import BuddyKit
@preconcurrency import CloudKit
import Foundation

/// What the notification service fetched about a request, kept in the delivered notification (`userInfo["buddy"]`,
/// a JSON string) so the long-press view can show it without fetching again. Display text only, already sanitized:
/// what the app acts on is always fetched fresh from the cloud, and an Allow from the long-press must match the
/// `summary` shown here (see `PhoneModel.allowFromNotification`).
struct NotificationDetail: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case approval, question }

    static let userInfoKey = "buddy"
    /// The longest command that can be allowed from the long-press: short enough to read in full there.
    static let quickAllowMaxLength = 300

    var kind: Kind
    var requestId: UUID
    var project: String?
    /// Approval: the tool and the command, as shown.
    var tool: String?
    var summary: String?
    /// Approval: Allow is offered on the long-press (the command is short, whole and plain).
    var canAllowHere: Bool = false
    /// Question: the first question, as shown.
    var header: String?
    var text: String?
    /// Question: the option labels, as shown (one action each when `canAnswerHere`).
    var options: [String] = []
    /// Question: a single question with a single choice, so each option can be one action.
    var canAnswerHere: Bool = false

    init(approval: ApprovalRecord, project: String?) {
        kind = .approval
        requestId = approval.requestId
        self.project = project.map(DisplayText.sanitized)
        tool = DisplayText.sanitized(approval.tool)
        summary = DisplayText.sanitized(approval.summary)
        canAllowHere = Self.canAllowHere(approval)
    }

    init(question: QuestionRecord, project: String?) {
        kind = .question
        requestId = question.requestId
        self.project = project.map(DisplayText.sanitized)
        let first = question.questions.first
        header = first.map { DisplayText.sanitized($0.header) }
        text = first.map { DisplayText.sanitized($0.text) }
        options = first?.options.map { DisplayText.sanitized($0.label) } ?? []
        canAnswerHere = Self.canAnswerHere(question)
    }

    /// Allow from the long-press: the phone's own rule (whole, plain text) and short enough to read there.
    static func canAllowHere(_ approval: ApprovalRecord) -> Bool {
        approval.canBeAllowedOnPhone && DisplayText.sanitized(approval.summary).count <= quickAllowMaxLength
    }

    /// One question with one choice to make, and not so many options that the buttons stop fitting.
    static func canAnswerHere(_ question: QuestionRecord) -> Bool {
        guard question.questions.count == 1, let only = question.questions.first else { return false }
        return !only.multiSelect && (1...4).contains(only.options.count)
    }

    /// The notification's title and body (shown on the lock screen only once the iPhone is unlocked, with iOS's
    /// default "Show Previews: When Unlocked").
    var title: String {
        switch kind {
        case .approval: [tool, project].compactMap { $0 }.joined(separator: " · ")
        case .question: ["Claude is asking", project].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var body: String {
        switch kind {
        case .approval: summary ?? ""
        case .question: text ?? ""
        }
    }

    var userInfoValue: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? ""
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let text = userInfo[Self.userInfoKey] as? String,
              let decoded = try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
        else { return nil }
        self = decoded
    }
}

extension ApprovalRecord {
    /// Whether the phone may offer Allow at all: the command was not cut, and every character of it as shown
    /// (`DisplayText.sanitized`) is in the allowlisted classes the Mac card uses (`DisplayText.isPlainReadable`).
    var canBeAllowedOnPhone: Bool {
        !isTruncated && DisplayText.isPlainReadable(DisplayText.sanitized(summary))
    }
}

/// The action identifier of one option of a question answered from the long-press.
enum QuestionAnswerAction {
    static let prefix = "BUDDY_ANSWER_"

    static func identifier(option: Int) -> String { prefix + String(option) }

    static func option(of identifier: String) -> Int? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return Int(identifier.dropFirst(prefix.count))
    }
}

/// The record a CloudKit query-subscription push is about, read from the push's `ck` dictionary itself (the app and the
/// notification service share this). `CKNotification` is only the fallback: it did not recognise these pushes in the
/// notification service, which then showed the generic text.
enum CloudKitPush {
    static func fields(_ userInfo: [AnyHashable: Any]) -> (recordName: String?, subscriptionID: String?) {
        if let ck = userInfo["ck"] as? [AnyHashable: Any], let query = ck["qry"] as? [AnyHashable: Any] {
            let recordName = query["rid"] as? String
            let subscriptionID = query["sid"] as? String
            if recordName != nil || subscriptionID != nil { return (recordName, subscriptionID) }
        }
        if let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification {
            return (query.recordID?.recordName, query.subscriptionID)
        }
        return (nil, nil)
    }
}
