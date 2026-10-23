import BuddyKit
import Foundation
import Observation

/// Why a decision was not sent. Nothing is submitted in any of these cases.
enum PhoneError: Error, Equatable, LocalizedError {
    /// Face ID / passcode failed or was cancelled.
    case notAuthenticated
    /// The command was too long to show in full: it can only be allowed on the Mac.
    case tooLongToAllow
    case expired
    /// No such request is known to this phone.
    case unknownApproval
    /// The request is resolved or expired (answered on the Mac or in the terminal).
    case notPending
    /// This phone already sent a decision for the request.
    case alreadyDecided
    /// Another decision for the request is being made (the Face ID prompt is up).
    case busy
    /// The request shown before the Face ID prompt is not the one there now (republished with other text).
    case changedWhileAuthenticating
    /// The command has characters outside the allowlisted classes (`DisplayText.isPlainReadable`), such as Hebrew
    /// or Arabic letters that can reorder the line on screen: it can only be allowed in the terminal.
    case notPlainText
    /// An answer for the request was already saved before this one (an earlier tap whose reply was lost, or
    /// another device); that answer counts. Nil when it could not be read back.
    case answeredEarlier(Decision?)
    case submitFailed(String)
    /// A pick is missing, or a pick is not one of the question's options (nothing is sent).
    case incompleteAnswer

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Face ID or passcode did not succeed. Nothing was sent."
        case .tooLongToAllow: "This command is too long to read in full here. Allow it on your Mac."
        case .expired: "This request has expired."
        case .unknownApproval: "This request is no longer available."
        case .notPending: "This request was already answered."
        case .alreadyDecided: "You already answered this request."
        case .busy: "Another answer for this request is in progress."
        case .changedWhileAuthenticating: "This request changed while you were answering. Nothing was sent. Review it again."
        case .notPlainText: "This command has characters that can change how it reads here. Allow it in the terminal on your Mac."
        case .answeredEarlier(.allow?): "This request was already answered with Allow, and that answer counts."
        case .answeredEarlier(.deny?): "This request was already answered with Deny, and that answer counts."
        case .answeredEarlier(nil): "This request already had an answer, and that answer counts."
        case .submitFailed(let message): "Could not send your answer (\(message)). Try again."
        case .incompleteAnswer: "Pick an answer for every question first. Nothing was sent."
        }
    }
}

/// The phone's state and rules (spec 4.4 and 6).
///
/// Nothing is allowed without a human tap AND a successful Face ID / passcode check, every time. Deny needs no
/// authentication. A decision names exactly the request shown. Resolved, expired and already-answered requests are
/// never pending, and expiry is re-evaluated against the clock on every read, so a stale list never offers them.
@MainActor
@Observable
final class PhoneModel {
    /// What the Face ID prompt says: generic on purpose (no command, tool or project text).
    static let authenticationReason = "Allow this Claude Code request"
    /// What the Face ID prompt says when sending an answer to a question: generic too.
    static let answerAuthenticationReason = "Send this answer to Claude"

    private(set) var sessions: [SessionRecord] = []
    /// Every approval the Mac published and the transport still has, whatever its status.
    private(set) var approvals: [ApprovalRecord] = []
    /// Every question the Mac published and the transport still has, whatever its status.
    private(set) var questions: [QuestionRecord] = []
    /// What this phone has sent, by request id.
    private var decided: [UUID: Decision] = [:]
    /// The answers this phone has sent (or that were already saved), by request id.
    private var answered: [UUID: [[String]]] = [:]
    /// Requests with a decision in progress (the prompt is up, or the submit is running).
    private var inFlight: Set<UUID> = []

    @ObservationIgnored private let transport: any PhoneClientTransport
    @ObservationIgnored private let authenticator: any Authenticating
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let refreshTransport: @Sendable () async -> Void
    @ObservationIgnored private let pause: @Sendable (Duration) async -> Void
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(
        transport: any PhoneClientTransport, authenticator: any Authenticating, clock: @escaping () -> Date,
        refresh: @escaping @Sendable () async -> Void = {},
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.authenticator = authenticator
        self.clock = clock
        self.refreshTransport = refresh
        self.pause = pause
    }

