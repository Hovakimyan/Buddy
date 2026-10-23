import BuddyKit
import Foundation

/// How much of the island is on screen.
enum IslandMode: Equatable, Sendable {
    /// Nothing is shown (no panel at all).
    case hidden
    /// A small bar around the notch: the character and a short status.
    case compact
    /// The full island: sessions, and the approval card or question when one is waiting.
    case expanded
}

/// What can happen to the island. `waitingCards` is a level, sent on every refresh; the rest are events.
enum IslandInput: Equatable, Sendable {
    case hoverBegan, hoverEnded
    /// A click on the island.
    case click
    case escape
    /// Pointer movement inside the expanded island.
    case interaction
    /// A session changed state or activity.
    case ordinaryEvent
    /// The ids of the cards (approvals, plans and questions) waiting.
    case waitingCards(Set<UUID>)
    /// The deadline in `closesAt` may have passed.
    case tick
}

/// A change of mode, or an escape press (which can leave the mode as it was). Sounds are played from it, and
/// a question that is showing is released when `escaped`.
struct IslandTransition: Equatable, Sendable {
    let from: IslandMode
    let to: IslandMode
    let escaped: Bool
}

/// The island's show/hide logic, pure so it is unit-tested without a window or a clock: the controller feeds
/// it inputs with the current time and schedules one wake-up at `closesAt`.
///
/// Closing is one step at a time, expanded to compact to hidden, and `closesAt` is set whenever a close is
/// scheduled (so a countdown can be shown). It is nil while the island is held open: the pointer is on it,
/// or a card is waiting.
struct IslandMachine: Sendable {
    static let expandedTimeout: TimeInterval = 15
    static let compactTimeout: TimeInterval = 60
    /// How long a compact island that the pointer opened stays after the pointer leaves.
    static let hoverLeaveDelay: TimeInterval = 0.6

    private(set) var mode = IslandMode.hidden
    /// When the island next closes one step, or nil when hidden or held.
    private(set) var closesAt: Date?

    private var hovering = false
    /// The cards waiting at the last `waitingCards`.
    private var waiting: Set<UUID> = []
    private var cardPending: Bool { !waiting.isEmpty }
    /// Whether the compact island was opened by the pointer alone (it then follows the pointer out quickly).
    private var openedByHover = false

    /// Returns the change of mode, or nil when there was none. An escape is always returned.
    @discardableResult
    mutating func handle(_ input: IslandInput, now: Date) -> IslandTransition? {
        let from = mode
        var escaped = false
        switch input {
        case .hoverBegan:
            hovering = true
            if mode == .hidden {
                mode = .compact
                openedByHover = true
            }
            schedule(now)
        case .hoverEnded:
            hovering = false
            schedule(now)
        case .click:
            mode = .expanded
            schedule(now)
        case .interaction:
            if mode == .expanded { schedule(now) }
        case .ordinaryEvent:
            switch mode {
            case .hidden, .compact:
                mode = .compact
                openedByHover = false
                schedule(now)
            case .expanded: break
            }
        case .waitingCards(let ids):
            let arrived = !ids.isSubset(of: waiting)
            let wasPending = cardPending
            waiting = ids
            // Only a card not waiting before expands, so an escaped card stays away until the next one, even one
            // that arrives behind it. When the last card goes `schedule` starts the current mode's normal timer.
            if arrived { mode = .expanded }
            if arrived || cardPending != wasPending { schedule(now) }
        case .escape:
            escaped = true
            switch mode {
            case .expanded: mode = .compact
            // A waiting card holds the island at compact: escape cannot hide it.
            case .compact: if !cardPending { mode = .hidden }
            case .hidden: break
            }
            openedByHover = false
            schedule(now)
        case .tick:
            if let closesAt, now >= closesAt {
                switch mode {
                case .expanded: mode = .compact
                case .compact: mode = .hidden
                case .hidden: break
                }
                openedByHover = false
                schedule(now)
            }
        }
        return mode != from || escaped ? IslandTransition(from: from, to: mode, escaped: escaped) : nil
    }

