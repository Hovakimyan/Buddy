import BuddyKit
@preconcurrency import CloudKit
import Foundation

/// Names and keys of Buddy's CloudKit schema (spec section 4.5) and the pure mappings between the
/// transport records and `CKRecord`. Foundation and CloudKit only, so the iPhone app can share it.
///
/// Sensitive fields (`project`, `lastTool`, `tool`, `summary`, `questions`, `responses`) are written ONLY through
/// `CKRecord.encryptedValues`; the other keys are plain so they can be queried and displayed.
/// Record names are deterministic (`sessionId` for Session, the request UUID for Approval and
/// Decision, Question and Answer), so republishing a record is an upsert and a Decision or Answer is unique
/// per request. A record name is unique per zone across ALL record types, so the Decision for a request
/// cannot reuse the request's own name (its Approval has it): it is `decision-<uuid>`. Likewise an Answer
/// is `answer-<uuid>`, because its Question has the bare request id.
enum CloudKitSchema {
    static let containerIdentifier = "iCloud.com.sergeyhovakimyan.buddy"
    static let zoneName = "Buddy"
    /// The custom zone (private database) holding every record. Created on demand.
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    static let approvalSubscriptionID = "buddy.approval.created"
    static let decisionSubscriptionID = "buddy.decision.created"
    static let questionSubscriptionID = "buddy.question.created"
    static let answerSubscriptionID = "buddy.answer.created"

    /// Notification category of the phone's actionable approval notification.
    static let approvalCategory = "BUDDY_APPROVAL"
    /// The push text. Generic on purpose: the command and project never appear in a push payload;
    /// the phone app fetches the encrypted record itself.
    static let approvalAlertBody = "Claude Code needs approval"
    /// Notification category of the phone's question notification.
    static let questionCategory = "BUDDY_QUESTION"
    /// The push text for a question. Generic like the approval one: the questions and options never appear
    /// in a push payload.
    static let questionAlertBody = "Claude is asking"

    enum RecordType {
        static let session = "Session"
        static let approval = "Approval"
        static let decision = "Decision"
        static let question = "Question"
        static let answer = "Answer"
    }

    enum Key {
        static let sessionId = "sessionId"
        static let state = "state"
        static let updatedAt = "updatedAt"
        static let requestId = "requestId"
        static let status = "status"
        static let createdAt = "createdAt"
        static let expiresAt = "expiresAt"
        static let isTruncated = "isTruncated"
        static let decision = "decision"
        static let decidedAt = "decidedAt"
        static let source = "source"
        static let answeredAt = "answeredAt"
        // Encrypted (only ever read or written through `encryptedValues`).
        static let project = "project"
        static let lastTool = "lastTool"
        static let tool = "tool"
        static let summary = "summary"
        /// JSON of `[AskQuestion]`.
        static let questions = "questions"
        /// JSON of `[[String]]`.
        static let responses = "responses"
    }

    static func decisionRecordName(for requestId: UUID) -> String { "decision-\(requestId.uuidString)" }
    static func answerRecordName(for requestId: UUID) -> String { "answer-\(requestId.uuidString)" }

    /// The JSON bytes of an encrypted structured field. Strings, bools and arrays of them always encode,
    /// so the empty fallback (which no reader accepts) is unreachable in practice.
    static func json<Value: Encodable>(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }

    // MARK: Subscriptions

    /// Alert push for a new `Approval` (wakes the phone). Fires on creation only: later status
    /// updates of the same record do not alert again.
    static func approvalSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RecordType.approval, predicate: NSPredicate(value: true),
            subscriptionID: approvalSubscriptionID, options: .firesOnRecordCreation)
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.alertBody = approvalAlertBody
        info.soundName = "default"
        info.category = approvalCategory
        subscription.notificationInfo = info
        return subscription
    }

    /// Silent push for a new `Decision` (wakes the Mac, which then fetches).
    static func decisionSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RecordType.decision, predicate: NSPredicate(value: true),
            subscriptionID: decisionSubscriptionID, options: .firesOnRecordCreation)
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    /// Alert push for a new `Question` (wakes the phone). Fires on creation only, like the approval one.
    static func questionSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RecordType.question, predicate: NSPredicate(value: true),
            subscriptionID: questionSubscriptionID, options: .firesOnRecordCreation)
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.alertBody = questionAlertBody
        info.soundName = "default"
        info.category = questionCategory
        subscription.notificationInfo = info
        return subscription
    }

    /// Silent push for a new `Answer` (wakes the Mac, which then fetches).
    static func answerSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RecordType.answer, predicate: NSPredicate(value: true),
            subscriptionID: answerSubscriptionID, options: .firesOnRecordCreation)
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }
}

// MARK: - Writing

