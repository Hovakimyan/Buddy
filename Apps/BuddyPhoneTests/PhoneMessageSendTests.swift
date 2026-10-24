import BuddyKit
import Foundation
import Testing

@MainActor
@Suite struct PhoneMessageSendTests {
    let clock = TestClock()
    let transport = RecordingTransport()

    private func loadedModel(_ authenticator: FakeAuthenticator) async -> PhoneModel {
        transport.push(sessions: [SessionRecord(
            sessionId: "s1", state: .finished, project: "proj", lastTool: nil, updatedAt: clock.now, awaitingMessage: true)])
        let clock = clock
        let model = PhoneModel(transport: transport, authenticator: authenticator, clock: { clock.now })
        model.start()
        #expect(await waitUntil { model.sessions.count == 1 })
        return model
    }

    @Test func aMessageIsSentOnlyAfterFaceID() async throws {
        let refused = FakeAuthenticator(result: false)
        let model = await loadedModel(refused)
        await #expect(throws: PhoneError.notAuthenticated) { try await model.send(message: "Run the tests", to: "s1") }
        #expect(refused.reasons == [PhoneModel.messageAuthenticationReason])
        #expect(transport.submittedMessages.isEmpty)

        let allowed = FakeAuthenticator(result: true)
        let model2 = await loadedModel(allowed)
        try await model2.send(message: "  Run the tests \n", to: "s1")
        let sent = try #require(transport.submittedMessages.first)
        #expect(sent.text == "Run the tests")
        #expect(sent.sessionId == "s1")
        #expect(sent.sentAt == clock.now)
        #expect(model2.sentMessages["s1"] == [sent])
    }

    @Test func emptyTooLongOrUnknownMessagesAreNotSentNorAuthenticated() async {
        let auth = FakeAuthenticator(result: true)
        let model = await loadedModel(auth)
        await #expect(throws: PhoneError.unsendableMessage) { try await model.send(message: " \n ", to: "s1") }
        await #expect(throws: PhoneError.unsendableMessage) {
            try await model.send(message: String(repeating: "a", count: MessageRecord.maxLength + 1), to: "s1")
        }
        await #expect(throws: PhoneError.unknownSession) { try await model.send(message: "hi", to: "gone") }
        #expect(auth.calls == 0)
        #expect(transport.submittedMessages.isEmpty)
    }

    @Test func aFailedSendIsReportedAndNotListedAsSent() async {
        let model = await loadedModel(FakeAuthenticator(result: true))
        transport.failSubmits(true)
        await #expect(throws: PhoneError.self) { try await model.send(message: "hi", to: "s1") }
        #expect(model.sentMessages["s1"] == nil)
    }

    @Test func aSessionQuietForMoreThan35MinutesIsALeftoverAndNotShown() async {
        transport.push(sessions: [
            SessionRecord(sessionId: "fresh", state: .working, project: "p", lastTool: nil, updatedAt: clock.now - 60),
            SessionRecord(
                sessionId: "stale", state: .waiting, project: "p", lastTool: nil,
                updatedAt: clock.now - PhoneModel.staleSessionAge),
        ])
        let clock = clock
        let model = PhoneModel(transport: transport, authenticator: FakeAuthenticator(result: true), clock: { clock.now })
        model.start()
        #expect(await waitUntil { model.hasLoaded })
        #expect(model.sessions.map(\.sessionId) == ["fresh"])
    }

    @Test func aSessionWaitingForAMessageIsWhatTheHomeScreenLeadsWith() {
        let waiting = SessionRecord(
            sessionId: "s1", state: .finished, project: "proj", lastTool: "Edit", updatedAt: clock.now, awaitingMessage: true)
        #expect(PhoneLook.overall(sessions: [waiting], approvals: 0, questions: 0, connected: true) == .question)
        #expect(PhoneLook.headline(sessions: [waiting], approvals: 0, questions: 0, connected: true).title == "Your turn")
        #expect(PhoneLook.sessionLine(waiting) == "Waiting for your message")
        // Requests still come first.
        #expect(PhoneLook.headline(sessions: [waiting], approvals: 1, questions: 0, connected: true).title == "Claude needs your OK")
        #expect(SessionView.deliveryNote(for: waiting).contains("right away"))
    }
}