    /// Pending, unexpired and not yet answered from this phone, oldest first. Computed against the clock on every
    /// read: an approval disappears from here the moment it expires, with no new data from the transport.
    var pendingApprovals: [ApprovalRecord] {
        let now = clock()
        return approvals.filter { $0.status == .pending && $0.expiresAt > now && decided[$0.requestId] == nil }
    }

    /// Pending, unexpired and not yet answered from this phone, oldest first (the transport's order). Computed
    /// against the clock on every read, like `pendingApprovals`.
    var pendingQuestions: [QuestionRecord] {
        let now = clock()
        return questions.filter { $0.status == .pending && $0.expiresAt > now && answered[$0.requestId] == nil }
    }

    /// The model's clock (the views draw countdowns and the arming delay from the same time the rules use).
    var now: Date { clock() }

    func approval(id: UUID) -> ApprovalRecord? {
        approvals.first { $0.requestId == id }
    }

    /// What this phone sent for the request, if anything.
    func decision(for id: UUID) -> Decision? { decided[id] }

    func question(id: UUID) -> QuestionRecord? {
        questions.first { $0.requestId == id }
    }

    /// The responses this phone sent for the question (or that were already saved), if any.
    func answer(for id: UUID) -> [[String]]? { answered[id] }

    // MARK: Live data

    /// Starts following the transport's streams. Safe to call twice.
    func start() {
        guard tasks.isEmpty else { return }
        let sessionStream = transport.sessions()
        let approvalStream = transport.approvals()
        let questionStream = transport.questions()
        tasks = [
            Task { [weak self] in
                for await sessions in sessionStream { self?.sessions = sessions }
            },
            Task { [weak self] in
                for await approvals in approvalStream { self?.approvals = approvals }
            },
            Task { [weak self] in
                for await questions in questionStream { self?.questions = questions }
            },
        ]
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    /// Fetches the latest from the cloud now (pull to refresh, a push arrived).
    func refresh() async {
        await refreshTransport()
    }

    // MARK: Decisions

    /// Allow: only a request that is pending, unexpired, short enough to have been read in full and made only of
    /// allowlisted characters (the Mac card's rule, `DisplayText.isPlainReadable`), and only after Face ID /
    /// passcode. Throws `PhoneError`; in every failure nothing is submitted.
    func allow(_ id: UUID) async throws {
        let shown = try decidable(id)
        guard !shown.isTruncated else { throw PhoneError.tooLongToAllow }
        guard shown.canBeAllowedOnPhone else { throw PhoneError.notPlainText }
        try begin(id)
        defer { inFlight.remove(id) }
        guard await authenticator.authenticate(reason: Self.authenticationReason) else {
            throw PhoneError.notAuthenticated
        }
        // The prompt took time: the request may have expired or been answered on the Mac meanwhile, or the
        // record may have been republished under the same id with other text. What the person approved is
        // what was shown before the prompt, so anything else (or a command now too long to read) is refused.
        let fresh = try decidable(id)
        guard !fresh.isTruncated else { throw PhoneError.tooLongToAllow }
        guard fresh.canBeAllowedOnPhone else { throw PhoneError.notPlainText }
        guard fresh.tool == shown.tool, fresh.summary == shown.summary else {
            throw PhoneError.changedWhileAuthenticating
        }
        try await submit(.allow, for: id)
    }

    /// Deny: no authentication, but the same checks. Denying is always safe to offer, so a truncated command can
    /// be denied.
    func deny(_ id: UUID) async throws {
        _ = try decidable(id)
        try begin(id)
        defer { inFlight.remove(id) }
        try await submit(.deny, for: id)
    }

    /// The Deny action of a notification: the app was woken in the background with only a request id. Waits (up
    /// to `timeout`) for the request to be fetched from the cloud, polling with a growing pause (0.1 s, doubling
    /// up to 1 s), then applies `deny` with all its checks (still pending, not expired, not answered).
    func denyFromNotification(_ id: UUID, timeout: Duration = .seconds(20)) async throws {
        start()
        let deadline = ContinuousClock.now + timeout
        var delay = Self.firstPollDelay
        while approval(id: id) == nil {
            guard !Task.isCancelled else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw PhoneError.unknownApproval }
            await refresh()
            await pause(delay)
            delay = min(delay * 2, Self.longestPollDelay)
        }
        try await deny(id)
    }

