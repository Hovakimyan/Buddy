import BuddyKit
@preconcurrency import CloudKit
import OSLog
import UserNotifications

private let log = Logger(subsystem: "com.sergeyhovakimyan.buddy", category: "notification-service")

/// Runs when an approval or question push arrives, before iOS shows it. The push itself is generic ("Claude Code
/// needs approval"): this fetches the encrypted record from the private database and fills in the real text, adds
/// Buddy's picture, and picks the actions (Allow without opening the app only for a short, plain command). Whatever
/// fails, the original notification is shown, with Buddy. iOS hides the text on the lock screen until the iPhone is
/// unlocked (the default "Show Previews: When Unlocked").
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        fallback = content
        let target = Self.target(of: request.content.userInfo)
        let shape = Self.shape(of: request.content.userInfo)
        log.notice("push for \(target?.recordName ?? "nothing of ours", privacy: .public) (\(target.map { "\($0.kind)" } ?? "-", privacy: .public))")
        let handler = SendableHandler(contentHandler)
        let base = SendableContent(content)
        Task {
            var detail: NotificationDetail?
            var problem = "not a Buddy push: \(shape)"
            if let target { (detail, problem) = await Self.detail(for: target) }
            let filled = base.content
            #if DEBUG
            // Debug builds say why the text could not be filled in, on the notification itself.
            if detail == nil { filled.subtitle = "debug: \(problem)" }
            #endif
            if let detail {
                filled.title = detail.title
                filled.body = detail.body
                filled.userInfo[NotificationDetail.userInfoKey] = detail.userInfoValue
                if detail.kind == .approval, detail.canAllowHere { filled.categoryIdentifier = CloudKitSchema.approvalNowCategory }
            }
            if let picture = Self.picture(for: detail?.kind ?? target?.kind) { filled.attachments = [picture] }
            handler.call(filled)
        }
    }

    /// Time is up: show what there is (the generic text) rather than nothing.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let fallback { contentHandler(fallback) }
    }

    // MARK: Fetching

    /// Which record a Buddy push is about: an Approval or a Question, by record name; nil for anything else.
    private struct Target: Sendable {
        let kind: NotificationDetail.Kind
        let recordName: String
    }

    private static func target(of userInfo: [AnyHashable: Any]) -> Target? {
        let (recordName, subscriptionID) = CloudKitPush.fields(userInfo)
        guard let recordName else { return nil }
        switch subscriptionID {
        case CloudKitSchema.approvalSubscriptionID: return Target(kind: .approval, recordName: recordName)
        case CloudKitSchema.questionSubscriptionID: return Target(kind: .question, recordName: recordName)
        default: return nil
        }
    }

    /// The keys of a push, for the debug line: what was there when it was not recognised.
    private static func shape(of userInfo: [AnyHashable: Any]) -> String {
        let top = userInfo.keys.map { "\($0)" }.sorted().joined(separator: ",")
        let ck = (userInfo["ck"] as? [AnyHashable: Any]).map { $0.keys.map { "\($0)" }.sorted().joined(separator: ",") } ?? "-"
        let qry = ((userInfo["ck"] as? [AnyHashable: Any])?["qry"] as? [AnyHashable: Any])
            .map { $0.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") } ?? "-"
        return "keys[\(top)] ck[\(ck)] qry[\(qry)]"
    }

    /// The request the push is about, with its session's project; nil (and why) when anything is missing or not ours.
    private static func detail(for target: Target) async -> (NotificationDetail?, String) {
        let database = CKContainer(identifier: CloudKitSchema.containerIdentifier).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: target.recordName, zoneID: CloudKitSchema.zoneID)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            log.error("fetching \(target.recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return (nil, "fetch \(target.kind) failed: \(error.localizedDescription)")
        }
        switch target.kind {
        case .approval:
            guard let approval = ApprovalRecord(from: record) else { return (nil, "approval record unreadable") }
            return (NotificationDetail(approval: approval, project: await project(of: approval.sessionId, in: database)), "")
        case .question:
            guard let question = QuestionRecord(from: record) else { return (nil, "question record unreadable") }
            return (NotificationDetail(question: question, project: await project(of: question.sessionId, in: database)), "")
        }
    }

    private static func project(of sessionId: String, in database: CKDatabase) async -> String? {
        let id = CKRecord.ID(recordName: sessionId, zoneID: CloudKitSchema.zoneID)
        guard let record = try? await database.record(for: id) else { return nil }
        return SessionRecord(from: record)?.project
    }

    /// Buddy for this kind of request, from the bundle (an attachment must be its own file, which iOS moves).
    private static func picture(for kind: NotificationDetail.Kind?) -> UNNotificationAttachment? {
        let name = kind == .question ? "buddy-question" : "buddy-approval"
        guard let source = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "buddy", url: copy)
    }
}

/// UIKit's content handler, carried into the task that calls it once.
private struct SendableHandler: @unchecked Sendable {
    let body: (UNNotificationContent) -> Void
    init(_ body: @escaping (UNNotificationContent) -> Void) { self.body = body }
    func call(_ content: UNNotificationContent) { body(content) }
}

/// The content being filled in: only the task touches it after this point.
private struct SendableContent: @unchecked Sendable {
    let content: UNMutableNotificationContent
    init(_ content: UNMutableNotificationContent) { self.content = content }
}
