import BuddyKit
@preconcurrency import CloudKit
import Foundation
import OSLog
import Synchronization

/// The phone link over CloudKit: the user's private database, custom zone `Buddy` (spec 4.5).
///
/// One class serves both ends. The Mac uses it as `PhoneTransport`, the iPhone as `PhoneClientTransport`;
/// `role` only decides which push subscriptions this device registers (a subscription belongs to the
/// device that saved it): the Mac wants `Decision` and `Answer` creations, the phone wants `Approval` and
/// `Question` creations.
///
/// Reliability. The Mac never depends on pushes alone: while at least one approval it published is
/// (or question) it published is still pending and unexpired it also polls the zone's change feed every
/// `pollInterval`, and a silent push (`handleRemoteNotification`) triggers an immediate fetch. Decisions and
/// answers come out of one change feed. Each is deduplicated by request id, first one wins, and is untrusted
/// input (`PhoneBridge` validates them). Publishing errors are thrown
/// so `PhoneBridge` retries with backoff; the Mac works without CloudKit.
///
/// Create it only in a process that has the CloudKit entitlement: `CKContainer(identifier:)` raises an
/// Objective-C exception otherwise (see `live(role:)`).
final class CloudKitTransport: PhoneTransport, PhoneClientTransport, Sendable {
    enum Role: Sendable { case mac, phone }

    /// Longest server `retryAfter` hint the transport sleeps through itself (once); anything longer is
    /// thrown to the caller's own backoff.
    static let maxInlineRetryAfter: TimeInterval = 8
    /// Most records one `deleteRecords` call removes (CloudKit allows 400 per request).
    static let deleteBatchLimit = 200
    /// Least time between two attempts to save a subscription that keeps failing.
    static let subscriptionRetryInterval: TimeInterval = 60

    private struct Flight {
        var running = false
        var again = false
    }

    private struct State {
        var setupTask: Task<Void, Error>?
        /// The push subscriptions are saved separately from the zone, each on its own, and the missing ones
        /// retried (at most every `subscriptionRetryInterval`) until each has succeeded once.
        var savedSubscriptions: Set<String> = []
        var subscriptionAttemptInFlight = false
        var lastSubscriptionAttempt: Date?

        // Mac: decision and answer intake (one change feed).
        var decisionToken: Data?
        var delivered: [UUID: DecisionRecord] = [:]
        var deliveredAnswers: [UUID: AnswerRecord] = [:]
        /// Messages seen and not yet consumed (`consume(message:)` deletes them, then they leave here).
        var deliveredMessages: [UUID: MessageRecord] = [:]
        var decisionSubscribers: [UUID: AsyncStream<DecisionRecord>.Continuation] = [:]
        var answerSubscribers: [UUID: AsyncStream<AnswerRecord>.Continuation] = [:]
        var messageSubscribers: [UUID: AsyncStream<MessageRecord>.Continuation] = [:]
        var decisionFlight = Flight()
        /// Approvals and questions published pending and not yet resolved/expired, by request id: the poll
        /// runs while this is non-empty.
        var outstanding: [UUID: Date] = [:]
        var pollTask: Task<Void, Never>?
        /// Mac: a slow fetch that runs while someone listens for messages, in case a push never comes.
        var messagePollTask: Task<Void, Never>?
        /// Sessions this run published: owned by `removeSession`, never aged out by `deleteRecords`.
        var publishedSessions: Set<String> = []

        // Phone: a local mirror of the zone.
        var phoneToken: Data?
        var sessionCache: [String: SessionRecord] = [:]
        var approvalCache: [UUID: ApprovalRecord] = [:]
        var questionCache: [UUID: QuestionRecord] = [:]
        var loaded = false
        var sessionSubscribers: [UUID: AsyncStream<[SessionRecord]>.Continuation] = [:]
        var approvalSubscribers: [UUID: AsyncStream<[ApprovalRecord]>.Continuation] = [:]
        var questionSubscribers: [UUID: AsyncStream<[QuestionRecord]>.Continuation] = [:]
        var refreshFlight = Flight()
        var phonePollTask: Task<Void, Never>?