    /// Sets `closesAt` for the current mode: nil when hidden or held, otherwise that mode's timeout from `now`.
    private mutating func schedule(_ now: Date) {
        if mode == .hidden || hovering || cardPending {
            closesAt = nil
            return
        }
        switch mode {
        case .expanded: closesAt = now.addingTimeInterval(Self.expandedTimeout)
        case .compact:
            closesAt = now.addingTimeInterval(openedByHover ? Self.hoverLeaveDelay : Self.compactTimeout)
        case .hidden: break
        }
    }
}

/// What the card's buttons can do.
enum ApprovalChoice: Sendable {
    case allow, deny, always
}

/// Since when a request's card has been on screen without a break: what the arming delay counts from.
struct ArmingClock: Equatable, Sendable {
    let request: UUID
    let since: Date
}

/// The island's decisions, kept pure so they are unit-tested without a window.
struct IslandLogic {
    /// Whether a refresh shows a session change worth revealing the island for: a session whose state or
    /// activity differs from the previous snapshot, or a new one. The first snapshot after launch is not a change.
    static func sessionsChanged(previous: [Session]?, current: [Session]) -> Bool {
        guard let previous else { return false }
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return current.contains { session in
            guard let old = before[session.id] else { return true }
            return old.state != session.state || old.activity != session.activity
        }
    }

    /// The text the card shows for the request: the engine's summary with invisible characters made visible.
    static func displayText(for approval: PendingApproval) -> String {
        DisplayText.sanitized(approval.summary.text)
    }

    /// The lines the card reserves for the text (at most `CardText.maxLines`). Text with glyphs of unknown width
    /// (`CardText.isMeasured`) cannot be estimated, so it reserves the most the card ever shows; its display is
    /// cut at that many lines, so it can never push the buttons out of the card.
    static func cardLines(for approval: PendingApproval) -> Int {
        let text = displayText(for: approval)
        guard CardText.isMeasured(text) else { return CardText.maxLines }
        return min(CardText.maxLines, CardText.lineCount(of: text))
    }

    /// Whether the card may allow this request: only when the human can read all of it. The summary must not
    /// have been cut by the engine (`isTruncated`), and what the card shows must fit in its lines. Otherwise
    /// the user answers in the terminal (the same rule as the phone bridge); Deny always works.
    static func canAllow(_ approval: PendingApproval) -> Bool {
        !approval.summary.isTruncated && CardText.isFullyVisible(displayText(for: approval))
    }

    /// How long a card must be on screen before Allow and Always do anything, so a click aimed at something
    /// else (the card appears under the pointer on its own) cannot approve a request.
    static let armingDelay: TimeInterval = Arming.delay

    /// Whether Allow/Always are live: `armingDelay` has passed since the card was first shown.
    static func isArmed(shownAt: Date, now: Date) -> Bool {
        Arming.isArmed(shownAt: shownAt, now: now)
    }

    /// The arming clock for the card at the front of the queue (`front`), given the island's `mode` and the
    /// clock so far. The card is only drawn while the island is expanded, so the clock runs only then: nil when
    /// there is no card or it is out of sight, a new clock from `now` when it comes into sight (again, or as a
    /// different card), and `previous` unchanged while the same card stays drawn.
    static func armingClock(front: UUID?, mode: IslandMode, previous: ArmingClock?, now: Date) -> ArmingClock? {
        guard let front, mode == .expanded else { return nil }
        if let previous, previous.request == front { return previous }
        return ArmingClock(request: front, since: now)
    }

