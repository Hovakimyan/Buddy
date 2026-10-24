import BuddyKit
import Foundation
import Synchronization

// SAFETY: nothing in BuddyPhoneTests creates a CKContainer, contacts CloudKit or iCloud, or touches
// ~/.claude or ~/Library/Application Support. Transports here are in memory.

/// A clock the tests move by hand.
final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Answers like Face ID would: always `result`, records the reasons it was asked with, and can run
/// something while the prompt is "on screen" (`during`).
final class FakeAuthenticator: Authenticating {
    private let state = Mutex<[String]>([])
    let result: Bool
    let during: @Sendable () async -> Void

    init(result: Bool, during: @escaping @Sendable () async -> Void = {}) {
        self.result = result
        self.during = during
    }

    var reasons: [String] { state.withLock { $0 } }
    var calls: Int { reasons.count }

    func authenticate(reason: String) async -> Bool {
        state.withLock { $0.append(reason) }
        await during()
        return result
    }
}

/// A phone-side transport the tests drive directly: they push sets into the streams and read what the
/// model submitted.
final class RecordingTransport: PhoneClientTransport {
    struct SubmitFailure: Error, Equatable {}

    private struct State {
        var sessions: [SessionRecord] = []
        var approvals: [ApprovalRecord] = []
        var sessionSubscribers: [UUID: AsyncStream<[SessionRecord]>.Continuation] = [:]
        var approvalSubscribers: [UUID: AsyncStream<[ApprovalRecord]>.Continuation] = [:]
        var questions: [QuestionRecord] = []
        var questionSubscribers: [UUID: AsyncStream<[QuestionRecord]>.Continuation] = [:]
        var submitted: [DecisionRecord] = []
        var submittedAnswers: [AnswerRecord] = []
        var submittedMessages: [MessageRecord] = []
        var failSubmits = false
        var alreadyRecorded: DecisionAlreadyRecorded?
        var answerAlreadyRecorded: AnswerAlreadyRecorded?
    }
    private let state = Mutex(State())

    var submitted: [DecisionRecord] { state.withLock { $0.submitted } }
    var submittedAnswers: [AnswerRecord] { state.withLock { $0.submittedAnswers } }
    var submittedMessages: [MessageRecord] { state.withLock { $0.submittedMessages } }

    func push(sessions: [SessionRecord]) {
        state.withLock { state in
            state.sessions = sessions
            for continuation in state.sessionSubscribers.values { continuation.yield(sessions) }
        }
    }

    func submit(message: MessageRecord) async throws {
        try state.withLock { state in
            if state.failSubmits { throw SubmitFailure() }
            state.submittedMessages.append(message)
        }
    }
    /// Makes every submit (decision or answer) fail.
    func failSubmits(_ fail: Bool) { state.withLock { $0.failSubmits = fail } }
    /// Makes every submit report that another decision was saved first.
    func rejectAsAlreadyRecorded(_ earlier: DecisionAlreadyRecorded?) { state.withLock { $0.alreadyRecorded = earlier } }

    /// Makes every answer submit report that another answer was saved first.
    func rejectAnswerAsAlreadyRecorded(_ earlier: AnswerAlreadyRecorded?) {
        state.withLock { $0.answerAlreadyRecorded = earlier }
    }

    func push(questions: [QuestionRecord]) {
        state.withLock { state in
            state.questions = questions
            for continuation in state.questionSubscribers.values { continuation.yield(questions) }
        }
    }

    func push(approvals: [ApprovalRecord]) {
        state.withLock { state in
            state.approvals = approvals
            for continuation in state.approvalSubscribers.values { continuation.yield(approvals) }
        }
    }

    func sessions() -> AsyncStream<[SessionRecord]> {
        let (stream, continuation) = AsyncStream<[SessionRecord]>.makeStream()
        state.withLock { state in
            state.sessionSubscribers[UUID()] = continuation
            continuation.yield(state.sessions)
        }
        return stream
    }

    func approvals() -> AsyncStream<[ApprovalRecord]> {
        let (stream, continuation) = AsyncStream<[ApprovalRecord]>.makeStream()
        state.withLock { state in
            state.approvalSubscribers[UUID()] = continuation
            continuation.yield(state.approvals)
        }
        return stream
    }

    func submit(decision: DecisionRecord) async throws {
        try state.withLock { state in
            if state.failSubmits { throw SubmitFailure() }
            if let earlier = state.alreadyRecorded { throw earlier }
            state.submitted.append(decision)
        }
    }

    func questions() -> AsyncStream<[QuestionRecord]> {
        let (stream, continuation) = AsyncStream<[QuestionRecord]>.makeStream()
        state.withLock { state in
            state.questionSubscribers[UUID()] = continuation
            continuation.yield(state.questions)
        }
        return stream
    }

    func submit(answer: AnswerRecord) async throws {
        try state.withLock { state in
            if state.failSubmits { throw SubmitFailure() }
            if let earlier = state.answerAlreadyRecorded { throw earlier }
            state.submittedAnswers.append(answer)
        }
    }
}

/// An approval relative to `clock`: pending, 60 s to live, by default.
func makeApproval(
    _ id: UUID = UUID(), clock: TestClock, status: ApprovalStatus = .pending, truncated: Bool = false,
    expiresIn: TimeInterval = 60, tool: String = "Bash", summary: String = "rm -rf build"
) -> ApprovalRecord {
    ApprovalRecord(
        requestId: id, sessionId: "s1", status: status, tool: tool, summary: summary, isTruncated: truncated,
        createdAt: clock.now.addingTimeInterval(-5), expiresAt: clock.now.addingTimeInterval(expiresIn))
}

/// A question relative to `clock`: pending, 60 s to live, one single-choice question, by default.
func makeQuestion(
    _ id: UUID = UUID(), clock: TestClock, status: ApprovalStatus = .pending, expiresIn: TimeInterval = 60,
    questions: [AskQuestion]? = nil
) -> QuestionRecord {
    QuestionRecord(
        requestId: id, sessionId: "s1", status: status,
        questions: questions ?? [
            AskQuestion(
                text: "Which database?", header: "Database",
                options: [AskOption(label: "Postgres", description: "Relational"), AskOption(label: "SQLite", description: nil)],
                multiSelect: false)
        ],
        createdAt: clock.now.addingTimeInterval(-5), expiresAt: clock.now.addingTimeInterval(expiresIn))
}

/// Polls until `condition` holds (the model consumes its streams on the main actor, asynchronously).
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
