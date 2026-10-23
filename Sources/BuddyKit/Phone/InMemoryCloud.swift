import Foundation
import Synchronization

/// A thread-safe in-memory stand-in for the cloud store between Mac and phone. `macSide` and
/// `phoneSide` are two views of the same state. Decisions are kept (like a persisted record) and
/// replayed to every new `macSide.decisions()` subscriber until `deleteRecords` removes them; answers
/// are kept and replayed the same way.
public final class InMemoryCloud: Sendable {
    /// Thrown by `publish(session:)` / `publish(approval:)` / `publish(question:)` while `failNextPublishes` is armed.
    public struct SimulatedFailure: Error, Equatable {}

    public let macSide: any PhoneTransport
    public let phoneSide: any PhoneClientTransport
    private let core: Core

    public init() {
        let core = Core()
        self.core = core
        self.macSide = MacSide(core: core)
        self.phoneSide = PhoneSide(core: core)
    }

    /// Makes the next `n` calls to `publish(session:)` / `publish(approval:)` / `publish(question:)` throw.
    public func failNextPublishes(_ n: Int) {
        core.state.withLock { $0.pendingFailures = max(n, 0) }
    }

    fileprivate final class Core: Sendable {
        struct State {
            var sessions: [String: SessionRecord] = [:]
            var approvals: [UUID: ApprovalRecord] = [:]
            var decisions: [DecisionRecord] = []
            var questions: [UUID: QuestionRecord] = [:]
            var answers: [AnswerRecord] = []
            var pendingFailures = 0
            var sessionSubscribers: [UUID: AsyncStream<[SessionRecord]>.Continuation] = [:]
            var approvalSubscribers: [UUID: AsyncStream<[ApprovalRecord]>.Continuation] = [:]
            var decisionSubscribers: [UUID: AsyncStream<DecisionRecord>.Continuation] = [:]
            var questionSubscribers: [UUID: AsyncStream<[QuestionRecord]>.Continuation] = [:]
            var answerSubscribers: [UUID: AsyncStream<AnswerRecord>.Continuation] = [:]

            var sessionSnapshot: [SessionRecord] {
                sessions.values.sorted { $0.sessionId < $1.sessionId }
            }

            var approvalSnapshot: [ApprovalRecord] {
                approvals.values.sorted {
                    ($0.createdAt, $0.requestId.uuidString) < ($1.createdAt, $1.requestId.uuidString)
                }
            }

            var questionSnapshot: [QuestionRecord] {
                questions.values.sorted {
                    ($0.createdAt, $0.requestId.uuidString) < ($1.createdAt, $1.requestId.uuidString)
                }
            }

            mutating func consumeFailure() -> Bool {
                guard pendingFailures > 0 else { return false }
                pendingFailures -= 1
                return true
            }

            func broadcastSessions() {
                let snapshot = sessionSnapshot
                for continuation in sessionSubscribers.values { continuation.yield(snapshot) }
            }

            func broadcastApprovals() {
                let snapshot = approvalSnapshot
                for continuation in approvalSubscribers.values { continuation.yield(snapshot) }
            }

            func broadcastQuestions() {
                let snapshot = questionSnapshot
                for continuation in questionSubscribers.values { continuation.yield(snapshot) }
            }
        }

        let state = Mutex(State())

        /// Registers a subscriber and yields the current values, atomically, so no change is missed
        /// or reordered relative to the initial snapshot.
        func subscribe<T: Sendable>(
            register: (inout State, UUID, AsyncStream<T>.Continuation) -> Void,
            unregister: @escaping @Sendable (inout State, UUID) -> Void,
            initial: (State) -> [T]
        ) -> AsyncStream<T> {
            let (stream, continuation) = AsyncStream<T>.makeStream()
            let token = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { unregister(&$0, token) }
            }
            state.withLock { state in
                register(&state, token, continuation)
                for value in initial(state) { continuation.yield(value) }
            }
            return stream
        }
    }

    private struct MacSide: PhoneTransport {
        let core: Core

        func publish(session: SessionRecord) async throws {
            try core.state.withLock { state in
                if state.consumeFailure() { throw SimulatedFailure() }
                state.sessions[session.sessionId] = session
                state.broadcastSessions()
            }
        }

        func removeSession(id: String) async throws {
            core.state.withLock { state in
                guard state.sessions.removeValue(forKey: id) != nil else { return }
                state.broadcastSessions()
            }
        }

        func publish(approval: ApprovalRecord) async throws {
            try core.state.withLock { state in
                if state.consumeFailure() { throw SimulatedFailure() }
                state.approvals[approval.requestId] = approval
                state.broadcastApprovals()
            }
        }

        func decisions() -> AsyncStream<DecisionRecord> {
            core.subscribe(
                register: { $0.decisionSubscribers[$1] = $2 },
                unregister: { $0.decisionSubscribers[$1] = nil },
                initial: { $0.decisions })
        }

        func publish(question: QuestionRecord) async throws {
            try core.state.withLock { state in
                if state.consumeFailure() { throw SimulatedFailure() }
                state.questions[question.requestId] = question
                state.broadcastQuestions()
            }
        }

        func answers() -> AsyncStream<AnswerRecord> {
            core.subscribe(
                register: { $0.answerSubscribers[$1] = $2 },
                unregister: { $0.answerSubscribers[$1] = nil },
                initial: { $0.answers })
        }

        /// Removes approvals and questions created, and decisions and answers made, before `olderThan`.
        /// Session records are left alone: they are owned by `removeSession` and a quiet session is still live.
        func deleteRecords(olderThan: Date) async throws {
            core.state.withLock { state in
                let oldApprovals = state.approvals.filter { $0.value.createdAt < olderThan }.map(\.key)
                for id in oldApprovals { state.approvals[id] = nil }
                state.decisions.removeAll { $0.decidedAt < olderThan }
                if !oldApprovals.isEmpty { state.broadcastApprovals() }
                let oldQuestions = state.questions.filter { $0.value.createdAt < olderThan }.map(\.key)
                for id in oldQuestions { state.questions[id] = nil }
                state.answers.removeAll { $0.answeredAt < olderThan }
                if !oldQuestions.isEmpty { state.broadcastQuestions() }
            }
        }
    }

    private struct PhoneSide: PhoneClientTransport {
        let core: Core

        func sessions() -> AsyncStream<[SessionRecord]> {
            core.subscribe(
                register: { $0.sessionSubscribers[$1] = $2 },
                unregister: { $0.sessionSubscribers[$1] = nil },
                initial: { [$0.sessionSnapshot] })
        }

        func approvals() -> AsyncStream<[ApprovalRecord]> {
            core.subscribe(
                register: { $0.approvalSubscribers[$1] = $2 },
                unregister: { $0.approvalSubscribers[$1] = nil },
                initial: { [$0.approvalSnapshot] })
        }

        func submit(decision: DecisionRecord) async throws {
            core.state.withLock { state in
                state.decisions.append(decision)
                for continuation in state.decisionSubscribers.values { continuation.yield(decision) }
            }
        }

        func questions() -> AsyncStream<[QuestionRecord]> {
            core.subscribe(
                register: { $0.questionSubscribers[$1] = $2 },
                unregister: { $0.questionSubscribers[$1] = nil },
                initial: { [$0.questionSnapshot] })
        }

        func submit(answer: AnswerRecord) async throws {
            core.state.withLock { state in
                state.answers.append(answer)
                for continuation in state.answerSubscribers.values { continuation.yield(answer) }
            }
        }
    }
}