    /// The decision to send for a button, or nil when the button must do nothing. Deny is never delayed.
    /// Allow and Always need a request that can be allowed and a card that has been shown long enough.
    /// "Always" is an ordinary allow of this one request: no persistent rule is written and nothing is
    /// auto-allowed later.
    /// `shownAt` is nil while the card has no arming clock yet (the island is still opening): Deny works, Allow and
    /// Always wait.
    static func decision(for choice: ApprovalChoice, approval: PendingApproval, shownAt: Date?, now: Date) -> Decision? {
        switch choice {
        case .deny: return .deny
        case .allow, .always:
            guard let shownAt else { return nil }
            return canAllow(approval) && isArmed(shownAt: shownAt, now: now) ? .allow : nil
        }
    }
}

// MARK: - Questions and plans

/// The card the expanded island shows: the oldest waiting request, an approval (a tool or a plan) or a question.
enum FrontCard: Equatable, Sendable {
    case approval(PendingApproval)
    case question(PendingQuestion)

    var id: UUID {
        switch self {
        case .approval(let approval): approval.id
        case .question(let question): question.id
        }
    }

    var createdAt: Date {
        switch self {
        case .approval(let approval): approval.createdAt
        case .question(let question): question.createdAt
        }
    }
}

extension IslandLogic {
    /// How long "Answered in iPhone." or "Still waiting in the terminal." shows after a question resolved.
    static let outcomeCardDuration: TimeInterval = 4

    /// The oldest waiting request across approvals and questions (an approval wins a tie), or nil when none waits.
    static func frontCard(pending: [PendingApproval], questions: [PendingQuestion]) -> FrontCard? {
        let cards = pending.map(FrontCard.approval) + questions.map(FrontCard.question)
        // `min` keeps the first of equal elements, and approvals come first.
        return cards.min { $0.createdAt < $1.createdAt }
    }

    /// The choice to send for a plan button, or nil when it must do nothing: "Change plan" is never delayed, the Go
    /// buttons wait for the card to have been shown for `armingDelay` (`shownAt` nil: not drawn yet).
    static func planChoice(_ choice: PlanChoice, shownAt: Date?, now: Date) -> PlanChoice? {
        switch choice {
        case .change: return .change
        case .acceptEdits, .askEachTime:
            guard let shownAt, isArmed(shownAt: shownAt, now: now) else { return nil }
            return choice
        }
    }

    /// The question to send back to the terminal after `transition`: the front one when Escape closed the open island
    /// while it showed (spec 6.1). Nil otherwise.
    static func questionToRelease(after transition: IslandTransition, front: FrontCard?) -> UUID? {
        guard transition.escaped, transition.from == .expanded, case .question(let question)? = front else { return nil }
        return question.id
    }

    /// What became of the latest question the island showed (`shown`), for `outcomeCardDuration` after it: answered on
    /// the phone, or timed out (the terminal asks now). Nothing for one answered here, released or cancelled.
    static func outcomeCard(_ records: [QuestionOutcomeRecord], shown: Set<UUID>, now: Date) -> StatusCardKind? {
        guard let last = records.last(where: { shown.contains($0.id) }),
              now >= last.at, now < last.at.addingTimeInterval(outcomeCardDuration) else { return nil }
        switch last.outcome {
        case .answered(_, .phone): return .answered(where: "iPhone")
        case .expired: return .stillWaiting
        case .answered(_, .mac), .released, .cancelled: return nil
        }
    }

    /// The questions that may get an outcome card: `previous`, plus `drawn` (the request whose card the island has
    /// drawn, its arming clock's) when it is a waiting question, less those that are neither waiting nor resolved
    /// lately. A question held in the compact island, or waiting while the screen is locked, is not one.
    static func shownQuestions(
        _ previous: Set<UUID>, drawn: UUID?, questions: [PendingQuestion], outcomes: [QuestionOutcomeRecord]
    ) -> Set<UUID> {
        let waiting = Set(questions.map(\.id))
        var shown = previous
        if let drawn, waiting.contains(drawn) { shown.insert(drawn) }
        return shown.intersection(waiting.union(outcomes.map(\.id)))
    }

    /// The "1/N" of the approval card: every request waiting, approvals and questions alike.
    static func queueCount(pending: [PendingApproval], questions: [PendingQuestion]) -> Int {
        pending.count + questions.count
    }

