import BuddyKit
import Foundation
import Synchronization
import Testing

/// Records what the controller asked to be posted as a local notification.
final class FakeNotifier: LocalNotifying {
    private let posted = Mutex<[(title: String, body: String)]>([])
    var notices: [(title: String, body: String)] { posted.withLock { $0 } }
    func post(title: String, body: String) async { posted.withLock { $0.append((title, body)) } }
}

/// Hands out the accounts in order (the last one repeats) and counts how often the check ran.
final class Accounts: Sendable {
    private let state = Mutex((next: 0, checks: 0))
    let list: [PhoneLinkAccount]
    let transport: RecordingTransport
    init(_ list: [PhoneLinkAccount], transport: RecordingTransport) {
        self.list = list
        self.transport = transport
    }
    var checks: Int { state.withLock { $0.checks } }

    var selector: PhoneCloudSelector {
        PhoneCloudSelector(
            hasEntitlement: { true },
            account: {
                self.state.withLock { state in
                    state.checks += 1
                    defer { state.next += 1 }
                    return self.list[min(state.next, self.list.count - 1)]
                }
            },
            makeConnection: { PhoneConnection(transport: self.transport, refresh: {}) })
    }
}

@MainActor
@Suite struct PhoneControllerTests {
    let clock = TestClock()
    let transport = RecordingTransport()
    let notifier = FakeNotifier()

    private func controller(_ accounts: PhoneLinkAccount..., denyTimeout: Duration = .milliseconds(200))
        -> (PhoneController, Accounts)
    {
        let clock = clock
        let accounts = Accounts(accounts, transport: transport)
        let controller = PhoneController(
            selector: accounts.selector, authenticator: FakeAuthenticator(result: true), clock: { clock.now },
            notifier: notifier, denyTimeout: denyTimeout)
        return (controller, accounts)
    }

    // MARK: Routing

    // Checklist: tapping a notification (or its Allow action) opens the approval screen and decides nothing.
    @Test func reviewOpensTheApprovalScreenAndSubmitsNothing() async {
        let (controller, _) = controller(.available)
        let id = UUID()
        await controller.handle(.review(id))
        #expect(controller.path == [.approval(id)])
        #expect(transport.submitted.isEmpty)
        #expect(notifier.notices.isEmpty)
    }

    @Test func reviewWithoutICloudStillOpensTheScreenAndSubmitsNothing() async {
        let (controller, _) = controller(.noAccount)
        let id = UUID()
        await controller.handle(.review(id))
        #expect(controller.path == [.approval(id)])
        #expect(transport.submitted.isEmpty)
    }

    @Test func aQuestionRouteOpensTheQuestionScreenAndSubmitsNothing() async {
        let (controller, _) = controller(.available)
        let id = UUID()
        await controller.handle(.question(id))
        #expect(controller.path == [.question(id)])
        #expect(transport.submitted.isEmpty)
        #expect(transport.submittedAnswers.isEmpty)
        #expect(notifier.notices.isEmpty)
    }

    @Test func denyWithNoModelIsANoOp() async {
        let (controller, _) = controller(.noAccount)
        await controller.handle(.deny(UUID()))
        #expect(controller.model == nil)
        #expect(controller.path.isEmpty)
        #expect(transport.submitted.isEmpty)
        #expect(notifier.notices.isEmpty)
    }

    @Test func denyDeniesAPendingRequestAndSaysNothing() async {
        let (controller, _) = controller(.available)
        let approval = makeApproval(clock: clock)
        transport.push(approvals: [approval])
        await controller.handle(.deny(approval.requestId))
        #expect(transport.submitted.map(\.requestId) == [approval.requestId])
        #expect(transport.submitted.map(\.decision) == [.deny])
        #expect(notifier.notices.isEmpty)
    }

    // MARK: A Deny that could not be sent

    // Checklist: a failed lock-screen Deny tells the person to answer on the Mac.
    @Test func aDenyThatFailsToSendPostsALocalNotification() async {
        let (controller, _) = controller(.available)
        let approval = makeApproval(clock: clock)
        transport.push(approvals: [approval])
        transport.failSubmits(true)
        await controller.handle(.deny(approval.requestId))
        #expect(transport.submitted.isEmpty)
        #expect(notifier.notices.count == 1)
        #expect(notifier.notices.first?.body == "Could not deny \u{2014} answer on your Mac")
        // Generic: nothing of the command, tool or project.
        #expect(notifier.notices.first?.body.contains(approval.summary) == false)
    }

    @Test func aDenyForARequestThatNeverArrivesPostsTheNotification() async {
        let (controller, _) = controller(.available, denyTimeout: .milliseconds(100))
        await controller.handle(.deny(UUID()))
        #expect(transport.submitted.isEmpty)
        #expect(notifier.notices.count == 1)
    }

