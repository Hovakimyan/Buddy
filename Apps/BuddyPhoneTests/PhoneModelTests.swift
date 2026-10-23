import BuddyKit
import Foundation
import Synchronization
import Testing

@MainActor
@Suite struct PhoneModelTests {
    let clock = TestClock()
    let transport = RecordingTransport()

    private func makeModel(
        _ authenticator: FakeAuthenticator, refresh: @escaping @Sendable () async -> Void = {},
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> PhoneModel {
        let clock = clock
        let model = PhoneModel(
            transport: transport, authenticator: authenticator, clock: { clock.now }, refresh: refresh, pause: pause)
        model.start()
        return model
    }

    /// A model that already shows `approvals`.
    private func loadedModel(_ authenticator: FakeAuthenticator, _ approvals: [ApprovalRecord]) async -> PhoneModel {
        transport.push(approvals: approvals)
        let model = makeModel(authenticator)
        #expect(await waitUntil { model.approvals.count == approvals.count })
        return model
    }

    // MARK: The six required cases

    @Test func allowRequiresAuthentication() async {
        let approval = makeApproval(clock: clock)
        let auth = FakeAuthenticator(result: false)
        let model = await loadedModel(auth, [approval])
        await #expect(throws: PhoneError.notAuthenticated) { try await model.allow(approval.requestId) }
        #expect(auth.calls == 1)
        #expect(transport.submitted.isEmpty)
        #expect(model.pendingApprovals.map(\.requestId) == [approval.requestId])  // still pending, can be retried
    }

    @Test func allowSubmitsDecisionAfterAuth() async throws {
        let approval = makeApproval(clock: clock)
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [approval])
        try await model.allow(approval.requestId)
        #expect(auth.calls == 1)
        #expect(
            transport.submitted == [
                DecisionRecord(requestId: approval.requestId, decision: .allow, decidedAt: clock.now, source: .phone)
            ])
        // The prompt never carries the command or tool text: it is generic.
        #expect(!auth.reasons[0].contains("rm -rf"))
    }

    @Test func denyDoesNotAuthenticate() async throws {
        let approval = makeApproval(clock: clock)
        let auth = FakeAuthenticator(result: false)
        let model = await loadedModel(auth, [approval])
        try await model.deny(approval.requestId)
        #expect(auth.calls == 0)
        #expect(
            transport.submitted == [
                DecisionRecord(requestId: approval.requestId, decision: .deny, decidedAt: clock.now, source: .phone)
            ])
    }

    @Test func truncatedCommandCannotBeAllowed() async throws {
        let approval = makeApproval(clock: clock, truncated: true)
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [approval])
        await #expect(throws: PhoneError.tooLongToAllow) { try await model.allow(approval.requestId) }
        #expect(auth.calls == 0)  // refused before any prompt
        #expect(transport.submitted.isEmpty)
        // Deny always works.
        try await model.deny(approval.requestId)
        #expect(transport.submitted.map(\.decision) == [.deny])
    }

    @Test func rightToLeftCommandCannotBeAllowedButCanBeDenied() async throws {
        let approval = makeApproval(clock: clock, summary: "rm -rf /tmp/א-ב")
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [approval])
        await #expect(throws: PhoneError.notPlainText) { try await model.allow(approval.requestId) }
        #expect(auth.calls == 0)  // refused before any prompt
        #expect(transport.submitted.isEmpty)
        try await model.deny(approval.requestId)
        #expect(transport.submitted.map(\.decision) == [.deny])
    }

    @Test func expiredApprovalCannotBeDecided() async {
        let approval = makeApproval(clock: clock, expiresIn: 30)
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [approval])
        clock.advance(30)  // exactly at expiresAt: expired
        await #expect(throws: PhoneError.expired) { try await model.allow(approval.requestId) }
        await #expect(throws: PhoneError.expired) { try await model.deny(approval.requestId) }
        #expect(auth.calls == 0)
        #expect(transport.submitted.isEmpty)
    }

    @Test func pendingListHidesResolved() async {
        let pending = makeApproval(clock: clock)
        let resolved = makeApproval(clock: clock, status: .resolved)
        let expired = makeApproval(clock: clock, status: .expired)
        let model = await loadedModel(FakeAuthenticator(result: true), [resolved, pending, expired])
        #expect(model.approvals.count == 3)
        #expect(model.pendingApprovals.map(\.requestId) == [pending.requestId])
    }

    // MARK: Errors and edge cases

    @Test func denyOnAnExpiredApprovalThrowsExpired() async {
        let approval = makeApproval(clock: clock, expiresIn: 10)
        let model = await loadedModel(FakeAuthenticator(result: true), [approval])
        clock.advance(11)
        await #expect(throws: PhoneError.expired) { try await model.deny(approval.requestId) }
        #expect(transport.submitted.isEmpty)
    }

    @Test func anUnknownIdIsAClearError() async {
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [makeApproval(clock: clock)])
        let stranger = UUID()
        await #expect(throws: PhoneError.unknownApproval) { try await model.allow(stranger) }
        await #expect(throws: PhoneError.unknownApproval) { try await model.deny(stranger) }
        #expect(auth.calls == 0)
        #expect(transport.submitted.isEmpty)
    }

    @Test func aResolvedOrExpiredStatusCannotBeDecided() async {
        let resolved = makeApproval(clock: clock, status: .resolved)
        let expired = makeApproval(clock: clock, status: .expired)
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [resolved, expired])
        await #expect(throws: PhoneError.notPending) { try await model.allow(resolved.requestId) }
        await #expect(throws: PhoneError.notPending) { try await model.deny(resolved.requestId) }
        await #expect(throws: PhoneError.notPending) { try await model.allow(expired.requestId) }
        #expect(auth.calls == 0)
        #expect(transport.submitted.isEmpty)
    }

    @Test func aCancelledAuthenticationLeavesNothingSubmitted() async {
        let approval = makeApproval(clock: clock)
        let auth = FakeAuthenticator(result: false)
        let model = await loadedModel(auth, [approval])
        await #expect(throws: PhoneError.notAuthenticated) { try await model.allow(approval.requestId) }
        await #expect(throws: PhoneError.notAuthenticated) { try await model.allow(approval.requestId) }
        #expect(auth.calls == 2)  // nothing is remembered: the user is asked again
        #expect(transport.submitted.isEmpty)
        #expect(model.decision(for: approval.requestId) == nil)
    }

    @Test func everyAllowAuthenticatesAgain() async throws {
        let a = makeApproval(clock: clock)
        let b = makeApproval(clock: clock)
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [a, b])
        try await model.allow(a.requestId)
        try await model.allow(b.requestId)
        #expect(auth.calls == 2)  // no cached "recently authenticated"
    }

    @Test func pendingListIsRecomputedAgainstTheClock() async {
        let soon = makeApproval(clock: clock, expiresIn: 20)
        let later = makeApproval(clock: clock, expiresIn: 90)
        let model = await loadedModel(FakeAuthenticator(result: true), [soon, later])
        #expect(model.pendingApprovals.count == 2)
        clock.advance(19.9)
        #expect(model.pendingApprovals.count == 2)
        clock.advance(0.1)  // no new stream value: the time alone hides it
        #expect(model.pendingApprovals.map(\.requestId) == [later.requestId])
        clock.advance(100)
        #expect(model.pendingApprovals.isEmpty)
    }

    @Test func aDecisionIsOnlyForTheExactDisplayedRequest() async throws {
        let a = makeApproval(clock: clock)
        let b = makeApproval(clock: clock)
        let model = await loadedModel(FakeAuthenticator(result: true), [a, b])
        try await model.allow(b.requestId)
        try await model.deny(a.requestId)
        #expect(transport.submitted.map(\.requestId) == [b.requestId, a.requestId])
        #expect(transport.submitted.map(\.decision) == [.allow, .deny])
        #expect(transport.submitted.allSatisfy { $0.source == .phone })
    }

    @Test func aDecidedRequestLeavesThePendingListAndCannotBeDecidedTwice() async throws {
        let approval = makeApproval(clock: clock)
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth, [approval])
        try await model.deny(approval.requestId)
        #expect(model.pendingApprovals.isEmpty)
        #expect(model.decision(for: approval.requestId) == .deny)
        await #expect(throws: PhoneError.alreadyDecided) { try await model.allow(approval.requestId) }
        await #expect(throws: PhoneError.alreadyDecided) { try await model.deny(approval.requestId) }
        #expect(transport.submitted.count == 1)
        #expect(auth.calls == 0)
    }

    @Test func aFailedSubmitIsReportedAndTheRequestStaysPending() async throws {
        let approval = makeApproval(clock: clock)
        let model = await loadedModel(FakeAuthenticator(result: true), [approval])
        transport.failSubmits(true)
        await #expect(throws: PhoneError.submitFailed(RecordingTransport.SubmitFailure().localizedDescription)) {
            try await model.deny(approval.requestId)
        }
        #expect(model.pendingApprovals.count == 1)
        #expect(model.decision(for: approval.requestId) == nil)
        transport.failSubmits(false)
        try await model.deny(approval.requestId)
        #expect(transport.submitted.count == 1)
    }

    @Test func anEarlierAnswerThatCountsIsShownInsteadOfThisOne() async throws {
        // An Allow reached the cloud but its reply was lost; the person then taps Deny. The Allow is what the Mac
        // acts on, so the phone must show Allowed, not Denied.
        let approval = makeApproval(clock: clock)
        let model = await loadedModel(FakeAuthenticator(result: true), [approval])
        transport.rejectAsAlreadyRecorded(DecisionAlreadyRecorded(decision: .allow))
        await #expect(throws: PhoneError.answeredEarlier(.allow)) { try await model.deny(approval.requestId) }
        #expect(model.decision(for: approval.requestId) == .allow)
        #expect(model.pendingApprovals.isEmpty)
    }

    @Test func anEarlierAnswerThatCannotBeReadShowsNoDecision() async throws {
        let approval = makeApproval(clock: clock)
        let model = await loadedModel(FakeAuthenticator(result: true), [approval])
        transport.rejectAsAlreadyRecorded(DecisionAlreadyRecorded(decision: nil))
        await #expect(throws: PhoneError.answeredEarlier(nil)) { try await model.deny(approval.requestId) }
        #expect(model.decision(for: approval.requestId) == nil)
    }

    @Test func approvalExpiringWhileThePromptIsUpIsNotAllowed() async {
        let approval = makeApproval(clock: clock, expiresIn: 30)
        let clock = clock
        let auth = FakeAuthenticator(result: true, during: { clock.advance(31) })
        let model = await loadedModel(auth, [approval])
        await #expect(throws: PhoneError.expired) { try await model.allow(approval.requestId) }
        #expect(transport.submitted.isEmpty)
    }

    @Test func approvalResolvedWhileThePromptIsUpIsNotAllowed() async {
        let approval = makeApproval(clock: clock)
        let transport = transport
        var resolved = approval
        resolved.status = .resolved
        let update = resolved
        let holder = Mutex<PhoneModel?>(nil)
        let auth = FakeAuthenticator(
            result: true,
            during: {
                transport.push(approvals: [update])
                // Bounded wait until the model's stream consumer has applied the update.
                _ = await waitUntil { holder.withLock { $0 }?.approval(id: update.requestId)?.status == .resolved }
            })
        let model = await loadedModel(auth, [approval])
        holder.withLock { $0 = model }
        await #expect(throws: PhoneError.notPending) { try await model.allow(approval.requestId) }
        #expect(transport.submitted.isEmpty)
    }

    @Test func aSecondDecisionWhileThePromptIsUpIsRefused() async throws {
        let approval = makeApproval(clock: clock)
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (release, letGo) = AsyncStream<Void>.makeStream()
        let auth = FakeAuthenticator(
            result: true,
            during: {
                enter.yield()
                for await _ in release { return }
            })
        let model = await loadedModel(auth, [approval])
        let first = Task { try await model.allow(approval.requestId) }
        for await _ in entered { break }
        await #expect(throws: PhoneError.busy) { try await model.allow(approval.requestId) }
        await #expect(throws: PhoneError.busy) { try await model.deny(approval.requestId) }
        letGo.yield()
        try await first.value
        #expect(transport.submitted.count == 1)
        #expect(auth.calls == 1)
    }

    // MARK: Live lists

    @Test func streamsUpdateTheListsLive() async throws {
        let cloud = InMemoryCloud()
        let clock = clock
        let model = PhoneModel(
            transport: cloud.phoneSide, authenticator: FakeAuthenticator(result: true), clock: { clock.now })
        model.start()
        #expect(model.sessions.isEmpty && model.pendingApprovals.isEmpty)

        let session = SessionRecord(
            sessionId: "s1", state: .working, project: "buddy", lastTool: "Bash", updatedAt: clock.now)
        try await cloud.macSide.publish(session: session)
        #expect(await waitUntil { model.sessions == [session] })

        let approval = makeApproval(clock: clock)
        try await cloud.macSide.publish(approval: approval)
        #expect(await waitUntil { model.pendingApprovals.map(\.requestId) == [approval.requestId] })

        var resolved = approval
        resolved.status = .resolved
        try await cloud.macSide.publish(approval: resolved)  // the Mac (or the terminal) answered first
        #expect(await waitUntil { model.pendingApprovals.isEmpty })

        try await cloud.macSide.removeSession(id: "s1")
        #expect(await waitUntil { model.sessions.isEmpty })
        model.stop()
    }

    @Test func aDecisionReachesTheMacSide() async throws {
        let cloud = InMemoryCloud()
        let clock = clock
        let approval = makeApproval(clock: clock)
        try await cloud.macSide.publish(approval: approval)
        let model = PhoneModel(
            transport: cloud.phoneSide, authenticator: FakeAuthenticator(result: true), clock: { clock.now })
        model.start()
        #expect(await waitUntil { model.pendingApprovals.count == 1 })
        try await model.allow(approval.requestId)
        var iterator = cloud.macSide.decisions().makeAsyncIterator()
        let decision = await iterator.next()
        #expect(
            decision
                == DecisionRecord(requestId: approval.requestId, decision: .allow, decidedAt: clock.now, source: .phone))
        model.stop()
    }

    @Test func refreshCallsTheTransportRefreshEntryPoint() async {
        let count = Mutex(0)
        let model = makeModel(FakeAuthenticator(result: true), refresh: { count.withLock { $0 += 1 } })
        await model.refresh()
        await model.refresh()
        #expect(count.withLock { $0 } == 2)
    }

    // MARK: Deny from a notification (background)

    @Test func denyFromNotificationWaitsForTheRequestThenDenies() async throws {
        let approval = makeApproval(clock: clock)
        let auth = FakeAuthenticator(result: true)
        let transport = transport
        let pauses = Mutex(0)
        // Cold: nothing loaded yet. The request "arrives" during the third pause, with no real waiting.
        let model = makeModel(
            auth,
            pause: { _ in
                if pauses.withLock({ $0 += 1; return $0 }) == 3 { transport.push(approvals: [approval]) }
                await Task.yield()
            })
        try await model.denyFromNotification(approval.requestId, timeout: .seconds(5))
        #expect(transport.submitted.map(\.requestId) == [approval.requestId])
        #expect(transport.submitted.map(\.decision) == [.deny])
        #expect(auth.calls == 0)
    }

    @Test func denyFromNotificationRefreshesToFindTheRequest() async throws {
        let approval = makeApproval(clock: clock)
        let transport = transport
        let model = makeModel(FakeAuthenticator(result: true), refresh: { transport.push(approvals: [approval]) })
        try await model.denyFromNotification(approval.requestId, timeout: .seconds(5))
        #expect(transport.submitted.map(\.requestId) == [approval.requestId])
    }

    @Test func denyFromNotificationVerifiesPendingAndUnexpired() async {
        let resolved = makeApproval(clock: clock, status: .resolved)
        let late = makeApproval(clock: clock, expiresIn: 5)
        let model = await loadedModel(FakeAuthenticator(result: true), [resolved, late])
        clock.advance(6)
        await #expect(throws: PhoneError.notPending) {
            try await model.denyFromNotification(resolved.requestId, timeout: .milliseconds(200))
        }
        await #expect(throws: PhoneError.expired) {
            try await model.denyFromNotification(late.requestId, timeout: .milliseconds(200))
        }
        #expect(transport.submitted.isEmpty)
    }

    @Test func denyFromNotificationForAnUnknownRequestGivesUp() async {
        let model = makeModel(FakeAuthenticator(result: true))
        await #expect(throws: PhoneError.unknownApproval) {
            try await model.denyFromNotification(UUID(), timeout: .milliseconds(200))
        }
        #expect(transport.submitted.isEmpty)
    }

    // MARK: Allow re-check after the prompt

    /// Allow where the record is republished under the same id while the Face ID prompt is up.
    private func allowWhileRepublished(_ original: ApprovalRecord, as replacement: ApprovalRecord) async -> (
        PhoneError?, Int
    ) {
        let transport = transport
        let holder = Mutex<PhoneModel?>(nil)
        let auth = FakeAuthenticator(
            result: true,
            during: {
                transport.push(approvals: [replacement])
                _ = await waitUntil { holder.withLock { $0 }?.approval(id: original.requestId) == replacement }
            })
        let model = await loadedModel(auth, [original])
        holder.withLock { $0 = model }
        do {
            try await model.allow(original.requestId)
            return (nil, transport.submitted.count)
        } catch {
            return (error as? PhoneError, transport.submitted.count)
        }
    }

    // Checklist: "Allow only covers what was shown" (post-prompt re-check).
    @Test func aRequestRepublishedAsTruncatedWhileThePromptIsUpIsNotAllowed() async {
        let id = UUID()
        let original = makeApproval(id, clock: clock)
        let (error, submitted) = await allowWhileRepublished(
            original, as: makeApproval(id, clock: clock, truncated: true))
        #expect(error == .tooLongToAllow)
        #expect(submitted == 0)
    }

    @Test func aRequestWithOtherTextWhileThePromptIsUpIsNotAllowed() async {
        let id = UUID()
        let original = makeApproval(id, clock: clock, summary: "ls build")
        let (error, submitted) = await allowWhileRepublished(
            original, as: makeApproval(id, clock: clock, summary: "rm -rf /"))
        #expect(error == .changedWhileAuthenticating)
        #expect(submitted == 0)

        let (toolError, toolSubmitted) = await allowWhileRepublished(
            makeApproval(id, clock: clock), as: makeApproval(id, clock: clock, tool: "Write"))
        #expect(toolError == .changedWhileAuthenticating)
        #expect(toolSubmitted == 0)
    }

    @Test func aRepublishWithTheSameTextDoesNotStopAllow() async {
        let id = UUID()
        let original = makeApproval(id, clock: clock, expiresIn: 30)
        let (error, submitted) = await allowWhileRepublished(original, as: makeApproval(id, clock: clock, expiresIn: 90))
        #expect(error == nil)
        #expect(submitted == 1)
    }

    // MARK: Questions

    /// A model that already shows `questions`.
    private func questionModel(_ authenticator: FakeAuthenticator, _ questions: [QuestionRecord]) async -> PhoneModel {
        transport.push(questions: questions)
        let model = makeModel(authenticator)
        #expect(await waitUntil { model.questions.count == questions.count })
        return model
    }

    private func multiSelectQuestions() -> [AskQuestion] {
        [
            AskQuestion(
                text: "Which database?", header: "Database",
                options: [AskOption(label: "Postgres", description: nil), AskOption(label: "SQLite", description: nil)],
                multiSelect: false),
            AskQuestion(
                text: "Which extras?", header: "Extras",
                options: [AskOption(label: "Auth", description: nil), AskOption(label: "Cache", description: nil)],
                multiSelect: true),
        ]
    }

    @Test func answerRequiresAuthentication() async {
        let question = makeQuestion(clock: clock)
        let auth = FakeAuthenticator(result: false)
        let model = await questionModel(auth, [question])
        await #expect(throws: PhoneError.notAuthenticated) { try await model.answer(question.requestId, responses: [["SQLite"]]) }
        #expect(auth.calls == 1)
        #expect(transport.submittedAnswers.isEmpty)
        #expect(model.pendingQuestions.map(\.requestId) == [question.requestId])  // still pending, can be retried
    }

    @Test func answerSubmitsRecord() async throws {
        let question = makeQuestion(clock: clock)
        let auth = FakeAuthenticator(result: true)
        let model = await questionModel(auth, [question])
        try await model.answer(question.requestId, responses: [["SQLite"]])
        #expect(auth.reasons == ["Send this answer to Claude"])
        #expect(
            transport.submittedAnswers == [AnswerRecord(requestId: question.requestId, responses: [["SQLite"]], answeredAt: clock.now)])
        #expect(model.answer(for: question.requestId) == [["SQLite"]])
        #expect(model.pendingQuestions.isEmpty)
    }

    @Test func expiredQuestionNotAnswerable() async {
        let question = makeQuestion(clock: clock, expiresIn: 30)
        let auth = FakeAuthenticator(result: true)
        let model = await questionModel(auth, [question])
        #expect(model.pendingQuestions.count == 1)
        clock.advance(30)  // exactly at expiresAt: expired
        #expect(model.pendingQuestions.isEmpty)
        await #expect(throws: PhoneError.expired) { try await model.answer(question.requestId, responses: [["SQLite"]]) }
        #expect(auth.calls == 0)
        #expect(transport.submittedAnswers.isEmpty)
    }

    @Test func onlyPendingQuestionsAreListed() async {
        let pending = makeQuestion(clock: clock)
        let resolved = makeQuestion(clock: clock, status: .resolved)
        let expired = makeQuestion(clock: clock, status: .expired)
        let model = await questionModel(FakeAuthenticator(result: true), [resolved, pending, expired])
        #expect(model.questions.count == 3)
        #expect(model.pendingQuestions.map(\.requestId) == [pending.requestId])
    }

    @Test func aResolvedOrUnknownQuestionIsNotAnswerable() async {
        let resolved = makeQuestion(clock: clock, status: .resolved)
        let auth = FakeAuthenticator(result: true)
        let model = await questionModel(auth, [resolved])
        await #expect(throws: PhoneError.notPending) { try await model.answer(resolved.requestId, responses: [["SQLite"]]) }
        await #expect(throws: PhoneError.unknownApproval) { try await model.answer(UUID(), responses: [["SQLite"]]) }
        #expect(auth.calls == 0)
        #expect(transport.submittedAnswers.isEmpty)
    }

    @Test func answersThatDoNotFitTheQuestionsAreRefusedBeforeAnyPrompt() async {
        let question = makeQuestion(clock: clock, questions: multiSelectQuestions())
        let auth = FakeAuthenticator(result: true)
        let model = await questionModel(auth, [question])
        let bad: [[[String]]] = [
            [],  // no answers
            [["Postgres"]],  // too few
            [["Postgres"], ["Auth"], ["Cache"]],  // too many
            [["Postgres"], []],  // nothing picked for the second question
            [["Mongo"], ["Auth"]],  // not an option
            [["Postgres", "SQLite"], ["Auth"]],  // two picks for a single-choice question
            [["Postgres"], ["Auth", "Auth"]],  // the same option twice
        ]
        for responses in bad {
            await #expect(throws: PhoneError.incompleteAnswer, "\(responses)") {
                try await model.answer(question.requestId, responses: responses)
            }
        }
        #expect(auth.calls == 0)
        #expect(transport.submittedAnswers.isEmpty)
    }

    @Test func aMultiSelectQuestionTakesSeveralOptions() async throws {
        let question = makeQuestion(clock: clock, questions: multiSelectQuestions())
        let model = await questionModel(FakeAuthenticator(result: true), [question])
        try await model.answer(question.requestId, responses: [["Postgres"], ["Auth", "Cache"]])
        #expect(transport.submittedAnswers.map(\.responses) == [[["Postgres"], ["Auth", "Cache"]]])
    }

    @Test func aFailedSendLeavesTheQuestionOpenForARetry() async throws {
        let question = makeQuestion(clock: clock)
        let model = await questionModel(FakeAuthenticator(result: true), [question])
        transport.failSubmits(true)
        await #expect(throws: PhoneError.submitFailed(RecordingTransport.SubmitFailure().localizedDescription)) {
            try await model.answer(question.requestId, responses: [["SQLite"]])
        }
        #expect(model.pendingQuestions.count == 1)
        #expect(model.answer(for: question.requestId) == nil)
        transport.failSubmits(false)
        try await model.answer(question.requestId, responses: [["SQLite"]])
        #expect(transport.submittedAnswers.count == 1)
    }

    @Test func anEarlierQuestionAnswerThatCountsIsShownInsteadOfThisOne() async {
        let question = makeQuestion(clock: clock)
        let model = await questionModel(FakeAuthenticator(result: true), [question])
        transport.rejectAnswerAsAlreadyRecorded(AnswerAlreadyRecorded(responses: [["Postgres"]]))
        await #expect(throws: PhoneError.answeredEarlier(nil)) {
            try await model.answer(question.requestId, responses: [["SQLite"]])
        }
        #expect(model.answer(for: question.requestId) == [["Postgres"]])
        #expect(model.pendingQuestions.isEmpty)
    }

    @Test func anAnswerIsOnlySentOncePerQuestion() async throws {
        let question = makeQuestion(clock: clock)
        let auth = FakeAuthenticator(result: true)
        let model = await questionModel(auth, [question])
        try await model.answer(question.requestId, responses: [["SQLite"]])
        await #expect(throws: PhoneError.alreadyDecided) { try await model.answer(question.requestId, responses: [["Postgres"]]) }
        #expect(auth.calls == 1)
        #expect(transport.submittedAnswers.count == 1)
    }

    @Test func aQuestionExpiringWhileThePromptIsUpIsNotAnswered() async {
        let question = makeQuestion(clock: clock, expiresIn: 30)
        let clock = clock
        let model = await questionModel(FakeAuthenticator(result: true, during: { clock.advance(31) }), [question])
        await #expect(throws: PhoneError.expired) { try await model.answer(question.requestId, responses: [["SQLite"]]) }
        #expect(transport.submittedAnswers.isEmpty)
    }

    @Test func aQuestionRepublishedWithOtherTextWhileThePromptIsUpIsNotAnswered() async {
        let id = UUID()
        let original = makeQuestion(id, clock: clock)
        let changed = makeQuestion(
            id, clock: clock,
            questions: [
                AskQuestion(
                    text: "Delete everything?", header: "Danger",
                    options: [AskOption(label: "Postgres", description: nil), AskOption(label: "SQLite", description: nil)],
                    multiSelect: false)
            ])
        let transport = transport
        let holder = Mutex<PhoneModel?>(nil)
        let auth = FakeAuthenticator(
            result: true,
            during: {
                transport.push(questions: [changed])
                _ = await waitUntil { holder.withLock { $0 }?.question(id: id) == changed }
            })
        let model = await questionModel(auth, [original])
        holder.withLock { $0 = model }
        await #expect(throws: PhoneError.changedWhileAuthenticating) {
            try await model.answer(id, responses: [["SQLite"]])
        }
        #expect(transport.submittedAnswers.isEmpty)
    }

    @Test func theMacsResolvedRecordTakesTheQuestionOffThePhone() async throws {
        let question = makeQuestion(clock: clock)
        let model = await questionModel(FakeAuthenticator(result: true), [question])
        try await model.answer(question.requestId, responses: [["SQLite"]])
        transport.push(questions: [makeQuestion(question.requestId, clock: clock, status: .resolved)])
        #expect(await waitUntil { model.question(id: question.requestId)?.status == .resolved })
        #expect(model.pendingQuestions.isEmpty)
    }

    // MARK: Polling backoff

    // Checklist: Deny from the lock screen waits for the request without hammering the cloud.
    @Test func denyFromNotificationPollsWithAGrowingPauseCappedAtOneSecond() async {
        let delays = Mutex<[Duration]>([])
        let model = makeModel(
            FakeAuthenticator(result: true),
            pause: { delay in
                delays.withLock { $0.append(delay) }
                try? await Task.sleep(for: .milliseconds(5))  // a little real time, so the 300 ms deadline passes
            })
        await #expect(throws: PhoneError.unknownApproval) {
            try await model.denyFromNotification(UUID(), timeout: .milliseconds(300))
        }
        let seen = delays.withLock { $0 }
        #expect(seen.count > 6)
        #expect(seen.prefix(6).elementsEqual([.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .seconds(1), .seconds(1)]))
        #expect(seen.allSatisfy { $0 <= .seconds(1) })
    }

    // MARK: Error text

    @Test func everyErrorHasAReadableMessage() {
        let errors: [PhoneError] = [
            .notAuthenticated, .tooLongToAllow, .expired, .unknownApproval, .notPending, .alreadyDecided, .busy,
            .changedWhileAuthenticating, .notPlainText, .answeredEarlier(.allow), .answeredEarlier(.deny),
            .answeredEarlier(nil), .submitFailed("offline"), .incompleteAnswer,
        ]
        for error in errors { #expect(!(error.errorDescription ?? "").isEmpty, "\(error)") }
        #expect(PhoneError.tooLongToAllow.errorDescription?.contains("Mac") == true)
        #expect(PhoneError.notPlainText.errorDescription?.contains("Mac") == true)
    }
}
