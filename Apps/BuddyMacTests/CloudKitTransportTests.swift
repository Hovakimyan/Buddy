import BuddyKit
@preconcurrency import CloudKit
import Foundation
import Synchronization
import Testing

// Everything runs against `FakeCloudDatabase`: no CKContainer, no network.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let farFuture = Date(timeIntervalSince1970: 4_000_000_000)

private func sessionRecord(_ id: String = "s1", state: SessionState = .working) -> SessionRecord {
    SessionRecord(sessionId: id, state: state, project: "proj-\(id)", lastTool: "Bash", updatedAt: t0)
}

private func approvalRecord(
    _ id: UUID = UUID(), status: ApprovalStatus = .pending, expiresAt: Date = farFuture
) -> ApprovalRecord {
    ApprovalRecord(
        requestId: id, sessionId: "s1", status: status, tool: "Bash", summary: "ls -la",
        isTruncated: false, createdAt: t0, expiresAt: expiresAt)
}

private func decisionRecord(_ id: UUID, _ decision: Decision = .allow) -> DecisionRecord {
    DecisionRecord(requestId: id, decision: decision, decidedAt: t0, source: .phone)
}

private func questionRecord(
    _ id: UUID = UUID(), status: ApprovalStatus = .pending, expiresAt: Date = farFuture
) -> QuestionRecord {
    QuestionRecord(
        requestId: id, sessionId: "s1", status: status,
        questions: [
            AskQuestion(
                text: "Which database?", header: "Database",
                options: [AskOption(label: "Postgres", description: nil), AskOption(label: "SQLite", description: nil)],
                multiSelect: false)
        ],
        createdAt: t0, expiresAt: expiresAt)
}

private func answerRecord(_ id: UUID, _ responses: [[String]] = [["Postgres"]]) -> AnswerRecord {
    AnswerRecord(requestId: id, responses: responses, answeredAt: t0)
}

private func mac(
    _ db: FakeCloudDatabase, pollInterval: Duration = .seconds(3600),
    clock: @escaping @Sendable () -> Date = { t0 }
) -> CloudKitTransport {
    CloudKitTransport(role: .mac, database: db, clock: clock, pollInterval: pollInterval)
}

private func phone(_ db: FakeCloudDatabase) -> CloudKitTransport {
    CloudKitTransport(role: .phone, database: db, phonePollInterval: .seconds(3600))
}

private final class WeakBox: @unchecked Sendable {
    weak var value: CloudKitTransport?
}

@Suite struct CloudKitTransportTests {
    // MARK: Publishing

    @Test func firstPublishCreatesZoneAndSubscriptionThenUpserts() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        try await transport.publish(session: sessionRecord())
        try await transport.publish(session: sessionRecord(state: .finished))

