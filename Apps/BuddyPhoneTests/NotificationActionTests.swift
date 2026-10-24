import BuddyKit
import Foundation
import Testing
import UserNotifications

/// Answering from a notification's long-press: what the notification shows, which actions it offers, and the checks
/// the app makes before anything is sent.
@MainActor
@Suite struct NotificationActionTests {
    let clock = TestClock()
    let transport = RecordingTransport()

    private func model() -> PhoneModel {
        let clock = clock
        let model = PhoneModel(
            transport: transport, authenticator: FakeAuthenticator(result: false), clock: { clock.now },
            pause: { _ in await Task.yield() })
        model.start()
        return model
    }

    private func push(_ recordName: String, subscription: String, detail: NotificationDetail? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "ck": ["qry": ["rid": recordName, "sid": subscription] as [String: Any]] as [String: Any],
        ]
        if let detail { info[NotificationDetail.userInfoKey] = detail.userInfoValue }
        return info
    }

    // MARK: What the notification says

    @Test func theNotificationNamesToolProjectAndCommand() {
        let detail = NotificationDetail(approval: makeApproval(clock: clock, summary: "npm test"), project: "deskmate")
        #expect(detail.title == "Bash · deskmate")
        #expect(detail.body == "npm test")
        #expect(detail.canAllowHere)
        let question = NotificationDetail(question: makeQuestion(clock: clock), project: nil)
        #expect(question.title == "Claude is asking")
        #expect(question.body == "Which database?")
        #expect(question.options == ["Postgres", "SQLite"])
        #expect(question.canAnswerHere)
        #expect(NotificationDetail(userInfo: [NotificationDetail.userInfoKey: detail.userInfoValue]) == detail)
    }

    @Test func allowAndAnswersAreOfferedOnlyWhereTheyCanBeReadAndMadeInFull() {
        #expect(!NotificationDetail.canAllowHere(makeApproval(clock: clock, truncated: true)))
        #expect(!NotificationDetail.canAllowHere(makeApproval(
            clock: clock, summary: String(repeating: "a", count: NotificationDetail.quickAllowMaxLength + 1))))
        #expect(!NotificationDetail.canAllowHere(makeApproval(clock: clock, summary: "echo \u{05D0}")))  // Hebrew
        let multi = AskQuestion(text: "Which?", header: "H", options: [AskOption(label: "A", description: nil)], multiSelect: true)
        #expect(!NotificationDetail.canAnswerHere(makeQuestion(clock: clock, questions: [multi])))
        let one = AskQuestion(text: "Which?", header: "H", options: [AskOption(label: "A", description: nil)], multiSelect: false)
        #expect(!NotificationDetail.canAnswerHere(makeQuestion(clock: clock, questions: [one, one])))
    }

    // MARK: Routing

    @Test func longPressActionsRouteToAllowNowAndAnswers() throws {
        let id = UUID()
        let detail = NotificationDetail(approval: makeApproval(id, clock: clock, summary: "ls"), project: nil)
        let approvalPush = push(id.uuidString, subscription: CloudKitSchema.approvalSubscriptionID, detail: detail)
        #expect(NotificationRoute.resolve(actionIdentifier: ApprovalNotification.allowNowActionID, userInfo: approvalPush)
            == .allowNow(id, shown: "ls"))
        let questionPush = push(id.uuidString, subscription: CloudKitSchema.questionSubscriptionID)
        #expect(NotificationRoute.resolve(actionIdentifier: QuestionAnswerAction.identifier(option: 1), userInfo: questionPush)
            == .answer(id, option: 1))
        #expect(NotificationRoute.resolve(actionIdentifier: "BUDDY_ANSWER_x", userInfo: questionPush) == nil)
        #expect(ApprovalNotification.nowCategory().actions.map(\.identifier)
            == [ApprovalNotification.allowNowActionID, ApprovalNotification.denyActionID])
        #expect(ApprovalNotification.nowCategory().actions.first?.options.contains(.authenticationRequired) == true)
        #expect(ApprovalNotification.nowCategory().actions.first?.options.contains(.foreground) == false)
    }

    // MARK: Allow from the long-press

    @Test func allowFromTheLongPressSendsTheShownCommandWithoutFaceID() async throws {
        let approval = makeApproval(clock: clock, summary: "npm test")
        transport.push(approvals: [approval])
        let model = model()
        try await model.allowFromNotification(approval.requestId, shownSummary: "npm test", timeout: .seconds(2))
        #expect(transport.submitted.map(\.decision) == [.allow])
    }

    @Test func allowFromTheLongPressRefusesACommandOtherThanTheOneShown() async {
        let approval = makeApproval(clock: clock, summary: "npm test")
        transport.push(approvals: [approval])
        let model = model()
        await #expect(throws: PhoneError.changedWhileAuthenticating) {
            try await model.allowFromNotification(approval.requestId, shownSummary: "npm tes", timeout: .seconds(2))
        }
        await #expect(throws: PhoneError.changedWhileAuthenticating) {
            try await model.allowFromNotification(approval.requestId, shownSummary: nil, timeout: .seconds(2))
        }
        #expect(transport.submitted.isEmpty)
    }

    @Test func allowFromTheLongPressRefusesWhatOnlyTheMacMayAllow() async {
        let long = makeApproval(clock: clock, summary: String(repeating: "a", count: NotificationDetail.quickAllowMaxLength + 1))
        let cut = makeApproval(clock: clock, truncated: true)
        transport.push(approvals: [long, cut])
        let model = model()
        await #expect(throws: PhoneError.tooLongToAllow) {
            try await model.allowFromNotification(long.requestId, shownSummary: long.summary, timeout: .seconds(2))
        }
        await #expect(throws: PhoneError.tooLongToAllow) {
            try await model.allowFromNotification(cut.requestId, shownSummary: cut.summary, timeout: .seconds(2))
        }
        #expect(transport.submitted.isEmpty)
    }

    // MARK: Answers from the long-press

    @Test func anOptionPickedOnTheLongPressIsSentAsTheAnswer() async throws {
        let question = makeQuestion(clock: clock)
        transport.push(questions: [question])
        let model = model()
        try await model.answerFromNotification(question.requestId, option: 1, timeout: .seconds(2))
        #expect(transport.submittedAnswers.map(\.responses) == [[["SQLite"]]])
    }

    @Test func anOptionThatDoesNotFitIsNotSent() async {
        let question = makeQuestion(clock: clock)
        let multi = makeQuestion(clock: clock, questions: [
            AskQuestion(text: "Which?", header: "H", options: [AskOption(label: "A", description: nil)], multiSelect: true),
        ])
        transport.push(questions: [question, multi])
        let model = model()
        await #expect(throws: PhoneError.incompleteAnswer) {
            try await model.answerFromNotification(question.requestId, option: 2, timeout: .seconds(2))
        }
        await #expect(throws: PhoneError.incompleteAnswer) {
            try await model.answerFromNotification(multi.requestId, option: 0, timeout: .seconds(2))
        }
        #expect(transport.submittedAnswers.isEmpty)
    }
}