extension CKRecord {
    convenience init(from session: SessionRecord, zoneID: CKRecordZone.ID = CloudKitSchema.zoneID) {
        typealias K = CloudKitSchema.Key
        // A bad record name raises an exception; `HookEvent.parse` only lets through session ids that are
        // safe here (printable ASCII, at most 200 characters, no leading "_").
        self.init(
            recordType: CloudKitSchema.RecordType.session,
            recordID: CKRecord.ID(recordName: session.sessionId, zoneID: zoneID))
        self[K.sessionId] = session.sessionId
        self[K.state] = session.state.rawValue
        self[K.updatedAt] = session.updatedAt
        encryptedValues[K.project] = session.project
        // Saved with `.allKeys`, which overwrites the keys present here but does NOT clear keys absent from
        // this record: once a server-side `lastTool` exists, a later nil `lastTool` leaves the old value.
        // Currently harmless (a session's lastTool is never cleared by the engine); to clear it, write an
        // explicit empty string instead of omitting the key.
        if let lastTool = session.lastTool { encryptedValues[K.lastTool] = lastTool }
    }

    convenience init(from approval: ApprovalRecord, zoneID: CKRecordZone.ID = CloudKitSchema.zoneID) {
        typealias K = CloudKitSchema.Key
        self.init(
            recordType: CloudKitSchema.RecordType.approval,
            recordID: CKRecord.ID(recordName: approval.requestId.uuidString, zoneID: zoneID))
        self[K.requestId] = approval.requestId.uuidString
        self[K.sessionId] = approval.sessionId
        self[K.status] = approval.status.rawValue
        self[K.createdAt] = approval.createdAt
        self[K.expiresAt] = approval.expiresAt
        // CloudKit has no Boolean field type: 0 / 1.
        self[K.isTruncated] = Int64(approval.isTruncated ? 1 : 0)
        encryptedValues[K.tool] = approval.tool
        encryptedValues[K.summary] = approval.summary
    }

    convenience init(from decision: DecisionRecord, zoneID: CKRecordZone.ID = CloudKitSchema.zoneID) {
        typealias K = CloudKitSchema.Key
        self.init(
            recordType: CloudKitSchema.RecordType.decision,
            recordID: CKRecord.ID(recordName: CloudKitSchema.decisionRecordName(for: decision.requestId), zoneID: zoneID))
        self[K.requestId] = decision.requestId.uuidString
        self[K.decision] = decision.decision.rawValue
        self[K.decidedAt] = decision.decidedAt
        self[K.source] = decision.source.rawValue
    }

    convenience init(from question: QuestionRecord, zoneID: CKRecordZone.ID = CloudKitSchema.zoneID) {
        typealias K = CloudKitSchema.Key
        self.init(
            recordType: CloudKitSchema.RecordType.question,
            recordID: CKRecord.ID(recordName: question.requestId.uuidString, zoneID: zoneID))
        self[K.requestId] = question.requestId.uuidString
        self[K.sessionId] = question.sessionId
        self[K.status] = question.status.rawValue
        self[K.createdAt] = question.createdAt
        self[K.expiresAt] = question.expiresAt
        encryptedValues[K.questions] = CloudKitSchema.json(question.questions)
    }

    convenience init(from answer: AnswerRecord, zoneID: CKRecordZone.ID = CloudKitSchema.zoneID) {
        typealias K = CloudKitSchema.Key
        self.init(
            recordType: CloudKitSchema.RecordType.answer,
            recordID: CKRecord.ID(recordName: CloudKitSchema.answerRecordName(for: answer.requestId), zoneID: zoneID))
        self[K.requestId] = answer.requestId.uuidString
        self[K.answeredAt] = answer.answeredAt
        encryptedValues[K.responses] = CloudKitSchema.json(answer.responses)
    }
}

// MARK: - Reading (untrusted input: any problem means nil)

/// Typed reads that distinguish "absent" from "present with the wrong type".
private enum Field<Value> {
    case absent, wrongType, value(Value)
}

private extension CKRecord {
    func plain<T>(_ key: String, as type: T.Type = T.self) -> Field<T> {
        guard let raw = self[key] else { return .absent }
        guard let value = raw as? T else { return .wrongType }
        return .value(value)
    }

    func encrypted<T>(_ key: String, as type: T.Type = T.self) -> Field<T> {
        guard let raw = encryptedValues[key] else { return .absent }
        guard let value = raw as? T else { return .wrongType }
        return .value(value)
    }

    func requiredPlain<T>(_ key: String, as type: T.Type = T.self) -> T? {
        if case .value(let value) = plain(key, as: type) { return value }
        return nil
    }

    func requiredEncrypted<T>(_ key: String, as type: T.Type = T.self) -> T? {
        if case .value(let value) = encrypted(key, as: type) { return value }
        return nil
    }

    func requiredEnum<E: RawRepresentable>(_ key: String, as type: E.Type) -> E? where E.RawValue == String {
        requiredPlain(key, as: String.self).flatMap { E(rawValue: $0) }
    }

    /// The `requestId` field as a UUID, only if the record name is the one `expectedName` derives from it.
    func requestId(recordName expectedName: (UUID) -> String) -> UUID? {
        guard let text = requiredPlain(CloudKitSchema.Key.requestId, as: String.self),
            let id = UUID(uuidString: text), recordID.recordName == expectedName(id)
        else { return nil }
        return id
    }
}