        #expect(db.zoneExists)
        #expect(db.calls(.saveZone) == 1)  // setup is shared, not repeated per publish
        #expect(db.calls(.saveSubscription) == 3)  // the Mac's three (decision, answer, message), once
        #expect(db.recordNames(ofType: "Session") == ["s1"])  // upsert, not a second record
        #expect(db.lastSavePolicy == .allKeys)
        let stored = try #require(db.record(named: "s1"))
        #expect(SessionRecord(from: stored)?.state == .finished)
    }

    @Test func storedApprovalKeepsSensitiveFieldsEncrypted() async throws {
        let db = FakeCloudDatabase()
        let id = UUID()
        try await mac(db).publish(approval: approvalRecord(id))
        let stored = try #require(db.record(named: id.uuidString))
        #expect(stored.recordID.zoneID == CloudKitSchema.zoneID)
        #expect(stored["summary"] == nil)
        #expect(stored["tool"] == nil)
        #expect(stored.encryptedValues["summary"] as? String == "ls -la")
    }

    @Test func concurrentFirstPublishesShareOneSetup() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { try await transport.publish(session: sessionRecord("s\(index)")) }
            }
            try await group.waitForAll()
        }
        #expect(db.calls(.saveZone) == 1)
        #expect(db.recordNames(ofType: "Session").count == 8)
    }

    @Test func userDeletedZoneIsRecreatedLikeAMissingOne() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        try await transport.publish(session: sessionRecord())
        db.fail(.save, with: CKError(.userDeletedZone))
        try await transport.publish(session: sessionRecord(state: .idle))
        #expect(db.calls(.saveZone) == 2)
        #expect(SessionRecord(from: try #require(db.record(named: "s1")))?.state == .idle)
    }

    @Test func vanishedZoneIsRecreatedAndThePublishSucceeds() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        try await transport.publish(session: sessionRecord())
        db.dropZone()
        try await transport.publish(session: sessionRecord(state: .idle))
        #expect(db.calls(.saveZone) == 2)
        #expect(db.recordNames(ofType: "Session") == ["s1"])
    }

    @Test func transientErrorsAreThrownSoTheBridgeRetries() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        for code in [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable, .serverResponseLost] {
            db.fail(.save, with: CKError(code))
            await #expect(throws: CKError.self) { try await transport.publish(session: sessionRecord()) }
        }
        // And it works again once the network does.
        try await transport.publish(session: sessionRecord())
        #expect(db.recordNames(ofType: "Session") == ["s1"])
    }

    @Test func setupFailureIsRetriedOnTheNextCall() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        db.fail(.saveZone, with: CKError(.networkUnavailable))
        await #expect(throws: CKError.self) { try await transport.publish(session: sessionRecord()) }
        try await transport.publish(session: sessionRecord())
        #expect(db.zoneExists)
    }

    @Test func shortRetryAfterIsHonouredInline() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        db.fail(.save, with: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 0.02]))
        try await transport.publish(session: sessionRecord())  // retried once, after 20 ms
        #expect(db.calls(.save) == 2)
        #expect(db.recordNames(ofType: "Session") == ["s1"])
    }

    @Test func longRetryAfterIsLeftToTheCaller() async {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        db.fail(.save, with: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 600.0]))
        await #expect(throws: CKError.self) { try await transport.publish(session: sessionRecord()) }
        #expect(db.calls(.save) == 1)
    }

    @Test func permanentErrorsAreThrownToo() async {
        let db = FakeCloudDatabase()
        db.fail(.save, with: CKError(.notAuthenticated))
        await #expect(throws: CKError.self) { try await mac(db).publish(session: sessionRecord()) }
    }

    @Test func removeSessionDeletesAndMissingIsFine() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        try await transport.publish(session: sessionRecord())
        try await transport.removeSession(id: "s1")
        #expect(db.recordNames(ofType: "Session").isEmpty)
        try await transport.removeSession(id: "s1")  // already gone
        try await mac(FakeCloudDatabase()).removeSession(id: "never-published")  // no zone at all
    }

    // MARK: Subscriptions

    @Test func macRegistersTheSilentDecisionAnswerAndMessageSubscriptionsOnly() async throws {
        let db = FakeCloudDatabase()
        try await mac(db).publish(session: sessionRecord())
        let ids = [CloudKitSchema.decisionSubscriptionID, CloudKitSchema.answerSubscriptionID, CloudKitSchema.messageSubscriptionID]
        #expect(Set(db.subscriptions.keys) == Set(ids))
        for id in ids {
            #expect(db.subscriptions[id]?.notificationInfo?.shouldSendContentAvailable == true)
        }
    }

    @Test func phoneRegistersTheApprovalAndQuestionAlertSubscriptionsOnly() async throws {
        let db = FakeCloudDatabase()
        try await phone(db).submit(decision: decisionRecord(UUID()))
        #expect(Set(db.subscriptions.keys) == [CloudKitSchema.approvalSubscriptionID, CloudKitSchema.questionSubscriptionID])
        let approvalInfo = db.subscriptions[CloudKitSchema.approvalSubscriptionID]?.notificationInfo
        #expect(approvalInfo?.category == "BUDDY_APPROVAL")
        #expect(approvalInfo?.alertBody == "Claude Code needs approval")
        let questionInfo = db.subscriptions[CloudKitSchema.questionSubscriptionID]?.notificationInfo
        #expect(questionInfo?.category == "BUDDY_QUESTION")
        #expect(questionInfo?.alertBody == "Claude is asking")
        // Without it iOS never runs the notification service, and the text stays generic.
        #expect(approvalInfo?.shouldSendMutableContent == true)
        #expect(questionInfo?.shouldSendMutableContent == true)
    }

    @Test func failedSubscriptionNeverStopsRecordsAndIsRetriedLaterNotInATightLoop() async throws {
        let db = FakeCloudDatabase()
        let now = Mutex(t0)
        let transport = mac(db) { now.withLock { $0 } }
        // The first attempts fail, whatever the reason (e.g. record type not created yet in Development).
        // The Mac saves three subscriptions per attempt (decision, answer, message), each independently of the others.
        db.fail(.saveSubscription, with: CKError(.permissionFailure), times: 4)

        try await transport.publish(session: sessionRecord("a"))
        #expect(db.recordNames(ofType: "Session") == ["a"])  // records flow regardless
        #expect(db.subscriptions.isEmpty)
        #expect(db.calls(.saveSubscription) == 3)

        try await transport.publish(session: sessionRecord("b"))  // too soon: not retried
        try await transport.publish(session: sessionRecord("c"))
        #expect(db.calls(.saveSubscription) == 3)

        now.withLock { $0 = t0.addingTimeInterval(CloudKitTransport.subscriptionRetryInterval + 1) }
        try await transport.publish(session: sessionRecord("d"))  // decision fails again, the others save
        #expect(db.calls(.saveSubscription) == 6)
        #expect(Set(db.subscriptions.keys) == [CloudKitSchema.answerSubscriptionID, CloudKitSchema.messageSubscriptionID])

        now.withLock { $0 = t0.addingTimeInterval(2 * (CloudKitTransport.subscriptionRetryInterval + 1)) }
        try await transport.publish(session: sessionRecord("e"))  // only the missing one is tried, and saves
        #expect(Set(db.subscriptions.keys) == [
            CloudKitSchema.decisionSubscriptionID, CloudKitSchema.answerSubscriptionID, CloudKitSchema.messageSubscriptionID,
        ])
        #expect(db.calls(.saveSubscription) == 7)

        now.withLock { $0 = t0.addingTimeInterval(10_000) }
        try await transport.publish(session: sessionRecord("f"))  // saved once: never again
        #expect(db.calls(.saveSubscription) == 7)
    }

    @Test func transientSubscriptionFailureDoesNotFailThePublish() async throws {
        let db = FakeCloudDatabase()
        db.fail(.saveSubscription, with: CKError(.networkUnavailable))
        try await mac(db).publish(session: sessionRecord())
        #expect(db.recordNames(ofType: "Session") == ["s1"])
    }

    @Test func recreatedZoneGetsItsSubscriptionAgain() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        try await transport.publish(session: sessionRecord())
        db.dropZone()
        try await transport.publish(session: sessionRecord())
        #expect(db.calls(.saveSubscription) == 6)  // all three subscriptions, twice
    }

    // MARK: Decisions (Mac)

    @Test func decisionReachesTheMacOnAPush() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let phone = phone(db)
        let collector = Collector(transport.decisions())
        let id = UUID()
        try await transport.publish(approval: approvalRecord(id, expiresAt: t0))  // not pending: no polling
        try await phone.submit(decision: decisionRecord(id, .deny))

        #expect(transport.handleNotification(subscriptionID: CloudKitSchema.decisionSubscriptionID))
        #expect(await collector.wait { $0.count == 1 })
        #expect(collector.all.first?.requestId == id)
        #expect(collector.all.first?.decision == .deny)
        #expect(!transport.handleNotification(subscriptionID: "somebody-elses"))
        #expect(!transport.handleNotification(subscriptionID: nil))
    }

    @Test func boundedPollFindsADecisionWithoutAnyPush() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(15))
        let collector = Collector(transport.decisions())
        let id = UUID()
        try await transport.publish(approval: approvalRecord(id))  // pending: starts the poll
        try await phone(db).submit(decision: decisionRecord(id))
        #expect(await collector.wait { $0.count == 1 })
        #expect(collector.all.first?.requestId == id)
    }

    @Test func pollStopsOnceNothingIsPending() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(10))
        let id = UUID()
        try await transport.publish(approval: approvalRecord(id))
        #expect(await eventually { db.calls(.changes) >= 3 })  // polling while pending

        try await transport.publish(approval: approvalRecord(id, status: .resolved))
        try await Task.sleep(for: .milliseconds(100))  // let an in-flight poll finish
        let settled = db.calls(.changes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(db.calls(.changes) == settled)
    }

    @Test func pollStopsWhenTheApprovalExpires() async throws {
        let db = FakeCloudDatabase()
        let now = Mutex(t0)
        let transport = mac(db, pollInterval: .milliseconds(10)) { now.withLock { $0 } }
        try await transport.publish(approval: approvalRecord(expiresAt: t0.addingTimeInterval(110)))
        #expect(await eventually { db.calls(.changes) >= 2 })

        now.withLock { $0 = t0.addingTimeInterval(111) }
        try await Task.sleep(for: .milliseconds(100))
        let settled = db.calls(.changes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(db.calls(.changes) == settled)
    }

    @Test func noPollingWithoutAPendingApproval() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(10))
        try await transport.publish(session: sessionRecord())
        try await transport.publish(approval: approvalRecord(status: .resolved))
        try await transport.publish(approval: approvalRecord(expiresAt: t0))  // already expired
        try await Task.sleep(for: .milliseconds(100))
        #expect(db.calls(.changes) == 0)
    }

    @Test func eachDecisionIsDeliveredOnceAndTheFirstOneWins() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(10))
        let phone = phone(db)
        let collector = Collector(transport.decisions())
        let id = UUID()
        try await transport.publish(approval: approvalRecord(id))

        try await phone.submit(decision: decisionRecord(id, .allow))
        // A flip is refused and says which answer stands; the same answer again (a retry) is fine.
        await #expect(throws: DecisionAlreadyRecorded(decision: .allow)) {
            try await phone.submit(decision: decisionRecord(id, .deny))
        }
        try await phone.submit(decision: decisionRecord(id, .allow))
        #expect(await collector.wait { !$0.isEmpty })
        try await Task.sleep(for: .milliseconds(80))
        await transport.pullPhoneInput()
        try await Task.sleep(for: .milliseconds(30))

        #expect(collector.all.map(\.decision) == [.allow])
        #expect(db.lastSavePolicy == .ifServerRecordUnchanged)
    }

    @Test func aLateSubscriberGetsTheDecisionsAlreadySeen() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let id = UUID()
        try await phone(db).submit(decision: decisionRecord(id))
        let first = Collector(transport.decisions())
        #expect(await first.wait { $0.count == 1 })
        let second = Collector(transport.decisions())
        #expect(await second.wait { $0.count == 1 })
        #expect(second.all.first?.requestId == id)
    }

    @Test func malformedOrForgedDecisionRecordsAreIgnored() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let collector = Collector(transport.decisions())
        _ = await eventually { db.zoneExists }

        let bad = UUID()
        let junk = CKRecord(
            recordType: "Decision", recordID: CKRecord.ID(recordName: CloudKitSchema.decisionRecordName(for: bad), zoneID: CloudKitSchema.zoneID))
        junk["requestId"] = bad.uuidString
        junk["decision"] = "always-allow-everything"
        junk["decidedAt"] = t0
        junk["source"] = "mac"
        db.inject(junk)
        let forged = CKRecord(
            recordType: "Decision", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: CloudKitSchema.zoneID))
        forged["requestId"] = bad.uuidString  // claims another request's id
        forged["decision"] = "allow"
        forged["decidedAt"] = t0
        forged["source"] = "phone"
        db.inject(forged)
        let good = UUID()
        db.inject(CKRecord(from: decisionRecord(good)))

        await transport.pullPhoneInput()
        #expect(await collector.wait { !$0.isEmpty })
        try await Task.sleep(for: .milliseconds(30))
        #expect(collector.all.map(\.requestId) == [good])
    }

    @Test func fetchFailureIsRetriedByTheNextPull() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let id = UUID()
        try await phone(db).submit(decision: decisionRecord(id))
        db.fail(.changes, with: CKError(.networkUnavailable))
        let collector = Collector(transport.decisions())  // first pull fails
        _ = await eventually { db.calls(.changes) >= 1 }
        transport.handleNotification(subscriptionID: CloudKitSchema.decisionSubscriptionID)
        #expect(await collector.wait { $0.count == 1 })
    }

    @Test func expiredChangeTokenRestartsTheFetchFromScratch() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let collector = Collector(transport.decisions())
        _ = await eventually { db.calls(.changes) >= 1 }
        try await phone(db).submit(decision: decisionRecord(UUID()))
        db.fail(.changes, with: CKError(.changeTokenExpired))
        await transport.pullPhoneInput()  // fails, forgets the token
        await transport.pullPhoneInput()  // full fetch again
        #expect(await collector.wait { $0.count == 1 })
    }

    // MARK: Per-record fetch failures (CloudKit reports them per item; one bad record must not stall the feed)

    @Test func aBadRecordInADecisionFetchIsSkippedAndTheTokenStillAdvances() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let collector = Collector(transport.decisions())
        _ = await eventually { db.calls(.changes) >= 1 }

        let bad = UUID(), good1 = UUID(), good2 = UUID()
        let badRecord = CKRecord(from: decisionRecord(bad))
        db.inject(CKRecord(from: decisionRecord(good1)))
        db.inject(badRecord)
        db.poison(badRecord.recordID)
        db.inject(CKRecord(from: decisionRecord(good2)))

        await transport.pullPhoneInput()
        #expect(await collector.wait { $0.count == 2 })
        #expect(Set(collector.all.map(\.requestId)) == [good1, good2])

        // The token moved past the bad record: a later fetch does not hit it again, and keeps working.
        let before = db.calls(.changes)
        let good3 = UUID()
        db.inject(CKRecord(from: decisionRecord(good3)))
        await transport.pullPhoneInput()
        #expect(await collector.wait { $0.count == 3 })
        #expect(collector.all.last?.requestId == good3)
        #expect(db.calls(.changes) == before + 1)
    }

    @Test func aBadRecordDoesNotStallThePhoneMirrorOrCleanup() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let phoneSide = phone(db)
        let good = UUID(), bad = UUID(), old = UUID()
        db.inject(CKRecord(from: approvalRecord(good)))
        let badRecord = CKRecord(from: approvalRecord(bad))
        db.inject(badRecord)
        db.poison(badRecord.recordID)
        db.inject(CKRecord(from: approvalRecord(old, status: .resolved)))

        let approvals = Collector(phoneSide.approvals())
        #expect(await approvals.wait { Set($0.last?.map(\.requestId) ?? []) == [good, old] })

        // Cleanup still removes what it can see.
        db.setNow(t0.addingTimeInterval(1000))
        try await transport.deleteRecords(olderThan: t0.addingTimeInterval(500))
        #expect(db.recordNames(ofType: "Approval") == [bad.uuidString])  // the unreadable one is left alone
    }

    @Test func absorbSkipsFailuresAndKeepsTheRest() {
        let zone = CloudKitSchema.zoneID
        let ok = CKRecord(recordType: "Approval", recordID: CKRecord.ID(recordName: "ok", zoneID: zone))
        var changes = ZoneChanges()
        changes.absorb(modifications: [
            (ok.recordID, .success(ChangedRecord(record: ok, modifiedAt: nil))),
            (CKRecord.ID(recordName: "broken", zoneID: zone), .failure(CKError(.internalError))),
        ])
        #expect(changes.records.map(\.record.recordID.recordName) == ["ok"])
        #expect(changes.skippedCount == 1)
    }

    // MARK: Questions and answers (Mac)

    @Test func storedQuestionKeepsItsContentEncrypted() async throws {
        let db = FakeCloudDatabase()
        let id = UUID()
        try await mac(db).publish(question: questionRecord(id))
        let stored = try #require(db.record(named: id.uuidString))
        #expect(stored.recordType == "Question")
        #expect(stored.recordID.zoneID == CloudKitSchema.zoneID)
        #expect(stored["questions"] == nil)
        #expect(stored.encryptedValues["questions"] != nil)
        #expect(QuestionRecord(from: stored) == questionRecord(id))
        #expect(db.lastSavePolicy == .allKeys)  // republish (status change) is an upsert
    }

    @Test func answerReachesTheMacOnAPush() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let phone = phone(db)
        let collector = Collector(transport.answers())
        let id = UUID()
        try await transport.publish(question: questionRecord(id, expiresAt: t0))  // not pending: no polling
        try await phone.submit(answer: answerRecord(id, [["SQLite"]]))

        #expect(transport.handleNotification(subscriptionID: "buddy.answer.created"))
        #expect(await collector.wait { $0.count == 1 })
        #expect(collector.all.first == answerRecord(id, [["SQLite"]]))
        #expect(db.recordNames(ofType: "Answer") == ["answer-\(id.uuidString)"])
    }

    @Test func boundedPollFindsAnAnswerWithoutAnyPush() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(15))
        let collector = Collector(transport.answers())
        let id = UUID()
        try await transport.publish(question: questionRecord(id))  // pending: starts the poll
        try await phone(db).submit(answer: answerRecord(id))
        #expect(await collector.wait { $0.count == 1 })
        #expect(collector.all.first?.requestId == id)
    }

    @Test func pollStopsOnceTheQuestionIsNoLongerPending() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(10))
        let id = UUID()
        try await transport.publish(question: questionRecord(id))
        #expect(await eventually { db.calls(.changes) >= 3 })

        try await transport.publish(question: questionRecord(id, status: .resolved))
        try await Task.sleep(for: .milliseconds(100))
        let settled = db.calls(.changes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(db.calls(.changes) == settled)
    }

    @Test func eachAnswerIsDeliveredOnceAndTheFirstOneWins() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let phone = phone(db)
        let collector = Collector(transport.answers())
        let id = UUID()

        try await phone.submit(answer: answerRecord(id, [["Postgres"]]))
        // A second, different answer does not replace the first; the same one again (a retry) is fine.
        await #expect(throws: AnswerAlreadyRecorded(responses: [["Postgres"]])) {
            try await phone.submit(answer: answerRecord(id, [["SQLite"]]))
        }
        try await phone.submit(answer: answerRecord(id, [["Postgres"]]))
        transport.handleNotification(subscriptionID: CloudKitSchema.answerSubscriptionID)
        #expect(await collector.wait { !$0.isEmpty })
        await transport.pullPhoneInput()
        try await Task.sleep(for: .milliseconds(30))

        #expect(collector.all.map(\.responses) == [[["Postgres"]]])
        #expect(db.lastSavePolicy == .ifServerRecordUnchanged)
    }

    @Test func savingTheSameAnswerAgainSucceedsAndADifferentOneSaysWhichStands() async throws {
        let db = FakeCloudDatabase()
        let phone = phone(db)
        let id = UUID()
        try await phone.submit(answer: answerRecord(id, [["Postgres"], ["A", "B"]]))

        // Same responses (a retry whose reply was lost): success, whatever the timestamp.
        let later = AnswerRecord(requestId: id, responses: [["Postgres"], ["A", "B"]], answeredAt: t0.addingTimeInterval(5))
        try await phone.submit(answer: later)
        // Different responses: refused, naming the one that counts.
        await #expect(throws: AnswerAlreadyRecorded(responses: [["Postgres"], ["A", "B"]])) {
            try await phone.submit(answer: answerRecord(id, [["SQLite"], ["A", "B"]]))
        }
        await #expect(throws: AnswerAlreadyRecorded(responses: [["Postgres"], ["A", "B"]])) {
            try await phone.submit(answer: answerRecord(id, [["Postgres"]]))
        }
    }

    @Test func anUnreadableStoredAnswerIsReportedWithoutResponses() async throws {
        let db = FakeCloudDatabase()
        let phone = phone(db)
        let id = UUID()
        // A record at the answer's name that is not a valid Answer (no responses).
        let bad = CKRecord(
            recordType: "Answer",
            recordID: CKRecord.ID(recordName: CloudKitSchema.answerRecordName(for: id), zoneID: CloudKitSchema.zoneID))
        bad["requestId"] = id.uuidString
        db.inject(bad)
        await #expect(throws: AnswerAlreadyRecorded(responses: nil)) {
            try await phone.submit(answer: answerRecord(id, [["Postgres"]]))
        }
    }

    @Test func aLateSubscriberGetsTheAnswersAlreadySeen() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let id = UUID()
        try await phone(db).submit(answer: answerRecord(id))
        let first = Collector(transport.answers())
        #expect(await first.wait { $0.count == 1 })
        let second = Collector(transport.answers())
        #expect(await second.wait { $0.count == 1 })
        #expect(second.all.first?.requestId == id)
    }

    @Test func decisionsAndAnswersShareOneFeedWithoutLosingEither() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let phone = phone(db)
        let decisionID = UUID(), answerID = UUID()
        try await phone.submit(decision: decisionRecord(decisionID))
        try await phone.submit(answer: answerRecord(answerID))
        let decisions = Collector(transport.decisions())
        let answers = Collector(transport.answers())
        #expect(await decisions.wait { $0.count == 1 })
        #expect(await answers.wait { $0.count == 1 })
        #expect(decisions.all.first?.requestId == decisionID)
        #expect(answers.all.first?.requestId == answerID)
    }

    @Test func malformedOrForgedAnswerRecordsAreIgnored() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let collector = Collector(transport.answers())
        _ = await eventually { db.zoneExists }

        let bad = UUID()
        let junk = CKRecord(
            recordType: "Answer", recordID: CKRecord.ID(recordName: CloudKitSchema.answerRecordName(for: bad), zoneID: CloudKitSchema.zoneID))
        junk["requestId"] = bad.uuidString
        junk["answeredAt"] = t0
        junk.encryptedValues["responses"] = Data("not json".utf8)
        db.inject(junk)
        let forged = CKRecord(
            recordType: "Answer", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: CloudKitSchema.zoneID))
        forged["requestId"] = bad.uuidString  // claims another request's id
        forged["answeredAt"] = t0
        forged.encryptedValues["responses"] = Data("[[\"Postgres\"]]".utf8)
        db.inject(forged)
        let good = UUID()
        db.inject(CKRecord(from: answerRecord(good)))

        await transport.pullPhoneInput()
        #expect(await collector.wait { !$0.isEmpty })
        try await Task.sleep(for: .milliseconds(30))
        #expect(collector.all.map(\.requestId) == [good])
    }

    @Test func stopFinishesAnswerStreams() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let stream = transport.answers()
        transport.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    // MARK: Stopping

    @Test(.timeLimit(.minutes(1))) func stopEndsPollingAndFinishesStreams() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(10))
        let stream = transport.decisions()
        try await transport.publish(approval: approvalRecord())  // pending: polling
        #expect(await eventually { db.calls(.changes) >= 3 })

        transport.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)  // finished
        try await Task.sleep(for: .milliseconds(100))  // let an in-flight poll end
        let settled = db.calls(.changes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(db.calls(.changes) == settled)
    }

    @Test(.timeLimit(.minutes(1))) func stopEndsThePhonePollToo() async throws {
        let db = FakeCloudDatabase()
        let transport = CloudKitTransport(role: .phone, database: db, phonePollInterval: .milliseconds(10))
        let stream = transport.approvals()
        #expect(await eventually { db.calls(.changes) >= 3 })
        transport.stop()
        for await _ in stream {}  // returns only because the stream was finished
        try await Task.sleep(for: .milliseconds(100))
        let settled = db.calls(.changes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(db.calls(.changes) == settled)
    }

    @Test func aTransportThatIsReleasedStopsPolling() async throws {
        let db = FakeCloudDatabase()
        let released = WeakBox()
        do {
            let transport = mac(db, pollInterval: .milliseconds(10))
            released.value = transport
            try await transport.publish(approval: approvalRecord())
            #expect(await eventually { db.calls(.changes) >= 2 })
        }
        #expect(await eventually { released.value == nil })  // the poll task does not keep it alive
        try await Task.sleep(for: .milliseconds(100))
        let settled = db.calls(.changes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(db.calls(.changes) == settled)
    }

    @Test func aStoppedTransportWorksAgain() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db, pollInterval: .milliseconds(10))
        _ = transport.decisions()
        transport.stop()
        let collector = Collector(transport.decisions())
        let id = UUID()
        try await transport.publish(approval: approvalRecord(id))
        try await phone(db).submit(decision: decisionRecord(id))
        #expect(await collector.wait { $0.count == 1 })
    }

    // MARK: Cleanup

    @Test func deleteRecordsRemovesOldApprovalsAndDecisionsAndOrphanSessionsOnly() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let phone = phone(db)

        db.setNow(t0)  // old
        let oldApproval = UUID(), oldDecision = UUID()
        try await transport.publish(approval: approvalRecord(oldApproval, status: .resolved))
        try await phone.submit(decision: decisionRecord(oldDecision))
        db.inject(CKRecord(from: sessionRecord("orphan-from-last-run")))
        try await transport.publish(session: sessionRecord("live-but-quiet"))

        db.setNow(t0.addingTimeInterval(700))  // fresh
        let newApproval = UUID()
        try await transport.publish(approval: approvalRecord(newApproval))
        db.inject(CKRecord(from: sessionRecord("orphan-but-fresh")))

        try await transport.deleteRecords(olderThan: t0.addingTimeInterval(600))

        #expect(db.recordNames(ofType: "Approval") == [newApproval.uuidString])
        #expect(db.recordNames(ofType: "Decision").isEmpty)
        #expect(db.recordNames(ofType: "Session") == ["live-but-quiet", "orphan-but-fresh"])
    }

    @Test func deleteRecordsIsBoundedPerCall() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        for _ in 0..<(CloudKitTransport.deleteBatchLimit + 25) {
            db.inject(CKRecord(from: approvalRecord(UUID(), status: .resolved)))
        }
        try await transport.deleteRecords(olderThan: t0.addingTimeInterval(60))
        #expect(db.recordNames(ofType: "Approval").count == 25)
        try await transport.deleteRecords(olderThan: t0.addingTimeInterval(60))
        #expect(db.recordNames(ofType: "Approval").isEmpty)
    }

    @Test func deleteRecordsWithoutAZoneIsANoOp() async throws {
        let db = FakeCloudDatabase()
        try await mac(db).deleteRecords(olderThan: t0)
        #expect(db.calls(.delete) == 0)
    }

    @Test func deleteRecordsRemovesOldQuestionsAndAnswersToo() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let phone = phone(db)

        db.setNow(t0)  // old
        let oldQuestion = UUID(), oldAnswer = UUID()
        try await transport.publish(question: questionRecord(oldQuestion, status: .resolved))
        try await phone.submit(answer: answerRecord(oldAnswer))

        db.setNow(t0.addingTimeInterval(700))  // fresh
        let newQuestion = UUID(), newAnswer = UUID()
        try await transport.publish(question: questionRecord(newQuestion))
        try await phone.submit(answer: answerRecord(newAnswer))

        try await transport.deleteRecords(olderThan: t0.addingTimeInterval(600))

        #expect(db.recordNames(ofType: "Question") == [newQuestion.uuidString])
        #expect(db.recordNames(ofType: "Answer") == ["answer-\(newAnswer.uuidString)"])
    }

    @Test func answersRemovedByCleanupAreForgottenLocally() async throws {
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let id = UUID()
        try await phone(db).submit(answer: answerRecord(id))
        let first = Collector(transport.answers())
        #expect(await first.wait { $0.count == 1 })
        db.setNow(t0)
        try await transport.deleteRecords(olderThan: t0.addingTimeInterval(1))
        #expect(db.recordNames(ofType: "Answer").isEmpty)
        let second = Collector(transport.answers())
        try await Task.sleep(for: .milliseconds(50))
        #expect(second.all.isEmpty)
    }

    @Test func decisionsRemovedByCleanupAreForgottenLocally() async throws {
        // A decision removed by cleanup is also forgotten locally (memory stays bounded), so a later
        // subscriber is not replayed it.
        let db = FakeCloudDatabase()
        let transport = mac(db)
        let id = UUID()
        try await phone(db).submit(decision: decisionRecord(id))
        let first = Collector(transport.decisions())
        #expect(await first.wait { $0.count == 1 })
        db.setNow(t0)
        try await transport.deleteRecords(olderThan: t0.addingTimeInterval(1))
        #expect(db.recordNames(ofType: "Decision").isEmpty)
        let second = Collector(transport.decisions())
        try await Task.sleep(for: .milliseconds(50))
        #expect(second.all.isEmpty)
    }

    // MARK: Phone side

    @Test func phoneSeesTheFullSetThenEveryChange() async throws {
        let db = FakeCloudDatabase()
        let macSide = mac(db)
        let phoneSide = phone(db)
        let a = UUID(), b = UUID()
        try await macSide.publish(approval: approvalRecord(a))

        let approvals = Collector(phoneSide.approvals())
        #expect(await approvals.wait { $0.last?.map(\.requestId) == [a] })

        try await macSide.publish(approval: approvalRecord(b))
        await phoneSide.refresh()
        #expect(await approvals.wait { Set($0.last?.map(\.requestId) ?? []) == [a, b] })

        try await macSide.publish(approval: approvalRecord(a, status: .resolved))
        await phoneSide.refresh()
        #expect(await approvals.wait { $0.last?.first { $0.requestId == a }?.status == .resolved })

        let count = approvals.all.count
        await phoneSide.refresh()  // nothing changed: no new snapshot
        try await Task.sleep(for: .milliseconds(30))
        #expect(approvals.all.count == count)
    }

    @Test func phoneSeesSessionsAppearAndDisappear() async throws {
        let db = FakeCloudDatabase()
        let macSide = mac(db)
        let phoneSide = phone(db)
        try await macSide.publish(session: sessionRecord("a"))
        let sessions = Collector(phoneSide.sessions())
        #expect(await sessions.wait { $0.last?.map(\.sessionId) == ["a"] })
        #expect(sessions.all.last?.first?.project == "proj-a")

        try await macSide.removeSession(id: "a")
        await phoneSide.refresh()
        #expect(await sessions.wait { $0.last?.isEmpty == true })
    }

    @Test func phoneIgnoresMalformedRecords() async throws {
        let db = FakeCloudDatabase()
        let junk = CKRecord(recordType: "Approval", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: CloudKitSchema.zoneID))
        junk["status"] = 12
        db.inject(junk)
        let good = UUID()
        db.inject(CKRecord(from: approvalRecord(good)))
        let phoneSide = phone(db)  // the transport must outlive its streams
        let approvals = Collector(phoneSide.approvals())
        #expect(await approvals.wait { $0.last?.map(\.requestId) == [good] })
    }

    @Test func pushRefreshesThePhone() async throws {
        let db = FakeCloudDatabase()
        let macSide = mac(db)
        let phoneSide = phone(db)
        try await macSide.publish(session: sessionRecord())
        let approvals = Collector(phoneSide.approvals())
        #expect(await approvals.wait { $0.last?.isEmpty == true })
        let id = UUID()
        try await macSide.publish(approval: approvalRecord(id))
        #expect(phoneSide.handleNotification(subscriptionID: CloudKitSchema.approvalSubscriptionID))
        #expect(await approvals.wait { $0.last?.map(\.requestId) == [id] })
    }

    @Test func phoneSeesQuestionsFullSetThenEveryChange() async throws {
        let db = FakeCloudDatabase()
        let macSide = mac(db)
        let phoneSide = phone(db)
        let a = UUID(), b = UUID()
        try await macSide.publish(question: questionRecord(a))

        let questions = Collector(phoneSide.questions())
        #expect(await questions.wait { $0.last?.map(\.requestId) == [a] })
        #expect(questions.all.last?.first == questionRecord(a))

        try await macSide.publish(question: questionRecord(b))
        await phoneSide.refresh()
        #expect(await questions.wait { Set($0.last?.map(\.requestId) ?? []) == [a, b] })

        try await macSide.publish(question: questionRecord(a, status: .resolved))
        await phoneSide.refresh()
        #expect(await questions.wait { $0.last?.first { $0.requestId == a }?.status == .resolved })

        let count = questions.all.count
        await phoneSide.refresh()  // nothing changed: no new snapshot
        try await Task.sleep(for: .milliseconds(30))
        #expect(questions.all.count == count)
    }

    @Test func phoneRemovesAQuestionTheMacDeleted() async throws {
        let db = FakeCloudDatabase()
        let macSide = mac(db)
        let phoneSide = phone(db)
        let id = UUID()
        db.setNow(t0)
        try await macSide.publish(question: questionRecord(id, status: .resolved))
        let questions = Collector(phoneSide.questions())
        #expect(await questions.wait { $0.last?.map(\.requestId) == [id] })

        try await macSide.deleteRecords(olderThan: t0.addingTimeInterval(1))
        db.setNow(t0.addingTimeInterval(5))
        await phoneSide.refresh()
        #expect(await questions.wait { $0.last?.isEmpty == true })
    }

    @Test func phoneIgnoresMalformedQuestionRecords() async throws {
        let db = FakeCloudDatabase()
        let junk = CKRecord(recordType: "Question", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: CloudKitSchema.zoneID))
        junk["status"] = 12
        junk.encryptedValues["questions"] = Data("not json".utf8)
        db.inject(junk)
        let good = UUID()
        db.inject(CKRecord(from: questionRecord(good)))
        let phoneSide = phone(db)  // the transport must outlive its streams
        let questions = Collector(phoneSide.questions())
        #expect(await questions.wait { $0.last?.map(\.requestId) == [good] })
    }

    @Test func questionPushRefreshesThePhone() async throws {
        let db = FakeCloudDatabase()
        let macSide = mac(db)
        let phoneSide = phone(db)
        try await macSide.publish(session: sessionRecord())
        let questions = Collector(phoneSide.questions())
        #expect(await questions.wait { $0.last?.isEmpty == true })
        let id = UUID()
        try await macSide.publish(question: questionRecord(id))
        #expect(phoneSide.handleNotification(subscriptionID: "buddy.question.created"))
        #expect(await questions.wait { $0.last?.map(\.requestId) == [id] })
    }

    @Test func submitAnswerIsRetriedLikeAnyOtherSave() async throws {
        let db = FakeCloudDatabase()
        let phoneSide = phone(db)
        db.fail(.save, with: CKError(.networkUnavailable))
        await #expect(throws: CKError.self) { try await phoneSide.submit(answer: answerRecord(UUID())) }
        let id = UUID()
        try await phoneSide.submit(answer: answerRecord(id))
        #expect(db.recordNames(ofType: "Answer") == ["answer-\(id.uuidString)"])
    }

    @Test func stopFinishesQuestionStreamsAndEndsThePhonePoll() async throws {
        let db = FakeCloudDatabase()
        let transport = CloudKitTransport(role: .phone, database: db, phonePollInterval: .milliseconds(10))
        let stream = transport.questions()
        #expect(await eventually { db.calls(.changes) >= 3 })
        transport.stop()
        for await _ in stream {}  // returns only because the stream was finished
        try await Task.sleep(for: .milliseconds(100))
        let settled = db.calls(.changes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(db.calls(.changes) == settled)
    }
}