        var sessionSnapshot: [SessionRecord] { sessionCache.values.sorted { $0.sessionId < $1.sessionId } }
        var approvalSnapshot: [ApprovalRecord] {
            approvalCache.values.sorted { ($0.createdAt, $0.requestId.uuidString) < ($1.createdAt, $1.requestId.uuidString) }
        }
        var questionSnapshot: [QuestionRecord] {
            questionCache.values.sorted { ($0.createdAt, $0.requestId.uuidString) < ($1.createdAt, $1.requestId.uuidString) }
        }
    }

    private let role: Role
    private let database: any CloudDatabase
    private let clock: @Sendable () -> Date
    private let pollInterval: Duration
    private let phonePollInterval: Duration
    private let messagePollInterval: Duration
    private let state = Mutex(State())
    private let log = Logger(subsystem: "com.sergeyhovakimyan.buddy", category: "cloudkit")

    init(
        role: Role,
        database: any CloudDatabase,
        clock: @escaping @Sendable () -> Date = Date.init,
        pollInterval: Duration = .seconds(2),
        phonePollInterval: Duration = .seconds(3),
        messagePollInterval: Duration = .seconds(5)
    ) {
        self.role = role
        self.database = database
        self.clock = clock
        self.pollInterval = pollInterval
        self.phonePollInterval = phonePollInterval
        self.messagePollInterval = messagePollInterval
    }

    /// The real transport on `iCloud.com.sergeyhovakimyan.buddy`'s private database. Only call it when the
    /// process has the iCloud/CloudKit entitlement (BuddyMac checks `CloudEntitlement` first).
    static func live(role: Role) -> CloudKitTransport {
        let container = CKContainer(identifier: CloudKitSchema.containerIdentifier)
        return CloudKitTransport(role: role, database: CKDatabaseAdapter(database: container.privateCloudDatabase))
    }

    deinit {
        state.withLock {
            $0.pollTask?.cancel()
            $0.phonePollTask?.cancel()
            $0.messagePollTask?.cancel()
            for continuation in $0.decisionSubscribers.values { continuation.finish() }
            for continuation in $0.answerSubscribers.values { continuation.finish() }
            for continuation in $0.messageSubscribers.values { continuation.finish() }
            for continuation in $0.sessionSubscribers.values { continuation.finish() }
            for continuation in $0.approvalSubscribers.values { continuation.finish() }
            for continuation in $0.questionSubscribers.values { continuation.finish() }
        }
    }

    /// Stops all background work: cancels the polls and finishes every stream. The Mac calls it when the
    /// engine stops, so nothing keeps talking to CloudKit after quit. The transport can be used again
    /// afterwards (a new `decisions()` / `answers()` stream, a new published approval or question restart what
    /// they need).
    func stop() {
        let (tasks, continuations) = state.withLock { state -> ([Task<Void, Never>], [() -> Void]) in
            let tasks = [state.pollTask, state.phonePollTask, state.messagePollTask].compactMap { $0 }
            state.pollTask = nil
            state.phonePollTask = nil
            state.messagePollTask = nil
            state.outstanding = [:]
            let finishers: [() -> Void] =
                state.decisionSubscribers.values.map { c in { c.finish() } }
                + state.answerSubscribers.values.map { c in { c.finish() } }
                + state.messageSubscribers.values.map { c in { c.finish() } }
                + state.sessionSubscribers.values.map { c in { c.finish() } }
                + state.approvalSubscribers.values.map { c in { c.finish() } }
                + state.questionSubscribers.values.map { c in { c.finish() } }
            state.decisionSubscribers = [:]
            state.answerSubscribers = [:]
            state.messageSubscribers = [:]
            state.sessionSubscribers = [:]
            state.approvalSubscribers = [:]
            state.questionSubscribers = [:]
            return (tasks, finishers)
        }
        for task in tasks { task.cancel() }
        for finish in continuations { finish() }
    }