    /// The app to give the keyboard back to when the "Other..." field closes: the one that was frontmost when it
    /// opened (`frontmost`, a process id), unless that was Buddy itself (`own`) or none was. Nil: leave it.
    static func keyboardReturn(frontmost: pid_t?, own: pid_t) -> pid_t? {
        guard let frontmost, frontmost != own else { return nil }
        return frontmost
    }
}

// MARK: - Overview

/// One of the focused session's last tools, with its place in the run (`id`), so a new tool scrolls in and the
/// older ones keep their identity.
struct RecentTool: Equatable, Identifiable {
    let id: Int
    let name: String
}

/// A status card the island shows, and what dismisses it: OK hides the card for `key` (the session as it was), and
/// any later event of that session brings a card back. Cards without OK have no key.
struct StatusCard: Equatable {
    let kind: StatusCardKind
    let key: String?
}

extension IslandLogic {
    /// The session the island shows (`SessionFocus.focused`): one with a waiting card, else `chosen`, else the
    /// most recently active one.
    static func focusedSession(
        sessions: [Session], pending: [PendingApproval], questions: [PendingQuestion], chosen: String?
    ) -> Session? {
        let id = SessionFocus.focused(
            sessions: sessions, approvalSessionIds: pending.map(\.sessionId),
            questionSessionIds: questions.map(\.sessionId), chosen: chosen)
        return sessions.first { $0.id == id }
    }

    /// The session ⌃⌥] (`forward`) or ⌃⌥[ picks: the next or previous one after the focused session, wrapping. Nil
    /// when the focus would not change: no other session, or a waiting card holds the focus on its session.
    static func cycledFocus(
        sessions: [Session], pending: [PendingApproval], questions: [PendingQuestion], chosen: String?, forward: Bool
    ) -> String? {
        let current = focusedSession(sessions: sessions, pending: pending, questions: questions, chosen: chosen)?.id
        guard let next = Hotkeys.cycle(sessions.map(\.id), from: current, forward: forward), next != current,
              focusedSession(sessions: sessions, pending: pending, questions: questions, chosen: next)?.id == next
        else { return nil }
        return next
    }

    /// Whether the director's clock runs: only while the island is on screen.
    static func directorRuns(mode: IslandMode) -> Bool { mode != .hidden }

    /// The pills under the focused session: the other sessions in list order, at most `IslandLayout.maxPills`.
    static func otherSessions(_ sessions: [Session], focused: String?) -> [Session] {
        Array(sessions.filter { $0.id != focused }.prefix(IslandLayout.maxPills))
    }

    /// What the character shows: dizzy (from clicks) over everything, else `CharacterState.resolve` for the
    /// focused session, where a waiting card anywhere counts (the card's session has the focus).
    static func characterState(
        focused: Session?, pending: [PendingApproval], questions: [PendingQuestion], quietFor: TimeInterval,
        visible: Bool, dizzy: Bool
    ) -> CharacterState {
        if dizzy { return .dizzy }
        return CharacterState.resolve(
            session: focused, approvalPending: !pending.isEmpty, questionPending: !questions.isEmpty,
            quietFor: quietFor, islandVisible: visible)
    }

    // MARK: Subagents

    /// Subagent chips shown under the focused session; the rest is counted as "+N".
    static let maxAgentChips = 3

    /// One running subagent on the agent strip: its kind and current tool ("Explore · Read"), and whether it waits
    /// on a permission.
    struct AgentChip: Equatable, Identifiable {
        let id: String
        let label: String
        let waiting: Bool
    }

    /// The focused session's subagents as chips, in the order they started, at most `maxAgentChips`, and how many more
    /// there are. Their kind and tool come from the hook payload, so they are sanitized for display.
    static func agentChips(of session: Session?) -> (chips: [AgentChip], overflow: Int) {
        let agents = session?.agents ?? []
        let chips = agents.prefix(maxAgentChips).map { agent in
            let name = agent.type ?? "Agent"
            let label = agent.lastTool.map { "\(name) · \($0)" } ?? name
            return AgentChip(id: agent.id, label: oneLine(label), waiting: agent.state == .waiting)
        }
        return (chips, agents.count - chips.count)
    }