@Suite struct CloudKitFailureTests {
    @Test func classification() {
        #expect(CloudKitFailure.classify(CKError(.zoneNotFound)) == .zoneNotFound)
        #expect(CloudKitFailure.classify(CKError(.userDeletedZone)) == .zoneNotFound)
        #expect(CloudKitFailure.classify(CKError(.serverRejectedRequest)) == .other)
        #expect(CloudKitFailure.classify(CKError(.unknownItem)) == .unknownItem)
        #expect(CloudKitFailure.classify(CKError(.serverRecordChanged)) == .serverRecordChanged)
        #expect(CloudKitFailure.classify(CKError(.changeTokenExpired)) == .changeTokenExpired)
        for code in [CKError.Code.networkUnavailable, .networkFailure, .serverResponseLost, .requestRateLimited, .serviceUnavailable, .zoneBusy] {
            #expect(CloudKitFailure.classify(CKError(code)) == .retryable(after: nil), "\(code)")
        }
        #expect(
            CloudKitFailure.classify(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 3.5]))
                == .retryable(after: 3.5))
        #expect(CloudKitFailure.classify(CKError(.notAuthenticated)) == .other)
        #expect(CloudKitFailure.classify(CKError(.quotaExceeded)) == .other)
        #expect(CloudKitFailure.classify(CKError(.permissionFailure)) == .other)
        #expect(CloudKitFailure.classify(CancellationError()) == .other)
        #expect(CloudKitFailure.classify(URLError(.notConnectedToInternet)) == .other)
    }

    @Test func partialFailureIsClassifiedByItsFirstItemError() {
        let id = CKRecord.ID(recordName: "x", zoneID: CloudKitSchema.zoneID)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.zoneNotFound)]])
        #expect(CloudKitFailure.classify(partial) == .zoneNotFound)
    }

}
