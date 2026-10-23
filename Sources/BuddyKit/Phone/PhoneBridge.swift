import Foundation

/// Mirrors sessions, pending approvals and pending questions to the phone and applies the phone's
/// decisions and answers.
///
/// Trust rules for decisions arriving from the phone (untrusted input):
/// - a decision is applied only if its `requestId` is currently pending in the local queue and not
///   expired (the bridge expires due approvals with its own clock first, since the queue has none);
///   unknown ids, duplicates, replays and decisions after the Mac already answered are ignored;
/// - it is always recorded as `.phone`, whatever `source` the record claims;
/// - an `allow` for an approval whose command summary was truncated is ignored (the approval stays
///   pending; truncated commands can only be allowed on the Mac). `deny` still applies;
/// - plan approvals are Mac only: they are never published, and any decision for one is ignored.
///
/// Answers to questions are untrusted the same way: one is applied only for a question currently
/// pending in the question queue and not expired (due questions are expired first, with the bridge's
/// clock), once (the first valid answer resolves it; replays find nothing pending). It needs exactly
/// one response per question and is built with `AskAnswers.build(allowFreeText: false)`, so every
/// response must be option labels of that question; anything else is ignored and the question stays
/// pending. It is always recorded as `.phone`.
///
/// Publishing is best effort: a failure never touches the queue. A failed publish is retried after
/// each of `retryDelays` in turn and then dropped. At most one publish task is live per session or
/// approval id; a newer record for the same id cancels the older one (and waits for it to finish),
/// so records of one id reach the transport in order and task count is bounded by the number of ids.
/// A question that leaves the queue is published as `.expired` when it ran out of time and as
/// `.resolved` otherwise (answered, released to the terminal or cancelled), like an approval.
public actor PhoneBridge {
    private enum PublishKey: Hashable {
        case session(String)
        case approval(UUID)
        case question(UUID)
    }

    private struct InFlight {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let queue: ApprovalQueue
    private let questionQueue: QuestionQueue
    private let transport: PhoneTransport
    private let clock: @Sendable () -> Date
    private let retryDelays: [TimeInterval]

    private var updatesTask: Task<Void, Never>?
    private var decisionsTask: Task<Void, Never>?
    private var questionUpdatesTask: Task<Void, Never>?
    private var answersTask: Task<Void, Never>?
    private var running = false
    /// True from `start()` until the first queue snapshot is applied: that snapshot republishes
    /// every pending approval and publishes a terminal record for any known one that has left.
    private var isFirstSnapshot = false
    /// Like `isFirstSnapshot`, for the question queue's snapshots.
    private var isFirstQuestionSnapshot = false

    /// Approvals currently in the queue, as last seen through `updates()`.
    private var knownApprovals: [UUID: PendingApproval] = [:]
    /// Questions currently in the question queue, as last seen through `updates()`.
    private var knownQuestions: [UUID: PendingQuestion] = [:]
    /// What the phone was last sent per session. Session changes the phone cannot see (activity,
    /// recent tools) map to an equal record and are not published again.
    private var publishedSessions: [String: SessionRecord] = [:]
    private var inFlight: [PublishKey: InFlight] = [:]
    private var nextGeneration: UInt64 = 0

    public init(
        queue: ApprovalQueue,
        questionQueue: QuestionQueue = QuestionQueue(),
        transport: PhoneTransport,
        clock: @escaping @Sendable () -> Date,
        retryDelays: [TimeInterval] = [1, 2, 4]
    ) {
        self.queue = queue
        self.questionQueue = questionQueue
        self.transport = transport
        self.clock = clock
        self.retryDelays = retryDelays
    }

    deinit {
        updatesTask?.cancel()
        decisionsTask?.cancel()
        questionUpdatesTask?.cancel()
        answersTask?.cancel()
        for entry in inFlight.values { entry.task.cancel() }
    }

    /// Number of publish tasks currently alive (running or waiting to retry).
    var inFlightPublishCount: Int { inFlight.count }

    /// Begins mirroring queue changes and consuming phone decisions and answers. A no-op if already started.
    public func start() {
        guard !running else { return }
        running = true
        isFirstSnapshot = true
        isFirstQuestionSnapshot = true
        let decisions = transport.decisions()
        let answers = transport.answers()
        let queue = queue
        let questionQueue = questionQueue
        updatesTask = Task { [weak self] in
            for await snapshot in await queue.updates() {
                guard !Task.isCancelled, let self else { return }
                await self.apply(snapshot: snapshot)
            }
        }
        decisionsTask = Task { [weak self] in
            for await record in decisions {
                guard !Task.isCancelled, let self else { return }
                await self.handle(record)
            }
        }
        questionUpdatesTask = Task { [weak self] in
            for await snapshot in await questionQueue.updates() {
                guard !Task.isCancelled, let self else { return }
                await self.apply(questionSnapshot: snapshot)
            }
        }
        answersTask = Task { [weak self] in
            for await record in answers {
                guard !Task.isCancelled, let self else { return }
                await self.handle(record)
            }
        }
    }

    /// Cancels every task the bridge started. Idempotent; the bridge can be started again.
    public func stop() {
        running = false
        updatesTask?.cancel()
        decisionsTask?.cancel()
        questionUpdatesTask?.cancel()
        answersTask?.cancel()
        updatesTask = nil
        decisionsTask = nil
        questionUpdatesTask = nil
        answersTask = nil
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
        // Publishes cancelled here never landed, so nothing is remembered as sent: the first sync
        // after a restart republishes every session.
        publishedSessions.removeAll()
        // knownApprovals and knownQuestions are kept on purpose: after a restart the first snapshot diff
        // publishes `.resolved`/`.expired` for approvals and questions that left their queue while stopped.
    }

    /// Publishes a record for each session whose record changed and removes records of sessions
    /// published before but absent now.
    public func sync(sessions: [Session]) async {
        let currentIds = Set(sessions.map(\.id))
        for session in sessions {
            let record = SessionRecord(
                sessionId: session.id,
                state: session.state,
                project: session.project,
                lastTool: session.lastTool,
                updatedAt: session.updatedAt)
            // Skips syncs that carry no new event: activity/recentTools-only changes keep the same
            // `updatedAt` (every store event bumps it), so the phone-visible record is equal.
            guard publishedSessions[session.id] != record else { continue }
            publishedSessions[session.id] = record
            let transport = transport
            enqueue(.session(session.id)) { try await transport.publish(session: record) }
        }
        for id in Set(publishedSessions.keys).subtracting(currentIds) {
            publishedSessions[id] = nil
            let transport = transport
            enqueue(.session(id)) { try await transport.removeSession(id: id) }
        }
    }

    /// Asks the transport to delete records older than 10 minutes. Best effort: a failure is
    /// ignored because the next `cleanup` retries the same deletion.
    public func cleanup() async {
        try? await transport.deleteRecords(olderThan: clock().addingTimeInterval(-600))
    }

    // MARK: Queue -> phone

    private func apply(snapshot: [PendingApproval]) {
        guard running else { return }
        let snapshot = snapshot.filter { $0.kind == .tool }  // plan cards are never mirrored
        let current = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = clock()
        for approval in snapshot where isFirstSnapshot || knownApprovals[approval.id] == nil {
            publish(approval, status: .pending)
        }
        for (id, approval) in knownApprovals where current[id] == nil {
            publish(approval, status: now >= approval.expiresAt ? .expired : .resolved)
        }
        knownApprovals = current
        isFirstSnapshot = false
    }

    private func publish(_ approval: PendingApproval, status: ApprovalStatus) {
        let record = ApprovalRecord(
            requestId: approval.id,
            sessionId: approval.sessionId,
            status: status,
            tool: approval.toolName,
            summary: approval.summary.text,
            isTruncated: approval.summary.isTruncated,
            createdAt: approval.createdAt,
            expiresAt: approval.expiresAt)
        let transport = transport
        enqueue(.approval(approval.id)) { try await transport.publish(approval: record) }
    }

    private func apply(questionSnapshot: [PendingQuestion]) {
        guard running else { return }
        let current = Dictionary(questionSnapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = clock()
        for question in questionSnapshot where isFirstQuestionSnapshot || knownQuestions[question.id] == nil {
            publish(question, status: .pending)
        }
        for (id, question) in knownQuestions where current[id] == nil {
            publish(question, status: now >= question.expiresAt ? .expired : .resolved)
        }
        knownQuestions = current
        isFirstQuestionSnapshot = false
    }

    private func publish(_ question: PendingQuestion, status: ApprovalStatus) {
        let record = QuestionRecord(
            requestId: question.id,
            sessionId: question.sessionId,
            status: status,
            questions: question.questions,
            createdAt: question.createdAt,
            expiresAt: question.expiresAt)
        let transport = transport
        enqueue(.question(question.id)) { try await transport.publish(question: record) }
    }

    // MARK: Phone -> queue

    private func handle(_ record: DecisionRecord) async {
        // The queue has no clock: expire anything due first so a late decision cannot win.
        await queue.expireDue(now: clock())
        guard !Task.isCancelled else { return }
        guard let approval = await queue.pending.first(where: { $0.id == record.requestId }),
              approval.kind == .tool else { return }
        if approval.summary.isTruncated, record.decision == .allow { return }
        _ = await queue.decide(requestId: record.requestId, record.decision, source: .phone)
    }

    private func handle(_ record: AnswerRecord) async {
        // The queue has no clock: expire anything due first so a late answer cannot win.
        await questionQueue.expireDue(now: clock())
        guard !Task.isCancelled else { return }
        guard let question = await questionQueue.pending.first(where: { $0.id == record.requestId }),
              let answers = AskAnswers.build(
                questions: question.questions,
                responses: record.responses.map(QuestionResponse.options),
                allowFreeText: false)
        else { return }
        _ = await questionQueue.answer(requestId: record.requestId, answers, source: .phone)
    }

    // MARK: Publishing with retry

    /// Runs `operation`, retrying after each delay in `retryDelays` and then giving up (the
    /// documented drop). Replaces any earlier task for `key`.
    private func enqueue(_ key: PublishKey, _ operation: @escaping @Sendable () async throws -> Void) {
        let previous = inFlight[key]?.task
        previous?.cancel()
        nextGeneration += 1
        let generation = nextGeneration
        let delays = retryDelays
        let task = Task { [weak self] in
            await previous?.value
            var attempt = 0
            var gaveUp = false
            while !Task.isCancelled {
                do {
                    try await operation()
                    break
                } catch {
                    guard attempt < delays.count else { gaveUp = true; break }
                    let delay = delays[attempt]
                    attempt += 1
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                }
            }
            await self?.finished(key, generation: generation, gaveUp: gaveUp)
        }
        inFlight[key] = InFlight(generation: generation, task: task)
    }

    private func finished(_ key: PublishKey, generation: UInt64, gaveUp: Bool) {
        guard inFlight[key]?.generation == generation else { return }
        inFlight[key] = nil
        // A dropped session record is forgotten, so the next sync of the same record publishes it again.
        if gaveUp, case .session(let id) = key { publishedSessions[id] = nil }
    }
}