    /// Who asks on a card: nil for the main conversation, otherwise "<type> agent", or "Subagent" when the kind is
    /// unknown (Buddy did not see it start).
    static func asker(agentId: String?, sessionId: String, sessions: [Session]) -> String? {
        guard let agentId else { return nil }
        let type = sessions.first { $0.id == sessionId }?.agents.first { $0.id == agentId }?.type
        return type.map { oneLine("\($0) agent") } ?? "Subagent"
    }

    /// How many subagents the main conversation waits on: its turn ended while they still run. Zero otherwise.
    static func awaitedAgents(_ session: Session?) -> Int {
        guard let session, session.awaitingAgents else { return 0 }
        return session.agents.count
    }

    /// Sanitized and kept on one line.
    private static func oneLine(_ text: String) -> String {
        DisplayText.sanitized(text).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    /// The short status beside the notch in the compact island.
    static func statusWord(_ state: CharacterState, pendingCount: Int, awaitingAgents: Int = 0) -> String {
        if pendingCount > 0 { return "\(pendingCount) waiting" }
        if awaitingAgents > 0 { return "Waiting on \(awaitingAgents) " + (awaitingAgents == 1 ? "agent" : "agents") }
        switch state {
        case .idle: return "Idle"
        case .working: return "Working"
        case .thinking: return "Thinking"
        case .searching: return "Searching"
        case .approval: return "Approval"
        case .question: return "Question"
        case .error: return "Error"
        case .finished: return "Done"
        case .rateLimited: return "Rate limited"
        case .sleeping: return "Asleep"
        case .dizzy: return "Dizzy"
        }
    }

    /// A pill's badge: "!" when the session waits for a permission (a card here or a prompt in the terminal),
    /// "?" for a question, a check when finished, an x after an error; none while it just works. At pill size the
    /// character alone cannot tell an approval from a question, so the badge does.
    static func pillBadge(for session: Session, pending: [PendingApproval], questions: [PendingQuestion]) -> PillBadge? {
        if questions.contains(where: { $0.sessionId == session.id }) || session.activity == .asking { return .question }
        if pending.contains(where: { $0.sessionId == session.id }) || session.state == .waiting { return .approval }
        switch session.state {
        case .finished: return .done
        case .error: return .failed
        case .idle, .working, .waiting: return nil
        }
    }

    static func stepsText(_ count: Int) -> String { count == 1 ? "1 step" : "\(count) steps" }

    /// The session's last (at most three) tools, oldest first, each numbered by its place among the session's
    /// `toolCount` tool calls.
    static func recentTools(of session: Session) -> [RecentTool] {
        let first = session.toolCount - session.recentTools.count
        return session.recentTools.enumerated().map { RecentTool(id: first + $0.offset, name: $0.element) }
    }

    /// The status card for the focused session, or nil. A waiting approval or question card takes the place
    /// instead; dizzy shows while it lasts, then what became of a question (`outcome`, `outcomeCard`); an error or
    /// finished session shows its card until OK.
    static func statusCard(
        focused: Session?, dizzy: Bool, cardPending: Bool, dismissed: Set<String>, outcome: StatusCardKind? = nil
    ) -> StatusCard? {
        guard !cardPending else { return nil }
        if dizzy { return StatusCard(kind: .dizzy, key: nil) }
        if let outcome { return StatusCard(kind: outcome, key: nil) }
        guard let session = focused else { return nil }
        let key = "\(session.id)@\(session.updatedAt.timeIntervalSinceReferenceDate)"
        guard !dismissed.contains(key) else { return nil }
        switch session.state {
        case .error:
            let details = session.lastTool.map { "\(session.project), after \($0)" } ?? session.project
            return StatusCard(kind: .error(details: details), key: key)
        case .finished:
            return StatusCard(kind: .finished(lastLine: "\(session.project), \(stepsText(session.toolCount))"), key: key)
        case .idle, .working, .waiting:
            return nil
        }
    }

    // MARK: Sounds

    /// Peek when the island appears compact, open when it expands, close when it collapses from expanded.
    static func cues(for transition: IslandTransition) -> [SoundCue] {
        switch (transition.from, transition.to) {
        case (.hidden, .compact): [.peek]
        case (.hidden, .expanded), (.compact, .expanded): [.open]
        case (.expanded, .compact), (.expanded, .hidden): [.close]
        case (.compact, .hidden), (.hidden, .hidden), (.compact, .compact), (.expanded, .expanded): []
        }
    }

    /// The cue named like the director's reaction or emote; nil for those without a sound of their own.
    static func cue(for event: DirectorEvent) -> SoundCue? {
        switch event {
        case .boop: .boop
        case .greet: .greet
        case .dizzyStarted: .dizzy
        case .dizzyEnded: nil
        case .emote(let emote):
            switch emote {
            case .love: .love
            case .annoyed: .annoyed
            case .proud: .proud
            case .wink: .wink
            case .yawn: .yawn
            case .surprised, .happy, .listening: nil
            }
        }
    }
}

/// The island's cues that depend on what came before: session cues (`SoundTrigger`) against the previous
/// snapshot, and `sleep` on entering sleeping. The first snapshot is the baseline: what was already running when
/// Buddy started makes no sound.
struct IslandCues {
    private var trigger = SoundTrigger()
    private var last: EngineSnapshot?
    private var lastState: CharacterState?