    static let firstPollDelay: Duration = .milliseconds(100)
    static let longestPollDelay: Duration = .seconds(1)

    /// The approval if it can still be decided now.
    private func decidable(_ id: UUID) throws -> ApprovalRecord {
        guard let approval = approval(id: id) else { throw PhoneError.unknownApproval }
        guard decided[id] == nil else { throw PhoneError.alreadyDecided }
        guard approval.status == .pending else { throw PhoneError.notPending }
        guard clock() < approval.expiresAt else { throw PhoneError.expired }
        return approval
    }

    private func begin(_ id: UUID) throws {
        guard inFlight.insert(id).inserted else { throw PhoneError.busy }
    }

    private func submit(_ decision: Decision, for id: UUID) async throws {
        let record = DecisionRecord(requestId: id, decision: decision, decidedAt: clock(), source: .phone)
        do {
            try await transport.submit(decision: record)
        } catch let earlier as DecisionAlreadyRecorded {
            // Show the answer that counts, never this one.
            if let standing = earlier.decision { decided[id] = standing }
            throw PhoneError.answeredEarlier(earlier.decision)
        } catch {
            throw PhoneError.submitFailed(error.localizedDescription)
        }
        decided[id] = decision
    }

    // MARK: Answers

    /// Sends the person's picks (`responses[i]` are the labels chosen for question i) for a question that is
    /// pending, unexpired and not yet answered from this phone, only after Face ID / passcode, like Allow. Every
    /// pick must be one of that question's options: free text never comes from the phone. Throws `PhoneError`;
    /// in every failure nothing is submitted.
    func answer(_ id: UUID, responses: [[String]]) async throws {
        let shown = try answerable(id)
        guard Self.fits(responses, shown.questions) else { throw PhoneError.incompleteAnswer }
        try begin(id)
        defer { inFlight.remove(id) }
        guard await authenticator.authenticate(reason: Self.answerAuthenticationReason) else {
            throw PhoneError.notAuthenticated
        }
        // The prompt took time: what the person answered is what was shown before it, so a question that
        // expired, was answered on the Mac, or was republished under the same id with other text is refused.
        let fresh = try answerable(id)
        guard fresh.questions == shown.questions else { throw PhoneError.changedWhileAuthenticating }
        let record = AnswerRecord(requestId: id, responses: responses, answeredAt: clock())
        do {
            try await transport.submit(answer: record)
        } catch let earlier as AnswerAlreadyRecorded {
            // Show the answer that counts, never this one.
            if let standing = earlier.responses { answered[id] = standing }
            throw PhoneError.answeredEarlier(nil)
        } catch {
            throw PhoneError.submitFailed(error.localizedDescription)
        }
        answered[id] = responses
    }

    /// The question if it can still be answered now.
    private func answerable(_ id: UUID) throws -> QuestionRecord {
        guard let question = question(id: id) else { throw PhoneError.unknownApproval }
        guard answered[id] == nil else { throw PhoneError.alreadyDecided }
        guard question.status == .pending else { throw PhoneError.notPending }
        guard clock() < question.expiresAt else { throw PhoneError.expired }
        return question
    }

    /// One non-empty set of distinct options per question (exactly one unless multi-select).
    private static func fits(_ responses: [[String]], _ questions: [AskQuestion]) -> Bool {
        guard responses.count == questions.count else { return false }
        return zip(responses, questions).allSatisfy { picks, question in
            let labels = Set(question.options.map(\.label))
            return !picks.isEmpty && Set(picks).count == picks.count && picks.allSatisfy(labels.contains)
                && (question.multiSelect || picks.count == 1)
        }
    }
}
