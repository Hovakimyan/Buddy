import Foundation

public enum Decision: String, Codable, Sendable {
    case allow, deny
}

public enum DecisionSource: String, Codable, Sendable {
    case mac, phone
}

/// What a permission request asks a person to approve.
public enum ApprovalKind: Sendable, Equatable {
    /// A tool call: allow or deny.
    case tool
    /// A plan (`ExitPlanMode`, its `plan` text): answered with a `PlanChoice` on the Mac only.
    case plan(text: String)
}

/// One permission request waiting for a human decision.
public struct PendingApproval: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionId: String
    /// The subagent that asked (`HookEvent.agentId`); nil for the main conversation.
    public let agentId: String?
    public let toolName: String
    public let toolInput: JSONValue?
    public let summary: ToolSummary
    public let createdAt: Date
    public let expiresAt: Date
    public let kind: ApprovalKind

    public init(
        id: UUID,
        sessionId: String,
        toolName: String,
        toolInput: JSONValue?,
        summary: ToolSummary,
        createdAt: Date,
        expiresAt: Date,
        agentId: String? = nil,
        kind: ApprovalKind = .tool
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentId = agentId
        self.toolName = toolName
        self.toolInput = toolInput
        self.summary = summary
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.kind = kind
    }
}

public enum ApprovalOutcome: Sendable, Equatable {
    case decided(Decision, DecisionSource)
    case expired
    case cancelled
}

/// Holds approvals awaiting a decision. Each `submit` suspends until exactly one of
/// `decide`, `cancel` or `expireDue` resolves it; a resolved id can never be resolved again.
public actor ApprovalQueue {
    private struct Entry {
        let approval: PendingApproval
        let continuation: CheckedContinuation<ApprovalOutcome, Never>
    }

    private var entries: [UUID: Entry] = [:]
    /// Submission order, so `pending` is stable.
    private var order: [UUID] = []
    private var subscribers: [UUID: AsyncStream<[PendingApproval]>.Continuation] = [:]

    public init() {}

    public var pending: [PendingApproval] {
        order.compactMap { entries[$0]?.approval }
    }

    /// Suspends until the approval is decided, cancelled or expired. Resubmitting an id that is
    /// already pending resolves the new call as `.cancelled` and leaves the original untouched, and so
    /// does submitting from a task that is already cancelled (it is never shown).
    public func submit(_ p: PendingApproval) async -> ApprovalOutcome {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled, entries[p.id] == nil else {
                continuation.resume(returning: .cancelled)
                return
            }
            entries[p.id] = Entry(approval: p, continuation: continuation)
            order.append(p.id)
            publish()
        }
    }

    /// Applies `d` to a currently pending approval. Returns false if `requestId` is unknown or
    /// was already resolved (decided, cancelled or expired); the first decision wins.
    public func decide(requestId: UUID, _ d: Decision, source: DecisionSource) -> Bool {
        resolve([requestId], with: .decided(d, source)) > 0
    }

    public func cancel(requestId: UUID) {
        resolve([requestId], with: .cancelled)
    }

    public func cancel(sessionId: String) {
        let ids = order.filter { entries[$0]?.approval.sessionId == sessionId }
        resolve(ids, with: .cancelled)
    }

    /// Cancels the approvals of one asker only: the main conversation of `sessionId` when `agentId` is nil,
    /// otherwise that one subagent. Parallel subagents of the session keep theirs.
    public func cancel(sessionId: String, agentId: String?) {
        let ids = order.filter {
            guard let approval = entries[$0]?.approval else { return false }
            return approval.sessionId == sessionId && approval.agentId == agentId
        }
        resolve(ids, with: .cancelled)
    }

    /// Resolves every approval whose `expiresAt` is at or before `now` as `.expired`.
    public func expireDue(now: Date) {
        let ids = order.filter { id in entries[id].map { $0.approval.expiresAt <= now } ?? false }
        resolve(ids, with: .expired)
    }

    /// Emits the current pending list on subscription and again after every change.
    public func updates() -> AsyncStream<[PendingApproval]> {
        let (stream, continuation) = AsyncStream<[PendingApproval]>.makeStream()
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
    private func resolve(_ ids: [UUID], with outcome: ApprovalOutcome) -> Int {
        var resolved: [CheckedContinuation<ApprovalOutcome, Never>] = []
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