    mutating func snapshot(_ snapshot: EngineSnapshot, terminalFrontmost: Bool) -> [SoundCue] {
        defer { last = snapshot }
        return trigger.cues(previous: last, current: snapshot, terminalFrontmost: terminalFrontmost)
    }

    mutating func character(_ state: CharacterState) -> [SoundCue] {
        defer { lastState = state }
        return state == .sleeping && lastState != .sleeping ? [.sleep] : []
    }
}

// MARK: Switching feeds (the demo)

/// What the island starts again from when its feed changes (`AppModel.islandFeed`: the demo starting or ending).
struct FeedSwitch {
    var cues: IslandCues
    /// The old feed's sessions and questions mean nothing to the new one.
    var chosenSession: String?
    var shownQuestions: Set<UUID>
}

extension IslandCues {
    /// Cues whose previous snapshot is `baseline`, so the next snapshot is compared with it.
    init(baseline: EngineSnapshot) {
        self.init()
        last = baseline
    }
}

extension IslandLogic {
    /// Into the demo the cues keep the real snapshot as their baseline, so the demo's SessionStart plays `work`. Back
    /// on the model (`toModel`) the baseline is the model's sessions with no card: no real card waited when the demo
    /// began (`AppModel.canStartDemo`), so any card there now is new and plays its cue, which matters most for the
    /// real request that ended the demo, while the sessions the engine already had play nothing.
    static func afterFeedSwitch(toModel: Bool, modelSessions: [Session], cues: IslandCues) -> FeedSwitch {
        let next = toModel ? IslandCues(baseline: EngineSnapshot(sessions: modelSessions, pending: [])) : cues
        return FeedSwitch(cues: next, chosenSession: nil, shownQuestions: [])
    }

    /// Where quiet is measured from at the earliest: launch for the model's feed; nothing for the demo, whose sleeping
    /// step is quiet from its own session's last event alone.
    static func quietSince(demo: Bool, launchedAt: Date) -> Date {
        demo ? .distantPast : launchedAt
    }

    /// Whether the cues treat a terminal as frontmost (skipping finish and error). Never for the demo: its session has
    /// no terminal, and the demo is the audio check.
    static func cuesSeeTerminalFrontmost(demo: Bool, terminalFrontmost: Bool) -> Bool {
        !demo && terminalFrontmost
    }
}
