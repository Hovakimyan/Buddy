import Foundation

/// One `AskUserQuestion` call waiting for a person's answer.
public struct PendingQuestion: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionId: String
    /// The subagent that asked (`HookEvent.agentId`); nil for the main conversation.
    public let agentId: String?
    /// The call's questions, already validated (`AskQuestion.parseSet`).
    public let questions: [AskQuestion]
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID,
        sessionId: String,
        agentId: String?,
        questions: [AskQuestion],
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentId = agentId
        self.questions = questions
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum QuestionOutcome: Sendable, Equatable {
    /// The answers map Claude Code receives (`AskAnswers.build`), and who gave it.
    case answered([String: String], DecisionSource)
    /// The person chose to answer in the terminal.
    case released
    case expired
    case cancelled
}

/// How one question ended: which, whose, and when. The engine keeps the recent ones in its snapshots so a UI can
/// tell how a question it showed was resolved.
public struct QuestionOutcomeRecord: Sendable, Equatable {
    public let id: UUID
    public let sessionId: String
    public let outcome: QuestionOutcome
    public let at: Date

    public init(id: UUID, sessionId: String, outcome: QuestionOutcome, at: Date) {
        self.id = id
        self.sessionId = sessionId
        self.outcome = outcome
        self.at = at
    }
}

/// Holds questions awaiting an answer, like `ApprovalQueue` holds approvals. Each `submit` suspends
/// until exactly one of `answer`, `release`, `cancel` or `expireDue` resolves it; a resolved id can
/// never be resolved again. Answers are stored as given: callers validate them first.
public actor QuestionQueue {
    private struct Entry {
        let question: PendingQuestion
        let continuation: CheckedContinuation<QuestionOutcome, Never>
    }

    private var entries: [UUID: Entry] = [:]
    /// Submission order, so `pending` is stable.
    private var order: [UUID] = []
    private var subscribers: [UUID: AsyncStream<[PendingQuestion]>.Continuation] = [:]

    public init() {}

    public var pending: [PendingQuestion] {
        order.compactMap { entries[$0]?.question }
    }

    /// Suspends until the question is answered, released, cancelled or expired. Resubmitting an id
    /// that is already pending resolves the new call as `.cancelled` and leaves the original
    /// untouched, and so does submitting from a task that is already cancelled (it is never shown).
    public func submit(_ q: PendingQuestion) async -> QuestionOutcome {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled, entries[q.id] == nil else {
                continuation.resume(returning: .cancelled)
                return
            }
            entries[q.id] = Entry(question: q, continuation: continuation)
            order.append(q.id)
            publish()
        }
    }

    /// Resolves a currently pending question with `answers`. Returns false if `requestId` is unknown
    /// or was already resolved; the first answer wins.
    public func answer(requestId: UUID, _ answers: [String: String], source: DecisionSource) -> Bool {
        resolve([requestId], with: .answered(answers, source)) > 0
    }

    public func release(requestId: UUID) {
        resolve([requestId], with: .released)
    }

    public func cancel(requestId: UUID) {
        resolve([requestId], with: .cancelled)
    }

    public func cancel(sessionId: String) {
        let ids = order.filter { entries[$0]?.question.sessionId == sessionId }
        resolve(ids, with: .cancelled)
    }

    /// Cancels the questions of one asker only: the main conversation of `sessionId` when `agentId` is
    /// nil, otherwise that one subagent. Parallel subagents of the session keep theirs.
    public func cancel(sessionId: String, agentId: String?) {
        let ids = order.filter {
            guard let question = entries[$0]?.question else { return false }
            return question.sessionId == sessionId && question.agentId == agentId
        }
        resolve(ids, with: .cancelled)
    }

    /// Resolves every question whose `expiresAt` is at or before `now` as `.expired`.
    public func expireDue(now: Date) {
        let ids = order.filter { id in entries[id].map { $0.question.expiresAt <= now } ?? false }
        resolve(ids, with: .expired)
    }

    /// Emits the current pending list on subscription and again after every change.
    public func updates() -> AsyncStream<[PendingQuestion]> {
        let (stream, continuation) = AsyncStream<[PendingQuestion]>.makeStream()
        let token = UUID()
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        continuation.yield(pending)
        return stream
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    /// Removes each id from storage before resuming its continuation, so a re-entrant or later
    /// call cannot find it and resume it a second time. Returns how many were resolved.
    @discardableResult
    private func resolve(_ ids: [UUID], with outcome: QuestionOutcome) -> Int {
        var resolved: [CheckedContinuation<QuestionOutcome, Never>] = []
        for id in ids {
            guard let entry = entries.removeValue(forKey: id) else { continue }
            order.removeAll { $0 == id }
            resolved.append(entry.continuation)
        }
        guard !resolved.isEmpty else { return 0 }
        publish()
        for continuation in resolved {
            continuation.resume(returning: outcome)
        }
        return resolved.count
    }

    private func publish() {
        let snapshot = pending
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }
}
