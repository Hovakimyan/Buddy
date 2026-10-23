import Foundation

public enum ApprovalStatus: String, Codable, Sendable {
    case pending, resolved, expired
}

/// What the phone sees of one terminal session.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var sessionId: String
    public var state: SessionState
    public var project: String
    public var lastTool: String?
    public var updatedAt: Date
    /// Subagents running in the session now (`Session.agents`); the phone shows the count only.
    public var agentCount: Int

    public init(
        sessionId: String, state: SessionState, project: String, lastTool: String?, updatedAt: Date, agentCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.state = state
        self.project = project
        self.lastTool = lastTool
        self.updatedAt = updatedAt
        self.agentCount = agentCount
    }
}

/// What the phone sees of one permission request. `summary` is already bounded (see `ToolSummary`).
public struct ApprovalRecord: Codable, Sendable, Equatable {
    public var requestId: UUID
    public var sessionId: String
    public var status: ApprovalStatus
    public var tool: String
    public var summary: String
    public var isTruncated: Bool
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        requestId: UUID,
        sessionId: String,
        status: ApprovalStatus,
        tool: String,
        summary: String,
        isTruncated: Bool,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.status = status
        self.tool = tool
        self.summary = summary
        self.isTruncated = isTruncated
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// A decision the phone sends back. Untrusted input: the Mac only applies it when `requestId` is
/// currently pending and unexpired, and always records it as `.phone` whatever `source` claims.
public struct DecisionRecord: Codable, Sendable, Equatable {
    public var requestId: UUID
    public var decision: Decision
    public var decidedAt: Date
    public var source: DecisionSource

    public init(requestId: UUID, decision: Decision, decidedAt: Date, source: DecisionSource) {
        self.requestId = requestId
        self.decision = decision
        self.decidedAt = decidedAt
        self.source = source
    }
}

/// What the phone sees of one question (`AskUserQuestion`) waiting for an answer. `status` is
/// `.pending` while it can be answered, then `.resolved` (answered, released or cancelled) or `.expired`.
public struct QuestionRecord: Codable, Sendable, Equatable {
    public var requestId: UUID
    public var sessionId: String
    public var status: ApprovalStatus
    public var questions: [AskQuestion]
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        requestId: UUID,
        sessionId: String,
        status: ApprovalStatus,
        questions: [AskQuestion],
        createdAt: Date,
        expiresAt: Date
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.status = status
        self.questions = questions
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// An answer the phone sends back: the chosen option labels per question, by question index.
/// Untrusted input: the Mac only applies it when it is valid for the question that is currently
/// pending and unexpired (see `PhoneBridge`), and always records it as `.phone`.
public struct AnswerRecord: Codable, Sendable, Equatable {
    public var requestId: UUID
    public var responses: [[String]]
    public var answeredAt: Date

    public init(requestId: UUID, responses: [[String]], answeredAt: Date) {
        self.requestId = requestId
        self.responses = responses
        self.answeredAt = answeredAt
    }
}

/// The Mac's side of the phone link (CloudKit in production, `InMemoryCloud` in tests).
public protocol PhoneTransport: Sendable {
    func publish(session: SessionRecord) async throws
    func removeSession(id: String) async throws
    func publish(approval: ApprovalRecord) async throws
    func decisions() -> AsyncStream<DecisionRecord>
    func publish(question: QuestionRecord) async throws
    func answers() -> AsyncStream<AnswerRecord>
    func deleteRecords(olderThan: Date) async throws
}

/// Thrown by `PhoneClientTransport.submit(decision:)` when a different decision for the same request was saved
/// first (an earlier tap whose reply was lost, another device). The earlier one is what the Mac acts on;
/// `decision` is it when the transport could read it back.
public struct DecisionAlreadyRecorded: Error, Equatable {
    public let decision: Decision?

    public init(decision: Decision?) {
        self.decision = decision
    }
}

/// Thrown by `PhoneClientTransport.submit(answer:)` when a different answer for the same question was saved
/// first (an earlier tap whose reply was lost, another device). The earlier one is what the Mac acts on;
/// `responses` is it when the transport could read it back.
public struct AnswerAlreadyRecorded: Error, Equatable {
    public let responses: [[String]]?

    public init(responses: [[String]]?) {
        self.responses = responses
    }
}

/// The phone's side of the phone link.
public protocol PhoneClientTransport: Sendable {
    /// The full current set on subscribe, then the full set after every change.
    func sessions() -> AsyncStream<[SessionRecord]>
    /// The full current set on subscribe, then the full set after every change.
    func approvals() -> AsyncStream<[ApprovalRecord]>
    /// Saves the decision. The first decision saved for a request stands: saving the same one again succeeds,
    /// a different one throws `DecisionAlreadyRecorded` (transports that cannot tell may accept it silently;
    /// the Mac still only acts on the first).
    func submit(decision: DecisionRecord) async throws
    /// The full current set on subscribe, then the full set after every change.
    func questions() -> AsyncStream<[QuestionRecord]>
    /// Saves the answer for the Mac to apply. The first answer saved for a question stands: saving the same one
    /// again succeeds, a different one throws `AnswerAlreadyRecorded` (transports that cannot tell may accept it
    /// silently; the Mac still only acts on the first valid one).
    func submit(answer: AnswerRecord) async throws
}
