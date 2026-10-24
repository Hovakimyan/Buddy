import BuddyKit
import CloudKit
import Foundation
import UserNotifications

/// What a tap on the approval notification (or one of its actions) should do. Allow never becomes a decision
/// here: it only opens the app, where Face ID runs.
enum NotificationRoute: Equatable, Sendable {
    /// Deny straight from the notification: wake in the background, verify, submit.
    case deny(UUID)
    /// Open the app on this request.
    case review(UUID)
    /// Open the app on this question.
    case question(UUID)
    /// Allow from the long-press (the iPhone was unlocked to tap it), for the command the notification showed.
    case allowNow(UUID, shown: String?)
    /// Answer from the long-press: the option at this index of the (single) question.
    case answer(UUID, option: Int)

    /// The route of a tapped notification, whichever of the two kinds it is (their subscriptions differ, so at
    /// most one of them matches).
    static func resolve(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        ApprovalNotification.route(actionIdentifier: actionIdentifier, userInfo: userInfo)
            ?? QuestionNotification.route(actionIdentifier: actionIdentifier, userInfo: userInfo)
    }
}

/// Everything about the `BUDDY_APPROVAL` notification that can be decided without UIKit, kept pure so it is
/// unit-tested. The push itself is generic ("Claude Code needs approval", no command or project): the request is
/// identified through CloudKit, by the record name of the Approval the subscription fired for.
enum ApprovalNotification {
    static let categoryID = CloudKitSchema.approvalCategory
    static let allowActionID = "BUDDY_ALLOW"
    static let denyActionID = "BUDDY_DENY"
    static let allowNowActionID = "BUDDY_ALLOW_NOW"
    static let nowCategoryID = CloudKitSchema.approvalNowCategory

    /// The category registered at launch with `UNUserNotificationCenter.setNotificationCategories`.
    /// Deny has neither `.foreground` nor `.authenticationRequired`: it runs in the background, also from the lock
    /// screen. Allow opens the app (`.foreground`) on an unlocked device (`.authenticationRequired`); the Face ID
    /// check itself is in the app.
    static func category() -> UNNotificationCategory {
        let allow = UNNotificationAction(
            identifier: allowActionID, title: "Allow", options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(identifier: denyActionID, title: "Deny", options: [.destructive])
        return UNNotificationCategory(identifier: categoryID, actions: [allow, deny], intentIdentifiers: [], options: [])
    }

    /// The category the notification service picks for a short, plain command: Allow works without opening the app,
    /// once the iPhone is unlocked (`.authenticationRequired`), which stands in for the app's own Face ID check.
    static func nowCategory() -> UNNotificationCategory {
        let allow = UNNotificationAction(identifier: allowNowActionID, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyActionID, title: "Deny", options: [.destructive])
        return UNNotificationCategory(identifier: nowCategoryID, actions: [allow, deny], intentIdentifiers: [], options: [])
    }

    // MARK: Which request

    /// The request id from the Approval record name; nil for anything that is not an approval of ours (other
    /// subscriptions, `decision-...` records, junk).
    static func requestId(recordName: String?, subscriptionID: String?) -> UUID? {
        if let subscriptionID, subscriptionID != CloudKitSchema.approvalSubscriptionID { return nil }
        guard let recordName else { return nil }
        return UUID(uuidString: recordName)
    }

    /// The request id from a push's user info: the `ck.qry` record id and subscription id CloudKit puts in a
    /// query-subscription push (this reads the dictionary itself; `CKNotification` is the fallback).
    static func requestId(userInfo: [AnyHashable: Any]) -> UUID? {
        let (recordName, subscriptionID) = fields(userInfo)
        return requestId(recordName: recordName, subscriptionID: subscriptionID)
    }

    /// Whether the push is the approval subscription's.
    static func isApprovalPush(userInfo: [AnyHashable: Any]) -> Bool {
        fields(userInfo).subscriptionID == CloudKitSchema.approvalSubscriptionID
    }

    fileprivate static func fields(_ userInfo: [AnyHashable: Any]) -> (recordName: String?, subscriptionID: String?) {
        CloudKitPush.fields(userInfo)
    }

    // MARK: Routing

    static func route(actionIdentifier: String, requestId: UUID?, shown: String? = nil) -> NotificationRoute? {
        guard let requestId else { return nil }
        switch actionIdentifier {
        case denyActionID: return .deny(requestId)
        case allowNowActionID: return .allowNow(requestId, shown: shown)
        case allowActionID, UNNotificationDefaultActionIdentifier: return .review(requestId)
        default: return nil  // dismissed, or an action we do not know
        }
    }

    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        route(
            actionIdentifier: actionIdentifier, requestId: requestId(userInfo: userInfo),
            shown: NotificationDetail(userInfo: userInfo)?.summary)
    }
}

/// The `BUDDY_QUESTION` notification ("Claude is asking"). It has no fixed actions: the long-press view adds one per
/// option for a single question with one choice (answered once the iPhone is unlocked); otherwise tapping the
/// notification opens the app on the question, behind Face ID. The push carries no question
/// text; the question is identified by the record name of the Question the subscription fired for.
enum QuestionNotification {
    static let categoryID = CloudKitSchema.questionCategory

    static func category() -> UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [], intentIdentifiers: [], options: [])
    }

    /// The request id from a push's user info; nil for anything that is not a question push of ours.
    static func requestId(userInfo: [AnyHashable: Any]) -> UUID? {
        let (recordName, subscriptionID) = ApprovalNotification.fields(userInfo)
        guard subscriptionID == CloudKitSchema.questionSubscriptionID, let recordName else { return nil }
        return UUID(uuidString: recordName)
    }

    /// Whether the push is the question subscription's.
    static func isQuestionPush(userInfo: [AnyHashable: Any]) -> Bool {
        ApprovalNotification.fields(userInfo).subscriptionID == CloudKitSchema.questionSubscriptionID
    }

    /// A tap on the notification opens the question; an option picked on the long-press answers it; dismissing or any
    /// other action does nothing.
    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        guard let id = requestId(userInfo: userInfo) else { return nil }
        if actionIdentifier == UNNotificationDefaultActionIdentifier { return .question(id) }
        if let option = QuestionAnswerAction.option(of: actionIdentifier) { return .answer(id, option: option) }
        return nil
    }
}

/// Posts a local notification. Abstracted so the controller's "could not deny" notice is tested without
/// `UNUserNotificationCenter`.
protocol LocalNotifying: Sendable {
    func post(title: String, body: String) async
}

/// The real thing. Posting needs the notification permission asked for at launch; without it this does nothing.
struct SystemLocalNotifier: LocalNotifying {
    func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "buddy.local.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension ApprovalNotification {
    /// Shown when a Deny tapped on a notification could not be sent. Generic on purpose: no command, tool or
    /// project text, because a notification can be read on the lock screen.
    static let denyFailedTitle = "Buddy"
    static let denyFailedBody = "Could not deny \u{2014} answer on your Mac"
}