private extension CKRecord {
    /// An encrypted JSON field decoded as `Value`: nil when absent, of another type, or not valid JSON for it.
    func requiredEncryptedJSON<Value: Decodable>(_ key: String, as type: Value.Type = Value.self) -> Value? {
        requiredEncrypted(key, as: Data.self).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }
}

extension SessionRecord {
    init?(from record: CKRecord) {
        typealias K = CloudKitSchema.Key
        guard record.recordType == CloudKitSchema.RecordType.session,
            let sessionId = record.requiredPlain(K.sessionId, as: String.self),
            record.recordID.recordName == sessionId,
            let state = record.requiredEnum(K.state, as: SessionState.self),
            let updatedAt = record.requiredPlain(K.updatedAt, as: Date.self),
            let project = record.requiredEncrypted(K.project, as: String.self)
        else { return nil }
        // Optional, but present-with-the-wrong-type means the record is not ours.
        let lastTool: String?
        switch record.encrypted(K.lastTool, as: String.self) {
        case .absent: lastTool = nil
        case .value(let value): lastTool = value
        case .wrongType: return nil
        }
        // A plain `project` key means the writer did not use encrypted values.
        if record[K.project] != nil || record[K.lastTool] != nil { return nil }
        self.init(sessionId: sessionId, state: state, project: project, lastTool: lastTool, updatedAt: updatedAt)
    }
}

extension ApprovalRecord {
    init?(from record: CKRecord) {
        typealias K = CloudKitSchema.Key
        guard record.recordType == CloudKitSchema.RecordType.approval,
            let requestId = record.requestId(recordName: \.uuidString),
            let sessionId = record.requiredPlain(K.sessionId, as: String.self),
            let status = record.requiredEnum(K.status, as: ApprovalStatus.self),
            let createdAt = record.requiredPlain(K.createdAt, as: Date.self),
            let expiresAt = record.requiredPlain(K.expiresAt, as: Date.self),
            let truncated = record.requiredPlain(K.isTruncated, as: Int64.self), truncated == 0 || truncated == 1,
            let tool = record.requiredEncrypted(K.tool, as: String.self),
            let summary = record.requiredEncrypted(K.summary, as: String.self),
            record[K.tool] == nil, record[K.summary] == nil
        else { return nil }
        self.init(
            requestId: requestId, sessionId: sessionId, status: status, tool: tool, summary: summary,
            isTruncated: truncated == 1, createdAt: createdAt, expiresAt: expiresAt)
    }
}

extension DecisionRecord {
    /// `source` is read as written but is not trustworthy: the Mac records every phone decision as `.phone`.
    init?(from record: CKRecord) {
        typealias K = CloudKitSchema.Key
        guard record.recordType == CloudKitSchema.RecordType.decision,
            let requestId = record.requestId(recordName: CloudKitSchema.decisionRecordName(for:)),
            let decision = record.requiredEnum(K.decision, as: Decision.self),
            let decidedAt = record.requiredPlain(K.decidedAt, as: Date.self),
            let source = record.requiredEnum(K.source, as: DecisionSource.self)
        else { return nil }
        self.init(requestId: requestId, decision: decision, decidedAt: decidedAt, source: source)
    }
}

extension QuestionRecord {
    init?(from record: CKRecord) {
        typealias K = CloudKitSchema.Key
        guard record.recordType == CloudKitSchema.RecordType.question,
            let requestId = record.requestId(recordName: \.uuidString),
            let sessionId = record.requiredPlain(K.sessionId, as: String.self),
            let status = record.requiredEnum(K.status, as: ApprovalStatus.self),
            let createdAt = record.requiredPlain(K.createdAt, as: Date.self),
            let expiresAt = record.requiredPlain(K.expiresAt, as: Date.self),
            let questions = record.requiredEncryptedJSON(K.questions, as: [AskQuestion].self),
            record[K.questions] == nil
        else { return nil }
        self.init(
            requestId: requestId, sessionId: sessionId, status: status, questions: questions,
            createdAt: createdAt, expiresAt: expiresAt)
    }
}

extension AnswerRecord {
    /// Untrusted input like `DecisionRecord`: the shape is checked here, whether the responses fit the
    /// pending question is `PhoneBridge`'s job.
    init?(from record: CKRecord) {
        typealias K = CloudKitSchema.Key
        guard record.recordType == CloudKitSchema.RecordType.answer,
            let requestId = record.requestId(recordName: CloudKitSchema.answerRecordName(for:)),
            let answeredAt = record.requiredPlain(K.answeredAt, as: Date.self),
            let responses = record.requiredEncryptedJSON(K.responses, as: [[String]].self),
            record[K.responses] == nil
        else { return nil }
        self.init(requestId: requestId, responses: responses, answeredAt: answeredAt)
    }
}
