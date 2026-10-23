import BuddyKit
import CloudKit
import Foundation
import Testing
import UserNotifications

@Suite struct NotificationRoutingTests {
    private let id = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!
    private let sid = CloudKitSchema.approvalSubscriptionID

    /// The shape of the `ck` dictionary in a CloudKit query-subscription push (no command or project text).
    private func push(recordName: String, subscription: String? = nil) -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["body": CloudKitSchema.approvalAlertBody], "category": CloudKitSchema.approvalCategory],
            "ck": [
                "ckuserid": "_abc", "nid": UUID().uuidString,
                "qry": [
                    "rid": recordName, "sid": subscription ?? sid, "zid": "Buddy", "zoid": "_owner", "dbs": 1, "fo": 1,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: Request id

    @Test func theRequestIdIsTheApprovalRecordName() {
        #expect(ApprovalNotification.requestId(recordName: id.uuidString, subscriptionID: sid) == id)
        #expect(ApprovalNotification.requestId(recordName: id.uuidString, subscriptionID: nil) == id)
    }

    @Test func anythingElseIsNotARequest() {
        #expect(ApprovalNotification.requestId(recordName: nil, subscriptionID: sid) == nil)
        #expect(ApprovalNotification.requestId(recordName: "not-a-uuid", subscriptionID: sid) == nil)
        #expect(ApprovalNotification.requestId(recordName: "decision-\(id.uuidString)", subscriptionID: sid) == nil)
        #expect(ApprovalNotification.requestId(recordName: id.uuidString, subscriptionID: "someone.elses") == nil)
        #expect(ApprovalNotification.requestId(recordName: id.uuidString, subscriptionID: CloudKitSchema.decisionSubscriptionID) == nil)
    }

    @Test func theRequestIdIsReadFromThePushPayload() {
        #expect(ApprovalNotification.requestId(userInfo: push(recordName: id.uuidString)) == id)
        #expect(ApprovalNotification.requestId(userInfo: push(recordName: id.uuidString, subscription: "other")) == nil)
        #expect(ApprovalNotification.requestId(userInfo: push(recordName: "junk")) == nil)
        #expect(ApprovalNotification.requestId(userInfo: [:]) == nil)
        #expect(ApprovalNotification.requestId(userInfo: ["ck": "nope"]) == nil)
        #expect(ApprovalNotification.requestId(userInfo: ["ck": ["qry": ["rid": 7]]]) == nil)
    }

    @Test func thePayloadReaderAgreesWithCloudKitsOwnParser() {
        let userInfo = push(recordName: id.uuidString)
        let parsed = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification
        #expect(parsed?.recordID?.recordName == id.uuidString)
        #expect(parsed?.subscriptionID == sid)
        #expect(ApprovalNotification.requestId(userInfo: userInfo) == (parsed?.recordID?.recordName).flatMap { UUID(uuidString: $0) })
    }

    @Test func approvalPushesAreRecognisedBySubscription() {
        #expect(ApprovalNotification.isApprovalPush(userInfo: push(recordName: id.uuidString)))
        #expect(!ApprovalNotification.isApprovalPush(userInfo: push(recordName: id.uuidString, subscription: "x")))
        #expect(!ApprovalNotification.isApprovalPush(userInfo: [:]))
    }

    // MARK: Routing

    @Test func denyActionRoutesToADirectDeny() {
        #expect(ApprovalNotification.route(actionIdentifier: ApprovalNotification.denyActionID, requestId: id) == .deny(id))
    }

    @Test func allowActionOnlyOpensTheApprovalScreen() {
        // Allow never turns into a decision here: it needs the Face ID flow in the app.
        #expect(ApprovalNotification.route(actionIdentifier: ApprovalNotification.allowActionID, requestId: id) == .review(id))
    }

    @Test func tappingTheNotificationOpensTheApprovalScreen() {
        #expect(ApprovalNotification.route(actionIdentifier: UNNotificationDefaultActionIdentifier, requestId: id) == .review(id))
    }

    @Test func dismissUnknownActionsAndMissingIdsDoNothing() {
        #expect(ApprovalNotification.route(actionIdentifier: UNNotificationDismissActionIdentifier, requestId: id) == nil)
        #expect(ApprovalNotification.route(actionIdentifier: "SOMETHING_ELSE", requestId: id) == nil)
        #expect(ApprovalNotification.route(actionIdentifier: ApprovalNotification.denyActionID, requestId: nil) == nil)
        #expect(ApprovalNotification.route(actionIdentifier: ApprovalNotification.allowActionID, requestId: nil) == nil)
    }

    @Test func routingFromTheWholePayload() {
        let userInfo = push(recordName: id.uuidString)
        #expect(ApprovalNotification.route(actionIdentifier: ApprovalNotification.denyActionID, userInfo: userInfo) == .deny(id))
        #expect(ApprovalNotification.route(actionIdentifier: ApprovalNotification.allowActionID, userInfo: userInfo) == .review(id))
        #expect(ApprovalNotification.route(actionIdentifier: ApprovalNotification.denyActionID, userInfo: [:]) == nil)
    }

    // MARK: Questions

    private func questionPush(recordName: String, subscription: String? = nil) -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["body": CloudKitSchema.questionAlertBody], "category": CloudKitSchema.questionCategory],
            "ck": [
                "ckuserid": "_abc", "nid": UUID().uuidString,
                "qry": [
                    "rid": recordName, "sid": subscription ?? CloudKitSchema.questionSubscriptionID, "zid": "Buddy",
                    "zoid": "_owner", "dbs": 1, "fo": 1,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    @Test func questionNotificationRoutesToQuestion() {
        let userInfo = questionPush(recordName: id.uuidString)
        #expect(QuestionNotification.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo) == .question(id))
        #expect(NotificationRoute.resolve(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo) == .question(id))
    }

    @Test func approvalPushesStillRouteToTheApprovalScreenAndDeny() {
        let userInfo = push(recordName: id.uuidString)
        #expect(NotificationRoute.resolve(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo) == .review(id))
        #expect(NotificationRoute.resolve(actionIdentifier: ApprovalNotification.denyActionID, userInfo: userInfo) == .deny(id))
    }

    @Test func aQuestionPushIsNotAnApprovalAndNeverAnAnswer() {
        let userInfo = questionPush(recordName: id.uuidString)
        #expect(ApprovalNotification.requestId(userInfo: userInfo) == nil)
        #expect(ApprovalNotification.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo) == nil)
        #expect(!ApprovalNotification.isApprovalPush(userInfo: userInfo))
        #expect(QuestionNotification.isQuestionPush(userInfo: userInfo))
        // An approval push is not a question's, and a question notification has no action that answers.
        #expect(QuestionNotification.requestId(userInfo: push(recordName: id.uuidString)) == nil)
        #expect(!QuestionNotification.isQuestionPush(userInfo: push(recordName: id.uuidString)))
        #expect(QuestionNotification.route(actionIdentifier: ApprovalNotification.denyActionID, userInfo: userInfo) == nil)
        #expect(QuestionNotification.route(actionIdentifier: ApprovalNotification.allowActionID, userInfo: userInfo) == nil)
    }

    @Test func questionRoutingIgnoresJunk() {
        #expect(QuestionNotification.requestId(userInfo: [:]) == nil)
        #expect(QuestionNotification.requestId(userInfo: questionPush(recordName: "junk")) == nil)
        #expect(QuestionNotification.requestId(userInfo: questionPush(recordName: "answer-\(id.uuidString)")) == nil)
        #expect(QuestionNotification.requestId(userInfo: questionPush(recordName: id.uuidString, subscription: "other")) == nil)
        let userInfo = questionPush(recordName: id.uuidString)
        #expect(QuestionNotification.route(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: userInfo) == nil)
        #expect(QuestionNotification.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:]) == nil)
    }

    @Test func theQuestionCategoryHasNoActions() {
        let category = QuestionNotification.category()
        #expect(category.identifier == "BUDDY_QUESTION")
        #expect(category.actions.isEmpty)  // opening the app routes to the question
        #expect(CloudKitSchema.questionSubscription().notificationInfo?.category == category.identifier)
    }

    // MARK: Category

    @Test func theCategoryMatchesTheSubscriptionsCategory() {
        #expect(ApprovalNotification.category().identifier == "BUDDY_APPROVAL")
        #expect(CloudKitSchema.approvalSubscription().notificationInfo?.category == ApprovalNotification.category().identifier)
    }

    @Test func denyRunsInTheBackgroundAndAllowOpensTheApp() throws {
        let actions = ApprovalNotification.category().actions
        let deny = try #require(actions.first { $0.identifier == ApprovalNotification.denyActionID })
        let allow = try #require(actions.first { $0.identifier == ApprovalNotification.allowActionID })
        #expect(actions.count == 2)
        // Deny: no app launch, and no unlock, so it works from the lock screen.
        #expect(!deny.options.contains(.foreground))
        #expect(!deny.options.contains(.authenticationRequired))
        #expect(deny.options.contains(.destructive))
        // Allow: opens the app (where Face ID runs), and the device must be unlocked.
        #expect(allow.options.contains(.foreground))
        #expect(allow.options.contains(.authenticationRequired))
        #expect(!allow.options.contains(.destructive))
    }
}