    @Test func aDenyForARequestAlreadyAnsweredPostsNothing() async {
        let (controller, _) = controller(.available)
        let answered = makeApproval(clock: clock, status: .resolved)
        transport.push(approvals: [answered])
        await controller.handle(.deny(answered.requestId))
        #expect(transport.submitted.isEmpty)
        #expect(notifier.notices.isEmpty)  // the Mac already answered: nothing is waiting for the person
    }

    // MARK: Re-check when the app returns to the foreground

    // Checklist: iCloud timed out or was briefly unavailable at launch; coming back to the app tries again.
    @Test func aTimedOutCheckIsTriedAgainAndConnects() async {
        let (controller, accounts) = controller(.timedOut, .available)
        await controller.start()
        #expect(controller.model == nil)
        #expect(controller.wantsRemoteNotifications == false)
        #expect(controller.canRetrySelection)

        let connected = await controller.retrySelectionIfNeeded()
        #expect(connected)
        #expect(controller.model != nil)
        #expect(controller.status == .on)
        #expect(controller.wantsRemoteNotifications)
        #expect(accounts.checks == 2)

        // Connected: later foregrounds do nothing.
        #expect(await controller.retrySelectionIfNeeded() == false)
        #expect(accounts.checks == 2)
    }

    @Test func aStillFailingCheckStaysRetryable() async {
        let (controller, accounts) = controller(.temporarilyUnavailable)
        await controller.start()
        #expect(await controller.retrySelectionIfNeeded() == false)
        #expect(controller.model == nil)
        #expect(controller.canRetrySelection)
        #expect(accounts.checks == 2)
    }

    @Test func aFinalAnswerIsNeverRetried() async {
        for account in [PhoneLinkAccount.noAccount, .restricted] {
            let (controller, accounts) = controller(account, .available)
            await controller.start()
            #expect(controller.canRetrySelection == false)
            #expect(await controller.retrySelectionIfNeeded() == false)
            #expect(controller.model == nil, "\(account)")
            #expect(accounts.checks == 1, "\(account)")
        }
    }

    @Test func twoForegroundsAtOnceRunOnlyOneRetry() async {
        let (controller, accounts) = controller(.timedOut, .available)
        await controller.start()
        #expect(accounts.checks == 1)
        // Both calls are queued on the main actor before either check has started.
        let first = Task { await controller.retrySelectionIfNeeded() }
        let second = Task { await controller.retrySelectionIfNeeded() }
        let results = [await first.value, await second.value]
        #expect(accounts.checks == 2)  // the launch check and ONE retry
        #expect(results.filter { $0 }.count == 1)
        #expect(controller.model != nil)
    }

    @Test func retryBeforeTheLaunchCheckDoesNothing() async {
        let (controller, accounts) = controller(.available)
        #expect(await controller.retrySelectionIfNeeded() == false)
        #expect(accounts.checks == 0)
    }

    // MARK: Sample

    @Test func theSampleShowsMadeUpRequestsAndSendsNothingToTheAccount() async throws {
        let (controller, _) = controller(.available)
        await controller.start()
        await controller.showSample()
        #expect(controller.isSample)
        let model = try #require(controller.model)
        #expect(await waitUntil { model.pendingApprovals.map(\.requestId) == [SampleCloud.approvalId] })
        #expect(model.pendingQuestions.map(\.requestId) == [SampleCloud.questionId])
        #expect(model.sessions.count == 3)
        // Allowing it works (Face ID passes in the fake), and only the sample hears about it.
        try await model.allow(SampleCloud.approvalId)
        #expect(model.pendingApprovals.isEmpty)
        #expect(transport.submitted.isEmpty)
    }

    @Test func leavingTheSampleChecksICloudAgainAndShowsTheAccount() async throws {
        let (controller, accounts) = controller(.noAccount, .available)
        await controller.start()
        #expect(controller.model == nil)
        await controller.showSample()
        #expect(controller.isSample)
        await controller.leaveSample()
        #expect(!controller.isSample)
        #expect(accounts.checks == 2)
        #expect(controller.status == .on)
        let model = try #require(controller.model)
        transport.push(sessions: [SessionRecord(sessionId: "real", state: .working, project: "p", lastTool: nil, updatedAt: clock.now)])
        #expect(await waitUntil { model.sessions.map(\.sessionId) == ["real"] })
    }

    @Test func aRealNotificationLeavesTheSample() async {
        let (controller, _) = controller(.available)
        await controller.start()
        await controller.showSample()
        let id = UUID()
        await controller.handle(.review(id))
        #expect(!controller.isSample)
        #expect(controller.path == [.approval(id)])
    }

    @Test func theSampleWaitsForTheICloudCheck() async {
        let (controller, _) = controller(.available)
        // No launch check yet: nothing is running, so the sample may start; it is the only model.
        await controller.showSample()
        #expect(controller.isSample)
        // A second tap does not replace it.
        let first = controller.model
        await controller.showSample()
        #expect(controller.model === first)
    }
}