    // MARK: Push entry point

    /// Call from `application(_:didReceiveRemoteNotification:)`. Returns whether the push was one of
    /// Buddy's subscriptions (the fetch it triggers runs in the background).
    @discardableResult
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return handleNotification(subscriptionID: notification.subscriptionID)
    }

    @discardableResult
    func handleNotification(subscriptionID: String?) -> Bool {
        switch subscriptionID {
        case CloudKitSchema.decisionSubscriptionID, CloudKitSchema.answerSubscriptionID, CloudKitSchema.messageSubscriptionID:
            Task { await pullPhoneInput() }
        case CloudKitSchema.approvalSubscriptionID, CloudKitSchema.questionSubscriptionID:
            Task { await refresh() }
        default:
            return false
        }
        return true
    }

    // MARK: PhoneTransport (Mac)

    func publish(session: SessionRecord) async throws {
        let record = CKRecord(from: session)
        try await perform { try await database.save([record], policy: .allKeys) }
        state.withLock { _ = $0.publishedSessions.insert(session.sessionId) }
    }

    func removeSession(id: String) async throws {
        state.withLock { _ = $0.publishedSessions.remove(id) }
        let recordID = CKRecord.ID(recordName: id, zoneID: CloudKitSchema.zoneID)
        do {
            try await perform { try await database.delete([recordID]) }
        } catch where CloudKitFailure.classify(error) == .zoneNotFound {
            return  // no zone, nothing to remove
        }
    }

    func publish(approval: ApprovalRecord) async throws {
        let record = CKRecord(from: approval)
        let started = clock()
        try await perform { try await database.save([record], policy: .allKeys) }
        let took = Self.milliseconds(since: started, now: clock())
        log.notice("approval \(approval.requestId, privacy: .public) \(approval.status.rawValue, privacy: .public) saved in \(took, privacy: .public) ms")
        track(approval)
    }

    func decisions() -> AsyncStream<DecisionRecord> {
        let (stream, continuation) = AsyncStream<DecisionRecord>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.decisionSubscribers[id] = nil }
        }
        state.withLock { state in
            state.decisionSubscribers[id] = continuation
            for decision in state.delivered.values.sorted(by: { $0.decidedAt < $1.decidedAt }) {
                continuation.yield(decision)
            }
        }
        // Sets up the zone and subscription, then delivers any Decision already in the zone.
        Task { [weak self] in await self?.pullPhoneInput() }
        return stream
    }

    func publish(question: QuestionRecord) async throws {
        let record = CKRecord(from: question)
        let started = clock()
        try await perform { try await database.save([record], policy: .allKeys) }
        let took = Self.milliseconds(since: started, now: clock())
        log.notice("question \(question.requestId, privacy: .public) \(question.status.rawValue, privacy: .public) saved in \(took, privacy: .public) ms")
        track(requestId: question.requestId, pending: question.status == .pending, expiresAt: question.expiresAt)
    }

    func answers() -> AsyncStream<AnswerRecord> {
        let (stream, continuation) = AsyncStream<AnswerRecord>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.answerSubscribers[id] = nil }
        }
        state.withLock { state in
            state.answerSubscribers[id] = continuation
            for answer in state.deliveredAnswers.values.sorted(by: { $0.answeredAt < $1.answeredAt }) {
                continuation.yield(answer)
            }
        }
        // Sets up the zone and subscription, then delivers any Answer already in the zone.
        Task { [weak self] in await self?.pullPhoneInput() }
        return stream
    }

    func messages() -> AsyncStream<MessageRecord> {
        let (stream, continuation) = AsyncStream<MessageRecord>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.messageSubscribers[id] = nil }
        }
        state.withLock { state in
            state.messageSubscribers[id] = continuation
            for message in state.deliveredMessages.values.sorted(by: { $0.sentAt < $1.sentAt }) {
                continuation.yield(message)
            }
        }
        // Sets up the zone and subscription, then delivers any Message already in the zone.
        Task { [weak self] in await self?.pullPhoneInput() }
        // Messages have no request to bound a poll by: a slow one stands in for a lost push.
        state.withLock { state in
            guard state.messagePollTask == nil else { return }
            let interval = messagePollInterval
            state.messagePollTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    guard let self else { return }
                    await self.pullPhoneInput()
                }
            }
        }
        return stream
    }

    /// Deletes a message the Mac took, so no later run delivers it again.
    func consume(message id: UUID) async throws {
        let recordID = CKRecord.ID(recordName: CloudKitSchema.messageRecordName(for: id), zoneID: CloudKitSchema.zoneID)
        try await perform { try await database.delete([recordID]) }
        state.withLock { _ = $0.deliveredMessages.removeValue(forKey: id) }
    }

    /// Deletes records the server last modified before `olderThan`: Approvals, Questions, Decisions, Answers, Messages, and Sessions
    /// this run did not publish (orphans of an earlier run; a live session's record is owned by
    /// `removeSession`, even if it has been quiet for a while). At most `deleteBatchLimit` per call; the
    /// next cleanup takes the rest.
    func deleteRecords(olderThan: Date) async throws {
        let changes: ZoneChanges
        do {
            changes = try await perform { try await database.changes(in: CloudKitSchema.zoneID, since: nil) }
        } catch where CloudKitFailure.classify(error) == .zoneNotFound {
            return
        }
        let published = state.withLock { $0.publishedSessions }
        var doomed: [CKRecord.ID] = []
        for changed in changes.records {
            guard let modified = changed.modifiedAt, modified < olderThan else { continue }
            switch changed.record.recordType {
            case CloudKitSchema.RecordType.approval, CloudKitSchema.RecordType.decision,
                CloudKitSchema.RecordType.question, CloudKitSchema.RecordType.answer, CloudKitSchema.RecordType.message:
                doomed.append(changed.record.recordID)
            case CloudKitSchema.RecordType.session where !published.contains(changed.record.recordID.recordName):
                doomed.append(changed.record.recordID)
            default:
                continue
            }
            if doomed.count == Self.deleteBatchLimit { break }
        }
        guard !doomed.isEmpty else { return }
        try await perform { try await database.delete(doomed) }
        let gone = Set(doomed.map(\.recordName))
        state.withLock { state in
            state.delivered = state.delivered.filter { !gone.contains(CloudKitSchema.decisionRecordName(for: $0.key)) }
            state.deliveredAnswers = state.deliveredAnswers.filter { !gone.contains(CloudKitSchema.answerRecordName(for: $0.key)) }
            state.deliveredMessages = state.deliveredMessages.filter { !gone.contains(CloudKitSchema.messageRecordName(for: $0.key)) }
        }
    }

    /// Deletes every Session record this run did not publish (see `PhoneTransport.removeUnownedSessions`).
    func removeUnownedSessions() async throws {
        let changes: ZoneChanges
        do {
            changes = try await perform { try await database.changes(in: CloudKitSchema.zoneID, since: nil) }
        } catch where CloudKitFailure.classify(error) == .zoneNotFound {
            return
        }
        let published = state.withLock { $0.publishedSessions }
        let leftovers = changes.records
            .filter { $0.record.recordType == CloudKitSchema.RecordType.session }
            .map(\.record.recordID)
            .filter { !published.contains($0.recordName) }
            .prefix(Self.deleteBatchLimit)
        guard !leftovers.isEmpty else { return }
        try await perform { try await database.delete(Array(leftovers)) }
        log.notice("removed \(leftovers.count, privacy: .public) session records left by an earlier run")
    }

    // MARK: PhoneClientTransport (iPhone)

    func sessions() -> AsyncStream<[SessionRecord]> {
        let (stream, continuation) = AsyncStream<[SessionRecord]>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.phoneSubscriberEnded { $0.sessionSubscribers[id] = nil } }
        state.withLock { state in
            state.sessionSubscribers[id] = continuation
            if state.loaded { continuation.yield(state.sessionSnapshot) }
        }
        startPhoneRefresh()
        return stream
    }

    func approvals() -> AsyncStream<[ApprovalRecord]> {
        let (stream, continuation) = AsyncStream<[ApprovalRecord]>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.phoneSubscriberEnded { $0.approvalSubscribers[id] = nil } }
        state.withLock { state in
            state.approvalSubscribers[id] = continuation
            if state.loaded { continuation.yield(state.approvalSnapshot) }
        }
        startPhoneRefresh()
        return stream
    }

    /// Writes the decision once per request: the record name is the request id and the save refuses to
    /// overwrite, so a second decision for the same request (a double tap, a retry) changes nothing. When the
    /// one already saved is the same decision (a retry whose reply was lost) that is success; otherwise
    /// `DecisionAlreadyRecorded` says which one stands, so the phone never shows an answer that did not count.
    func submit(decision: DecisionRecord) async throws {
        let record = CKRecord(from: decision)
        try await perform {
            do {
                try await database.save([record], policy: .ifServerRecordUnchanged)
            } catch where CloudKitFailure.classify(error) == .serverRecordChanged {
                let existing = CloudKitFailure.serverRecord(of: error).flatMap { DecisionRecord(from: $0) }
                guard let existing, existing.requestId == decision.requestId, existing.decision == decision.decision
                else { throw DecisionAlreadyRecorded(decision: existing?.decision) }
            }
        }
    }

    func questions() -> AsyncStream<[QuestionRecord]> {
        let (stream, continuation) = AsyncStream<[QuestionRecord]>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.phoneSubscriberEnded { $0.questionSubscribers[id] = nil } }
        state.withLock { state in
            state.questionSubscribers[id] = continuation
            if state.loaded { continuation.yield(state.questionSnapshot) }
        }
        startPhoneRefresh()
        return stream
    }

    /// Writes the answer once per request: the record name derives from the request id and the save refuses
    /// to overwrite, so a second answer for the same question (a double tap, a retry) changes nothing and the
    /// first one stands, which is also the one the Mac acts on. When the one already saved has the same
    /// responses (a retry whose reply was lost) that is success; otherwise `AnswerAlreadyRecorded` says which
    /// one stands, so the phone never shows an answer that did not count.
    func submit(answer: AnswerRecord) async throws {
        let record = CKRecord(from: answer)
        try await perform {
            do {
                try await database.save([record], policy: .ifServerRecordUnchanged)
            } catch where CloudKitFailure.classify(error) == .serverRecordChanged {
                let existing = CloudKitFailure.serverRecord(of: error).flatMap { AnswerRecord(from: $0) }
                guard let existing, existing.requestId == answer.requestId, existing.responses == answer.responses
                else { throw AnswerAlreadyRecorded(responses: existing?.responses) }
            }
        }
    }

    /// Saves a message for the Mac. Its id is new every time, so there is nothing to collide with.
    func submit(message: MessageRecord) async throws {
        let record = CKRecord(from: message)
        try await perform { try await database.save([record], policy: .allKeys) }
    }

    /// Fetches the zone's changes and publishes the new full sets to `sessions()` / `approvals()` / `questions()`.
    /// Called on subscribe, on a push, by the foreground poll, and by the app (pull to refresh).
    func refresh() async {
        await singleFlight(\.refreshFlight) { await refreshOnce() }
    }

    // MARK: Decision and answer intake

    /// Fetches the zone's changes and delivers the new Decisions and Answers (one feed, one token, so a
    /// fetch for one never makes the other miss out: whatever has no subscriber yet is replayed to the next).
    func pullPhoneInput() async {
        await singleFlight(\.decisionFlight) { await pullPhoneInputOnce() }
    }

    private func pullPhoneInputOnce() async {
        let token = state.withLock { $0.decisionToken }
        do {
            let changes = try await perform { try await database.changes(in: CloudKitSchema.zoneID, since: token) }
            state.withLock { state in
                state.decisionToken = changes.token ?? state.decisionToken
                var fresh: [DecisionRecord] = []
                var freshAnswers: [AnswerRecord] = []
                var freshMessages: [MessageRecord] = []
                for changed in changes.records {
                    switch changed.record.recordType {
                    case CloudKitSchema.RecordType.decision:
                        guard let decision = DecisionRecord(from: changed.record),
                            state.delivered[decision.requestId] == nil
                        else { continue }
                        state.delivered[decision.requestId] = decision
                        fresh.append(decision)
                    case CloudKitSchema.RecordType.answer:
                        guard let answer = AnswerRecord(from: changed.record),
                            state.deliveredAnswers[answer.requestId] == nil
                        else { continue }
                        state.deliveredAnswers[answer.requestId] = answer
                        freshAnswers.append(answer)
                    case CloudKitSchema.RecordType.message:
                        guard let message = MessageRecord(from: changed.record),
                            state.deliveredMessages[message.messageId] == nil
                        else { continue }
                        state.deliveredMessages[message.messageId] = message
                        freshMessages.append(message)
                    default:
                        continue
                    }
                }
                for continuation in state.decisionSubscribers.values {
                    for decision in fresh { continuation.yield(decision) }
                }
                for continuation in state.answerSubscribers.values {
                    for answer in freshAnswers { continuation.yield(answer) }
                }
                for continuation in state.messageSubscribers.values {
                    for message in freshMessages { continuation.yield(message) }
                }
                // How long the phone's tap took to get here (the phone's clock, so roughly): the delay people feel.
                let now = clock()
                for decision in fresh {
                    let late = Self.milliseconds(since: decision.decidedAt, now: now)
                    log.notice("decision for \(decision.requestId, privacy: .public) arrived \(late, privacy: .public) ms after the tap")
                }
                for answer in freshAnswers {
                    let late = Self.milliseconds(since: answer.answeredAt, now: now)
                    log.notice("answer for \(answer.requestId, privacy: .public) arrived \(late, privacy: .public) ms after the tap")
                }
            }
        } catch {
            if CloudKitFailure.classify(error) == .changeTokenExpired {
                state.withLock { $0.decisionToken = nil }
            }
            log.error("decision/answer fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func milliseconds(since start: Date, now: Date) -> Int { Int((now.timeIntervalSince(start) * 1000).rounded()) }

    /// Records a published approval for the bounded poll, and starts the poll if it is not running.
    private func track(_ approval: ApprovalRecord) {
        track(requestId: approval.requestId, pending: approval.status == .pending, expiresAt: approval.expiresAt)
    }

    /// Records a published approval or question for the bounded poll, and starts the poll if it is not running.
    private func track(requestId: UUID, pending: Bool, expiresAt: Date) {
        state.withLock { state in
            if pending, expiresAt > clock() {
                state.outstanding[requestId] = expiresAt
                if state.pollTask == nil {
                    let interval = pollInterval
                    state.pollTask = Task { [weak self] in
                        // `self` is held only inside a tick, never while sleeping, so a released transport stops polling.
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: interval) } catch { return }
                            guard let self, await self.pollTick() else { return }
                        }
                    }
                }
            } else {
                state.outstanding[requestId] = nil
            }
        }
    }

    /// One poll step: drops expired approvals and questions, then fetches decisions and answers. False (and
    /// the poll ends) when none tracked is pending and unexpired any more.
    private func pollTick() async -> Bool {
        let keepGoing = state.withLock { state -> Bool in
            let now = clock()
            state.outstanding = state.outstanding.filter { $0.value > now }
            if state.outstanding.isEmpty { state.pollTask = nil }
            return !state.outstanding.isEmpty
        }
        guard keepGoing else { return false }
        await pullPhoneInput()
        return true
    }

    // MARK: Phone mirror

    private func startPhoneRefresh() {
        state.withLock { state in
            if state.phonePollTask == nil {
                let interval = phonePollInterval
                state.phonePollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: interval) } catch { return }
                        guard let self else { return }
                        await self.refresh()
                    }
                }
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    private func phoneSubscriberEnded(_ remove: (inout State) -> Void) {
        state.withLock { state in
            remove(&state)
            if state.sessionSubscribers.isEmpty, state.approvalSubscribers.isEmpty, state.questionSubscribers.isEmpty {
                state.phonePollTask?.cancel()
                state.phonePollTask = nil
            }
        }
    }

    private func refreshOnce() async {
        let token = state.withLock { $0.phoneToken }
        do {
            let changes = try await perform { try await database.changes(in: CloudKitSchema.zoneID, since: token) }
            state.withLock { state in
                let sessionsBefore = state.sessionCache
                let approvalsBefore = state.approvalCache
                let questionsBefore = state.questionCache
                state.phoneToken = changes.token ?? state.phoneToken
                for changed in changes.records {
                    let record = changed.record
                    switch record.recordType {
                    case CloudKitSchema.RecordType.session:
                        // A record we cannot read replaces (removes) the one we had.
                        state.sessionCache[record.recordID.recordName] = SessionRecord(from: record)
                    case CloudKitSchema.RecordType.approval:
                        if let id = UUID(uuidString: record.recordID.recordName) {
                            state.approvalCache[id] = ApprovalRecord(from: record)
                        }
                    case CloudKitSchema.RecordType.question:
                        if let id = UUID(uuidString: record.recordID.recordName) {
                            state.questionCache[id] = QuestionRecord(from: record)
                        }
                    default:
                        continue
                    }
                }
                for deletion in changes.deletions {
                    switch deletion.recordType {
                    case CloudKitSchema.RecordType.session:
                        state.sessionCache[deletion.id.recordName] = nil
                    case CloudKitSchema.RecordType.approval:
                        if let id = UUID(uuidString: deletion.id.recordName) { state.approvalCache[id] = nil }
                    case CloudKitSchema.RecordType.question:
                        if let id = UUID(uuidString: deletion.id.recordName) { state.questionCache[id] = nil }
                    default:
                        continue
                    }
                }
                let first = !state.loaded
                state.loaded = true
                if first || state.sessionCache != sessionsBefore {
                    let snapshot = state.sessionSnapshot
                    for continuation in state.sessionSubscribers.values { continuation.yield(snapshot) }
                }
                if first || state.approvalCache != approvalsBefore {
                    let snapshot = state.approvalSnapshot
                    for continuation in state.approvalSubscribers.values { continuation.yield(snapshot) }
                }
                if first || state.questionCache != questionsBefore {
                    let snapshot = state.questionSnapshot
                    for continuation in state.questionSubscribers.values { continuation.yield(snapshot) }
                }
            }
        } catch {
            if CloudKitFailure.classify(error) == .changeTokenExpired {
                state.withLock { state in
                    state.phoneToken = nil
                    state.sessionCache = [:]
                    state.approvalCache = [:]
                    state.questionCache = [:]
                }
            }
            log.error("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Setup, retry

    /// Runs `operation` after the zone exists (and the subscription has been attempted). A vanished zone is recreated and the
    /// operation retried once; a transient failure that carries a short server `retryAfter` is retried
    /// once after that delay. Everything else is thrown (PhoneBridge's own backoff retries publishes).
    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        var repairedZone = false
        var waited = false
        while true {
            do {
                try await ensureSetup()
                await ensureSubscription()
                return try await operation()
            } catch {
                switch CloudKitFailure.classify(error) {
                case .zoneNotFound where !repairedZone:
                    repairedZone = true
                    state.withLock { state in
                        state.setupTask = nil
                        // A recreated zone has no subscriptions.
                        state.savedSubscriptions = []
                        state.lastSubscriptionAttempt = nil
                    }
                case .retryable(let after?) where !waited && after <= Self.maxInlineRetryAfter:
                    waited = true
                    try await Task.sleep(for: .seconds(after))
                default:
                    throw error
                }
            }
        }
    }

    /// Creates the `Buddy` zone. Idempotent: concurrent callers share
    /// one attempt, and a failed attempt is forgotten so the next call tries again.
    private func ensureSetup() async throws {
        let task = state.withLock { state -> Task<Void, Error> in
            if let existing = state.setupTask { return existing }
            let task = Task { try await self.performSetup() }
            state.setupTask = task
            return task
        }
        do {
            try await task.value
        } catch {
            state.withLock { if $0.setupTask == task { $0.setupTask = nil } }
            throw error
        }
    }

    private func performSetup() async throws {
        try await database.saveZone(CKRecordZone(zoneID: CloudKitSchema.zoneID))
    }

    /// Saves this device's push subscriptions until each has succeeded once (saving an existing subscription
    /// ID again just updates it). The Mac saves Decision and Answer, the phone Approval and Question; each is
    /// saved on its own, so a missing record type for one never holds back the other. They only speed things
    /// up (the Mac also polls, the phone also refreshes), so a failure never stops records flowing: it is
    /// logged and the missing ones tried again on a later operation, at most once per
    /// `subscriptionRetryInterval`. In a fresh Development schema the record type must exist before a query
    /// subscription on it can be saved, so the first attempts can fail until the first record of that type
    /// has been written (see docs/cloudkit-setup.md).
    private func ensureSubscription() async {
        let wanted: [CKQuerySubscription] =
            role == .mac
            ? [CloudKitSchema.decisionSubscription(), CloudKitSchema.answerSubscription(), CloudKitSchema.messageSubscription()]
            : [CloudKitSchema.approvalSubscription(), CloudKitSchema.questionSubscription()]
        let attempt = state.withLock { state -> [CKQuerySubscription]? in
            let missing = wanted.filter { !state.savedSubscriptions.contains($0.subscriptionID) }
            guard !missing.isEmpty, !state.subscriptionAttemptInFlight else { return nil }
            let now = clock()
            if let last = state.lastSubscriptionAttempt, now.timeIntervalSince(last) < Self.subscriptionRetryInterval {
                return nil
            }
            state.subscriptionAttemptInFlight = true
            state.lastSubscriptionAttempt = now
            return missing
        }
        guard let attempt else { return }
        var saved: [String] = []
        for subscription in attempt {
            do {
                try await database.save(subscription: subscription)
                saved.append(subscription.subscriptionID)
                log.notice("subscription \(subscription.subscriptionID, privacy: .public) saved")
            } catch {
                log.error(
                    "subscription \(subscription.subscriptionID, privacy: .public) save failed (will retry later): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        state.withLock { state in
            state.subscriptionAttemptInFlight = false
            state.savedSubscriptions.formUnion(saved)
        }
    }

    /// Runs `body`; a call made while it runs makes it run once more afterwards instead of overlapping.
    private func singleFlight(_ flight: WritableKeyPath<State, Flight>, _ body: () async -> Void) async {
        let isFirst = state.withLock { state -> Bool in
            if state[keyPath: flight].running {
                state[keyPath: flight].again = true
                return false
            }
            state[keyPath: flight].running = true
            return true
        }
        guard isFirst else { return }
        while true {
            await body()
            let again = state.withLock { state -> Bool in
                if state[keyPath: flight].again {
                    state[keyPath: flight].again = false
                    return true
                }
                state[keyPath: flight].running = false
                return false
            }
            if !again { return }
        }
    }
}
