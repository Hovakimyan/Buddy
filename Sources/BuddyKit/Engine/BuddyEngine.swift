#if os(macOS)
import Foundation
import OSLog

/// Everything a UI needs to draw: live sessions (most recent first), the approvals waiting for a
/// decision and the questions waiting for an answer (each in submission order), and how the recent
/// questions ended (oldest first, the last `BuddyEngine.recentOutcomeLimit`).
public struct EngineSnapshot: Sendable, Equatable {
    public var sessions: [Session]
    public var pending: [PendingApproval]
    public var questions: [PendingQuestion]
    public var recentQuestionOutcomes: [QuestionOutcomeRecord]

    public init(
        sessions: [Session], pending: [PendingApproval], questions: [PendingQuestion] = [],
        recentQuestionOutcomes: [QuestionOutcomeRecord] = []
    ) {
        self.sessions = sessions
        self.pending = pending
        self.questions = questions
        self.recentQuestionOutcomes = recentQuestionOutcomes
    }
}

/// The headless core: receives hook events on a Unix socket, folds them into a `SessionStore`,
/// turns permission requests into approvals and mirrors both to the phone.
///
/// Security: the socket handler only ever returns the decision carried by an
/// `ApprovalOutcome.decided`, and the queue is only decided by `decide(requestId:_:)` (the Mac) or
/// by `PhoneBridge` (a validated phone decision). Expired or cancelled approvals print nothing, so
/// Claude Code falls back to its own prompt. An approval is cancelled when its hook goes away, when
/// the terminal answered it first (matching PostToolUse), or when a later event shows it was answered
/// (PermissionRequest or PreToolUse of another call by the same asker; UserPromptSubmit or Stop for the
/// main conversation's; SubagentStop for that subagent's; SessionEnd for all of the session's). The asker is the session's main conversation or one of its subagents
/// (`agent_id`): subagents run in parallel, so one moving on says nothing about another's request.
///
/// Questions follow the same rules. An ask (a PreToolUse of `AskUserQuestion` from the `--ask` relay)
/// waits in a `QuestionQueue` until it is answered on the Mac (`answer`), released to the terminal,
/// expired or cancelled; only an answer prints anything. A plain PreToolUse of the very same call
/// (the `*` group firing next to the ask group) keeps it. A plan (`ExitPlanMode`) is an approval of
/// kind `.plan`, answered with a `PlanChoice` (`decidePlan`) on the Mac only.
public actor BuddyEngine {
    private enum Phase {
        case stopped, running, stopping
    }

    /// How long an approval stays open by default: 10 minutes, Claude Code's own default hook
    /// timeout, so a person who steps away can still answer from the iPhone. The terminal shows its
    /// own prompt meanwhile, so the wait never blocks it. Deliberately a few seconds under the
    /// relay's own wait (`HookClient.defaultWaitTimeout`, 610 s): a decision is only accepted while
    /// the approval is open, so one landing in the last moments can still reach a hook that is
    /// waiting, instead of being accepted but undeliverable.
    public static let defaultApprovalTimeout: TimeInterval = 600

    /// How long a question stays open by default: 10 minutes like an approval, under the relay's
    /// own wait for an ask (`HookClient.askWaitTimeout`, 610 s), for the same reason as
    /// `defaultApprovalTimeout`. The terminal shows no prompt while an ask waits; "Answer in
    /// terminal" (or Escape on the open island) hands it back at once.
    public static let defaultQuestionTimeout: TimeInterval = 600

    /// Tools whose permission request is never shown on the card or the phone. Questions are
    /// answered through the ask hook instead, before any permission request.
    static let terminalOnlyTools: Set<String> = ["AskUserQuestion"]
    static let askTool = "AskUserQuestion"
    static let planTool = "ExitPlanMode"

    /// How long a finished turn waits for a message from the phone: 10 minutes, as long as the Mac is kept awake
    /// after the last activity, and under the relay's own wait (`HookClient.stopWaitTimeout`, 610 s) like the other
    /// timeouts. Using the Mac (`releaseWaitingTurns`), Esc or a prompt in the terminal ends it sooner.
    public static let stopHoldTimeout: TimeInterval = 600
    /// A message from the phone older than this when it reaches the Mac (or still queued this long) is dropped:
    /// it was meant for a moment that has passed.
    public static let messageMaxAge: TimeInterval = 3600
    /// The most messages queued for one session; a further one is dropped.
    static let maxQueuedMessages = 5

    /// How often `PhoneBridge.cleanup()` runs while the engine is running.
    static let cleanupInterval: TimeInterval = 60
    /// How many resolved outcomes are kept for `outcome(for:)` (and of questions, for snapshots).
    static let recentOutcomeLimit = 64

    private let socketPath: URL
    private let approvalTimeout: TimeInterval
    private let questionTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let tickInterval: TimeInterval
    /// Whether someone can answer a question in Buddy right now; asked once per ask.
    private let canAskInBuddy: @Sendable () async -> Bool
    /// Types a message from the phone into the terminal a session runs in, as the person's own prompt; true when it
    /// did. Nil: messages only go through the `Stop` hook.
    public typealias TypeIntoTerminal = @Sendable (TerminalInfo, String) async -> Bool
    private let typeIntoTerminal: TypeIntoTerminal?
    private let queue: ApprovalQueue
    private let questionQueue: QuestionQueue
    private let bridge: PhoneBridge?
    private let transport: PhoneTransport?

    private var phase = Phase.stopped
    private var store = SessionStore()
    /// The queue's pending list as last delivered by `queue.updates()`.
    private var pending: [PendingApproval] = []
    /// The question queue's pending list as last delivered by `questionQueue.updates()`.
    private var questions: [PendingQuestion] = []
    private var server: HookSocketServer?

    private var timerTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var questionUpdatesTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    /// Starts the bridge, then applies session syncs one at a time, in order.
    private var bridgeTask: Task<Void, Never>?
    private var syncContinuation: AsyncStream<[Session]>.Continuation?
    /// The session list last handed to the bridge; nil means unknown (forces the next sync).
    private var lastSynced: [Session]?

    private var subscribers: [UUID: AsyncStream<EngineSnapshot>.Continuation] = [:]
    private var lastSnapshot = EngineSnapshot(sessions: [], pending: [], questions: [])

    /// Approvals whose `submit` has been issued and has not returned yet.
    private var inFlight: Set<UUID> = []
    /// Questions whose `submit` has been issued and has not returned yet.
    private var questionsInFlight: Set<UUID> = []
    /// The choice made for a plan approval, from `decidePlan` until its hook reply is built.
    private var planChoices: [UUID: PlanChoice] = [:]
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var recentOutcomes: [(id: UUID, outcome: ApprovalOutcome)] = []

    /// A `Stop` held for a message, per session (one at a time: a newer one lets the older go).
    private struct HeldStop {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<String?, Never>
    }
    private var heldStops: [String: HeldStop] = [:]
    /// Messages from the phone waiting for their session's turn to end, oldest first.
    private var queuedMessages: [String: [MessageRecord]] = [:]
    /// Messages for a session this run has not seen yet (after a restart its next event brings it back), kept until
    /// it shows up or they are too old.
    private var parkedMessages: [MessageRecord] = []
    /// Ids of messages already taken, so a replay is never delivered twice.
    private var takenMessages: [UUID] = []
    private var messagesTask: Task<Void, Never>?
    /// What happened to each message from the phone: ids, sessions and outcomes only, never the text.
    private static let messageLog = Logger(subsystem: "com.sergeyhovakimyan.buddy", category: "messages")
    private var recentQuestionOutcomes: [QuestionOutcomeRecord] = []

    public init(
        socketPath: URL,
        transport: PhoneTransport?,
        approvalTimeout: TimeInterval = BuddyEngine.defaultApprovalTimeout,
        clock: @escaping @Sendable () -> Date = Date.init,
        tickInterval: TimeInterval = 1,
        questionTimeout: TimeInterval = BuddyEngine.defaultQuestionTimeout,
        canAskInBuddy: @escaping @Sendable () async -> Bool = { true },
        typeIntoTerminal: TypeIntoTerminal? = nil
    ) {
        self.socketPath = socketPath
        self.approvalTimeout = approvalTimeout
        self.questionTimeout = questionTimeout
        self.clock = clock
        self.tickInterval = tickInterval
        self.canAskInBuddy = canAskInBuddy
        self.typeIntoTerminal = typeIntoTerminal
        let queue = ApprovalQueue()
        self.queue = queue
        let questionQueue = QuestionQueue()
        self.questionQueue = questionQueue
        self.bridge = transport.map {
            PhoneBridge(queue: queue, questionQueue: questionQueue, transport: $0, clock: clock)
        }
        self.transport = transport
    }

    deinit {
        server?.stop()
        timerTask?.cancel()
        updatesTask?.cancel()
        questionUpdatesTask?.cancel()
        cleanupTask?.cancel()
        messagesTask?.cancel()
        syncContinuation?.finish()
        for continuation in subscribers.values { continuation.finish() }
        for held in heldStops.values { held.continuation.resume(returning: nil) }
        for waiter in stopWaiters { waiter.resume() }
    }

    // MARK: Lifecycle

    /// Starts the socket server, the expiry timer, the queue mirror and (with a transport) the
    /// phone bridge. Throws `HookSocketError` if the socket cannot be served, and
    /// `HookSocketError.alreadyStarted` if the engine is running or still stopping.
    public func start() async throws {
        guard phase == .stopped else { throw HookSocketError.alreadyStarted }
        let server = HookSocketServer(path: socketPath) { [weak self] event in
            await self?.handle(event)
        }
        try server.start()
        self.server = server
        phase = .running

        let queue = queue
        updatesTask = Task { [weak self] in
            for await list in await queue.updates() {
                guard let self, !Task.isCancelled else { return }
                await self.applyPending(list)
            }
        }
        let questionQueue = questionQueue
        questionUpdatesTask = Task { [weak self] in
            for await list in await questionQueue.updates() {
                guard let self, !Task.isCancelled else { return }
                await self.applyQuestions(list)
            }
        }

        let interval = tickInterval
        timerTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }

        if let bridge {
            let (syncs, continuation) = AsyncStream<[Session]>.makeStream(
                bufferingPolicy: .bufferingNewest(1))  // only the latest list matters
            syncContinuation = continuation
            bridgeTask = Task {
                await bridge.removeLeftovers()
                await bridge.start()
                for await sessions in syncs {
                    await bridge.sync(sessions: sessions)
                }
            }
            cleanupTask = Task {
                while true {
                    await bridge.cleanup()
                    do { try await Task.sleep(for: .seconds(Self.cleanupInterval)) } catch { return }
                }
            }
        }
        if let transport {
            let messages = transport.messages()
            messagesTask = Task { [weak self] in
                for await message in messages {
                    guard let self, !Task.isCancelled else { return }
                    await self.receive(message: message)
                }
            }
        }
        sessionsChanged()
    }

    /// Stops accepting events, releases every waiting hook with no decision, and ends every task
    /// the engine started. Idempotent; a concurrent call returns once the first has finished.
    /// The engine can be started again afterwards (sessions are kept).
    public func stop() async {
        switch phase {
        case .stopped:
            return
        case .stopping:
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        case .running:
            phase = .stopping
        }

        server?.stop()  // removes the socket file
        server = nil

        // No new approval or question can be submitted now (handle() checks the phase), but a submit
        // may have been issued and not reached its queue yet, so keep cancelling until every one returned.
        while !inFlight.isEmpty || !questionsInFlight.isEmpty {
            for id in inFlight { await queue.cancel(requestId: id) }
            for id in questionsInFlight { await questionQueue.cancel(requestId: id) }
            if !inFlight.isEmpty || !questionsInFlight.isEmpty { await Task.yield() }
        }

        // Held stops end now, with no message: Claude stops as it would have without Buddy.
        for sessionId in Array(heldStops.keys) { releaseStop(sessionId: sessionId, with: nil) }

        timerTask?.cancel()
        updatesTask?.cancel()
        questionUpdatesTask?.cancel()
        cleanupTask?.cancel()
        messagesTask?.cancel()
        syncContinuation?.finish()  // lets the bridge task deliver the last sync, then end
        let tasks = [timerTask, updatesTask, questionUpdatesTask, cleanupTask, bridgeTask, messagesTask].compactMap { $0 }
        timerTask = nil
        updatesTask = nil
        questionUpdatesTask = nil
        cleanupTask = nil
        bridgeTask = nil
        messagesTask = nil
        syncContinuation = nil
        for task in tasks { await task.value }
        await bridge?.stop()
        lastSynced = nil

        pending = []  // the queues are empty: nothing can submit while not running
        questions = []
        publishSnapshot()
        phase = .stopped
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Public API

    /// The current snapshot on subscription, then a new one after every change to sessions,
    /// pending approvals or pending questions. The stream never finishes while the engine exists.
    public func snapshots() -> AsyncStream<EngineSnapshot> {
        let (stream, continuation) = AsyncStream<EngineSnapshot>.makeStream()
        let token = UUID()
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        continuation.yield(lastSnapshot)
        return stream
    }

    /// A decision made on the Mac. Returns true iff it was applied: false when `requestId` is
    /// unknown, already resolved, or past its `expiresAt` (even if the timer has not fired yet).
    /// Also false for a plan approval: a plan takes a `PlanChoice` (`decidePlan`).
    public func decide(requestId: UUID, _ d: Decision) async -> Bool {
        await queue.expireDue(now: clock())
        guard await queue.pending.first(where: { $0.id == requestId })?.kind == .tool else { return false }
        return await queue.decide(requestId: requestId, d, source: .mac)
    }

    /// A plan choice made on the Mac. `.acceptEdits` and `.askEachTime` approve the plan, `.change`
    /// sends it back. Returns true iff it was applied: false when `requestId` is not a pending plan
    /// approval (unknown, resolved, expired, or a tool approval) or another choice is being applied.
    public func decidePlan(requestId: UUID, _ choice: PlanChoice) async -> Bool {
        await queue.expireDue(now: clock())
        guard case .plan? = await queue.pending.first(where: { $0.id == requestId })?.kind,
              planChoices[requestId] == nil else { return false }
        // Recorded before deciding: the waiting request reads it as soon as the queue resolves.
        planChoices[requestId] = choice
        let decided = await queue.decide(requestId: requestId, choice == .change ? .deny : .allow, source: .mac)
        if !decided { planChoices[requestId] = nil }
        return decided
    }

    /// Answers given on the Mac, one response per question in order (free text allowed). Returns
    /// true iff they were applied: false when `requestId` is unknown, already resolved or past its
    /// `expiresAt`, or when the responses are not a valid answer or their reply would be longer than
    /// `HookWire.maxReplyBytes` (the question stays pending).
    public func answer(requestId: UUID, _ responses: [QuestionResponse]) async -> Bool {
        await questionQueue.expireDue(now: clock())
        guard let question = await questionQueue.pending.first(where: { $0.id == requestId }),
              let answers = AskAnswers.build(
                questions: question.questions, responses: responses, allowFreeText: true),
              // The hook would take a longer reply as no reply at all.
              HookWire.replyLine(for: .answers(answers)).count <= HookWire.maxReplyBytes
        else { return false }
        return await questionQueue.answer(requestId: requestId, answers, source: .mac)
    }

    /// The person chose to answer in the terminal: the ask hook prints nothing and returns now.
    public func releaseQuestion(requestId: UUID) async {
        await questionQueue.release(requestId: requestId)
    }

    // MARK: Messages from the phone

    /// Someone is using the Mac: every turn waiting for a phone message ends now, so the terminal is theirs again.
    public func releaseWaitingTurns() {
        for sessionId in Array(heldStops.keys) { releaseStop(sessionId: sessionId, with: nil) }
    }

    /// A message from the phone (untrusted). Taken once, while it is recent, and only as plain text of 1 to
    /// `MessageRecord.maxLength` characters (control characters other than line breaks and tabs are dropped). A held
    /// turn for its session gets it at once; otherwise it waits for the session's next finished turn. A message for a
    /// session this run has not seen is parked until that session's next event. It leaves the cloud only once it is
    /// handed to Claude, so a restart before that does not lose it. Returns whether it was taken (queued, parked or
    /// handed over).
    @discardableResult
    public func receive(message: MessageRecord) async -> Bool {
        let id = message.messageId
        let session = message.sessionId
        guard phase == .running, !takenMessages.contains(id) else { return false }
        let now = clock()
        guard now.timeIntervalSince(message.sentAt) <= Self.messageMaxAge else {
            Self.messageLog.notice("message \(id, privacy: .public) refused: too old")
            return false
        }
        guard let text = Self.cleaned(message.text) else {
            Self.messageLog.notice("message \(id, privacy: .public) refused: empty or too long")
            return false
        }
        takenMessages.append(message.messageId)
        if takenMessages.count > Self.recentOutcomeLimit { takenMessages.removeFirst() }

        var cleaned = message
        cleaned.text = text
        let late = Int(now.timeIntervalSince(message.sentAt) * 1000)
        if !store.sessions.contains(where: { $0.id == session }) {
            guard parkedMessages.count < Self.maxQueuedMessages * 4 else { return false }
            parkedMessages.append(cleaned)
            Self.messageLog.notice("message \(id, privacy: .public) parked until session \(session, privacy: .public) shows up")
        } else if await typed(text, into: session) {
            consume(message)
            Self.messageLog.notice("message \(id, privacy: .public) typed into the terminal of session \(session, privacy: .public), \(late, privacy: .public) ms after sending")
        } else if heldStops[message.sessionId] != nil {
            store.notePrompt(text, sessionId: message.sessionId)  // before the release, which publishes the session
            releaseStop(sessionId: message.sessionId, with: text)
            consume(message)
            Self.messageLog.notice("message \(id, privacy: .public) handed to waiting session \(session, privacy: .public), \(late, privacy: .public) ms after sending")
        } else {
            var queue = queuedMessages[message.sessionId, default: []]
            guard queue.count < Self.maxQueuedMessages else {
                Self.messageLog.notice("message \(id, privacy: .public) refused: queue of \(session, privacy: .public) full")
                return false
            }
            queue.append(cleaned)
            queuedMessages[message.sessionId] = queue
            sessionsChanged()
            Self.messageLog.notice("message \(id, privacy: .public) queued for session \(session, privacy: .public) until its turn ends, \(late, privacy: .public) ms after sending")
        }
        return true
    }

    /// Whether this Mac can type into the session's terminal (see `TerminalInfo.isTypable`).
    private func canType(sessionId: String) -> Bool {
        typeIntoTerminal != nil && store.sessions.first { $0.id == sessionId }?.terminal?.isTypable == true
    }

    /// Types `text` into the session's terminal as a prompt, when it can: one line only (a line break would send the
    /// first line on its own). A turn waiting for a message ends first, so the typed prompt is taken at once.
    private func typed(_ text: String, into sessionId: String) async -> Bool {
        guard let typeIntoTerminal, !text.contains("\n"),
              let terminal = store.sessions.first(where: { $0.id == sessionId })?.terminal, terminal.isTypable
        else { return false }
        releaseStop(sessionId: sessionId, with: nil)
        return await typeIntoTerminal(terminal, text)
    }

    /// Removes a message handed to Claude from the cloud, so no later run delivers it again.
    private func consume(_ message: MessageRecord) {
        guard let transport else { return }
        let id = message.messageId
        Task { try? await transport.consume(message: id) }
    }

    /// Moves the messages parked for `sessionId` into its queue (its first event since they arrived).
    private func unpark(sessionId: String) {
        let arrived = parkedMessages.filter { $0.sessionId == sessionId }
        guard !arrived.isEmpty else { return }
        parkedMessages.removeAll { $0.sessionId == sessionId }
        var queue = queuedMessages[sessionId, default: []]
        queue.append(contentsOf: arrived.prefix(Self.maxQueuedMessages - queue.count))
        queuedMessages[sessionId] = queue
        for message in arrived {
            Self.messageLog.notice("message \(message.messageId, privacy: .public) queued: session \(sessionId, privacy: .public) showed up")
        }
    }

    /// Plain text a message may carry: trimmed, control characters other than line breaks and tabs dropped,
    /// 1 to `MessageRecord.maxLength` characters. Nil when nothing is left or it is too long.
    static func cleaned(_ text: String) -> String? {
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !(CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format)
        }))
        let trimmed = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= MessageRecord.maxLength else { return nil }
        return trimmed
    }

    /// A `Stop` from `buddy-hook --stop`: the main conversation finished its turn. A queued message is handed over
    /// at once; otherwise the turn waits (up to `stopHoldTimeout`) for one. The person can always end the wait
    /// in the terminal (Esc closes the hook's connection, which cancels this).
    private func holdStop(for event: HookEvent) async -> HookReply? {
        guard event.name == .stop, event.agentId == nil else { return nil }
        let sessionId = event.sessionId
        unpark(sessionId: sessionId)
        if let message = takeQueuedMessage(sessionId: sessionId) {
            consume(message)
            store.notePrompt(message.text, sessionId: sessionId)
            sessionsChanged()
            Self.messageLog.notice("message \(message.messageId, privacy: .public) handed to session \(sessionId, privacy: .public) as its turn ended")
            return .message(message.text)
        }
        guard phase == .running else { return nil }
        // A message can be typed into this session's terminal whenever it comes: nothing needs to wait.
        guard !canType(sessionId: sessionId) else { return nil }
        Self.messageLog.notice("session \(sessionId, privacy: .public) finished its turn: waiting for a message")
        releaseStop(sessionId: sessionId, with: nil)  // one wait per session
        let id = UUID()
        let deadline = clock().addingTimeInterval(Self.stopHoldTimeout)
        let text = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                heldStops[sessionId] = HeldStop(id: id, deadline: deadline, continuation: continuation)
                sessionsChanged()
            }
        } onCancel: {
            Task { await self.releaseStop(sessionId: sessionId, id: id) }
        }
        return text.map(HookReply.message)
    }

    private func takeQueuedMessage(sessionId: String) -> MessageRecord? {
        guard var queue = queuedMessages[sessionId], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        queuedMessages[sessionId] = queue.isEmpty ? nil : queue
        sessionsChanged()
        return first
    }

    /// Ends the session's held turn (only the one with `id`, when given): with a message Claude carries on, with
    /// nil it stops.
    private func releaseStop(sessionId: String, id: UUID? = nil, with text: String? = nil) {
        guard let held = heldStops[sessionId], id == nil || held.id == id else { return }
        heldStops[sessionId] = nil
        held.continuation.resume(returning: text)
        sessionsChanged()
    }

    // MARK: Test hooks

    var hasPhoneBridge: Bool { bridge != nil }

    /// How a recent approval was resolved (the last `recentOutcomeLimit` are kept).
    func outcome(for id: UUID) -> ApprovalOutcome? {
        recentOutcomes.last { $0.id == id }?.outcome
    }

    /// How a recent question was resolved (the last `recentOutcomeLimit` are kept).
    func questionOutcome(for id: UUID) -> QuestionOutcome? {
        recentQuestionOutcomes.last { $0.id == id }?.outcome
    }

    // MARK: Events

    private func handle(_ event: HookEvent) async -> HookReply? {
        guard phase == .running else { return nil }
        // The `--stop` relay's copy of a Stop: only about messages. The plain relay's copy, in order, is the one
        // applied to the session.
        if event.isStopWait { return await holdStop(for: event) }
        switch event.name {
        case .permissionRequest:
            return await requestApproval(for: event)
        case .postToolUse, .postToolUseFailure:
            // The terminal answered this exact call first: its hook is no longer waiting for us.
            let match = await queue.pending.first {
                $0.sessionId == event.sessionId
                    && $0.agentId == event.agentId
                    && $0.toolName == event.toolName
                    && $0.toolInput == event.toolInput
            }
            if let match { await queue.cancel(requestId: match.id) }
            if let asked = askedQuestions(in: event) {
                let question = await questionQueue.pending.first {
                    $0.sessionId == event.sessionId && $0.agentId == event.agentId && $0.questions == asked
                }
                if let question { await questionQueue.cancel(requestId: question.id) }
            }
        case .sessionEnd:
            // The session is gone: nobody waits on any of its requests, and its messages have nowhere to go.
            await queue.cancel(sessionId: event.sessionId)
            await questionQueue.cancel(sessionId: event.sessionId)
            releaseStop(sessionId: event.sessionId)
            queuedMessages[event.sessionId] = nil
        case .stop, .stopFailure, .userPromptSubmit:
            // The main turn ended or a new prompt was typed: the main conversation's requests were answered.
            // Background subagents can outlive the turn, and their open requests still wait in the terminal.
            await queue.cancel(sessionId: event.sessionId, agentId: nil)
            await questionQueue.cancel(sessionId: event.sessionId, agentId: nil)
            // A prompt typed in the terminal: the person is back, so a turn held for the phone is over.
            if event.name == .userPromptSubmit { releaseStop(sessionId: event.sessionId) }
        case .subagentStop:
            // The subagent finished: nothing of its is waiting any more.
            if let agentId = event.agentId {
                await queue.cancel(sessionId: event.sessionId, agentId: agentId)
                await questionQueue.cancel(sessionId: event.sessionId, agentId: agentId)
            }
        case .preToolUse:
            if event.isAsk, event.toolName == Self.askTool {
                return await requestAnswer(for: event)
            }
            // The asker (main conversation or one subagent) moved on to another tool call, so its older
            // requests were answered in the terminal. This call's own request comes after this event but
            // can be handled first (permission requests skip the ordered event line), so a request for
            // the very same call is kept.
            let stale = await queue.pending.filter {
                $0.sessionId == event.sessionId
                    && $0.agentId == event.agentId
                    && !($0.toolName == event.toolName && $0.toolInput == event.toolInput)
            }
            for approval in stale { await queue.cancel(requestId: approval.id) }
            // Likewise for questions: the `*` group's PreToolUse of the call an ask waits on keeps it.
            let asked = askedQuestions(in: event)
            let staleQuestions = await questionQueue.pending.filter {
                $0.sessionId == event.sessionId && $0.agentId == event.agentId && $0.questions != asked
            }
            for question in staleQuestions { await questionQueue.cancel(requestId: question.id) }
        case .sessionStart, .notification, .subagentStart:
            break
        }
        // Applied after the queue work, so a snapshot showing this event also reflects it.
        apply(event)
        return nil
    }

    private func requestApproval(for event: HookEvent) async -> HookReply? {
        apply(event)
        // Each asker (the main conversation, or one subagent) asks one thing at a time: a new request
        // means its older ones were answered in the terminal (belt and braces next to the hang-up check
        // below). Parallel subagents of the same session keep theirs. Its PreToolUse hooks have all
        // returned by now, so no ask of this asker is waiting either.
        await queue.cancel(sessionId: event.sessionId, agentId: event.agentId)
        await questionQueue.cancel(sessionId: event.sessionId, agentId: event.agentId)
        // stop() may have run while the cancels above were suspended: it only cancels ids already in
        // inFlight, so a request submitted after it would wait for nothing.
        guard phase == .running else { return nil }
        // Nothing to show a human without a tool name: let Claude Code ask in the terminal.
        guard let toolName = event.toolName, !toolName.isEmpty else { return nil }
        // A question's permission request: the ask hook is where Buddy answers it, so only the
        // terminal can answer this one. No card, no phone record, and the hook prints nothing.
        guard !Self.terminalOnlyTools.contains(toolName) else { return nil }
        var kind = ApprovalKind.tool
        if toolName == Self.planTool {
            // Nothing to read without the plan text: let Claude Code ask in the terminal.
            guard let plan = Self.planText(in: event.toolInput) else { return nil }
            kind = .plan(text: plan)
        }
        let now = clock()
        let approval = PendingApproval(
            id: UUID(),
            sessionId: event.sessionId,
            toolName: toolName,
            toolInput: event.toolInput,
            summary: ToolSummary.make(toolName: toolName, toolInput: event.toolInput),
            createdAt: now,
            expiresAt: now.addingTimeInterval(approvalTimeout),
            agentId: event.agentId,
            kind: kind)
        inFlight.insert(approval.id)
        let queue = queue
        let id = approval.id
        // The socket server cancels this task when the hook's connection closes: the person answered
        // in the terminal (a "no" there sends no other event), so the card and the phone clear now.
        let outcome = await withTaskCancellationHandler {
            await queue.submit(approval)
        } onCancel: {
            Task { await queue.cancel(requestId: id) }
        }
        inFlight.remove(approval.id)
        remember(outcome, for: approval.id)
        let choice = planChoices.removeValue(forKey: approval.id)
        switch outcome {
        case .decided(let decision, _):
            guard case .plan = kind else { return .decision(decision) }
            return choice.map(HookReply.plan)
        case .expired, .cancelled:
            return nil
        }
    }

    /// An ask: the `--ask` relay waits on this `AskUserQuestion` call until the person answers in
    /// Buddy. Not applied to the session: the `*` group relays the same PreToolUse in order.
    private func requestAnswer(for event: HookEvent) async -> HookReply? {
        // Malformed questions: no card, the terminal asks them.
        guard let asked = AskQuestion.parseSet(toolInput: event.toolInput) else { return nil }
        // One question at a time per asker, like approvals.
        await questionQueue.cancel(sessionId: event.sessionId, agentId: event.agentId)
        // While the hook waits the terminal shows no prompt, so wait only if someone can answer here.
        guard await canAskInBuddy() else { return nil }
        // stop() may have run while suspended above (see requestApproval).
        guard phase == .running else { return nil }
        let now = clock()
        let question = PendingQuestion(
            id: UUID(),
            sessionId: event.sessionId,
            agentId: event.agentId,
            questions: asked,
            createdAt: now,
            expiresAt: now.addingTimeInterval(questionTimeout))
        questionsInFlight.insert(question.id)
        let questionQueue = questionQueue
        let id = question.id
        // The socket server cancels this task when the hook's connection closes (Ctrl+C in the terminal).
        let outcome = await withTaskCancellationHandler {
            await questionQueue.submit(question)
        } onCancel: {
            Task { await questionQueue.cancel(requestId: id) }
        }
        questionsInFlight.remove(id)
        rememberQuestion(outcome, for: question)
        guard case .answered(let answers, _) = outcome else { return nil }
        return .answers(answers)
    }

    /// The questions of an `AskUserQuestion` event, or nil for any other tool or malformed questions.
    private func askedQuestions(in event: HookEvent) -> [AskQuestion]? {
        guard event.toolName == Self.askTool else { return nil }
        return AskQuestion.parseSet(toolInput: event.toolInput)
    }

    /// The `plan` of an `ExitPlanMode` call, or nil when it has no readable plan text.
    private static func planText(in toolInput: JSONValue?) -> String? {
        guard case .object(let input)? = toolInput,
              case .string(let plan)? = input["plan"],
              !plan.allSatisfy(\.isWhitespace) else { return nil }
        return plan
    }

    private func apply(_ event: HookEvent) {
        store.apply(event, now: clock())
        unpark(sessionId: event.sessionId)
        sessionsChanged()
    }

    private func remember(_ outcome: ApprovalOutcome, for id: UUID) {
        recentOutcomes.append((id, outcome))
        if recentOutcomes.count > Self.recentOutcomeLimit {
            recentOutcomes.removeFirst(recentOutcomes.count - Self.recentOutcomeLimit)
        }
    }

    private func rememberQuestion(_ outcome: QuestionOutcome, for question: PendingQuestion) {
        recentQuestionOutcomes.append(QuestionOutcomeRecord(
            id: question.id, sessionId: question.sessionId, outcome: outcome, at: clock()))
        if recentQuestionOutcomes.count > Self.recentOutcomeLimit {
            recentQuestionOutcomes.removeFirst(recentQuestionOutcomes.count - Self.recentOutcomeLimit)
        }
        publishSnapshot()
    }

    // MARK: Timer and mirrors

    private func tick() async {
        guard phase == .running else { return }
        let now = clock()
        store.expire(now: now)
        for (sessionId, held) in heldStops where held.deadline <= now { releaseStop(sessionId: sessionId, with: nil) }
        for (sessionId, queue) in queuedMessages {
            let fresh = queue.filter { now.timeIntervalSince($0.sentAt) <= Self.messageMaxAge }
            queuedMessages[sessionId] = fresh.isEmpty ? nil : fresh
        }
        parkedMessages.removeAll { now.timeIntervalSince($0.sentAt) > Self.messageMaxAge }
        sessionsChanged()
        await queue.expireDue(now: now)
        await questionQueue.expireDue(now: now)
    }

    private func applyPending(_ list: [PendingApproval]) {
        pending = list
        publishSnapshot()
    }

    private func applyQuestions(_ list: [PendingQuestion]) {
        questions = list
        publishSnapshot()
    }

    /// Publishes a snapshot and queues a phone sync, each only if something actually changed.
    private func sessionsChanged() {
        publishSnapshot()
        guard let syncContinuation else { return }
        let sessions = currentSessions
        guard sessions != lastSynced else { return }
        lastSynced = sessions
        syncContinuation.yield(sessions)
    }

    private func publishSnapshot() {
        let snapshot = EngineSnapshot(
            sessions: currentSessions, pending: pending, questions: questions,
            recentQuestionOutcomes: recentQuestionOutcomes)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    /// The store's sessions with what only the engine knows: a turn held for a message, and queued messages.
    private var currentSessions: [Session] {
        store.sessions.map { session in
            var session = session
            // Waiting for a message: a turn held for one, or a finished session a message can be typed into.
            session.awaitingMessage = heldStops[session.id] != nil
                || (canType(sessionId: session.id) && (session.state == .finished || session.state == .idle))
            session.queuedMessages = queuedMessages[session.id]?.count ?? 0
            return session
        }
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }
}

#endif
