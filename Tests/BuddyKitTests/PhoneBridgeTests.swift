import Foundation
import Synchronization
import Testing
@testable import BuddyKit

// MARK: - Helpers

private final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

/// First element of `stream` matching `predicate`, or nil after `timeout` (an upper bound only).
private func firstMatch<T: Sendable>(
    in stream: AsyncStream<T>,
    timeout: Duration = .seconds(20),
    where predicate: @escaping @Sendable (T) -> Bool
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// The outcome of a submitted approval or question, or nil after `timeout` (an upper bound only).
private func within<Outcome: Sendable>(
    _ task: Task<Outcome, Never>, timeout: Duration = .seconds(20)
) async -> Outcome? {
    let (stream, continuation) = AsyncStream<Outcome>.makeStream()
    Task {
        continuation.yield(await task.value)
        continuation.finish()
    }
    return await firstMatch(in: stream, timeout: timeout) { _ in true }
}

/// A transport double that records every attempt and fails the ones `shouldFail` selects.
private final class ScriptedTransport: PhoneTransport {
    struct State {
        var approvalAttempts: [ApprovalRecord] = []
        var attemptTimes: [ContinuousClock.Instant] = []
        /// Records the transport accepted (did not throw), in order.
        var accepted: [ApprovalRecord] = []
        var cutoffs: [Date] = []
        var decisionStreamsOpened = 0
        /// Every `publish(session:)` attempt, in order.
        var sessionAttempts: [SessionRecord] = []
        /// How many of the next session publishes still fail.
        var sessionFailuresLeft = 0
    }

    let state = Mutex(State())
    let shouldFail: @Sendable (ApprovalRecord, Int) -> Bool
    struct Attempt: Sendable {
        let record: ApprovalRecord
        /// 1-based count of all `publish(approval:)` attempts so far.
        let total: Int
    }

    /// One element per `publish(approval:)` attempt, in order.
    let attempts: AsyncStream<Attempt>
    private let attemptsContinuation: AsyncStream<Attempt>.Continuation
    /// Receives one element when the stream handed out by `decisions()` terminates.
    let decisionStreamTerminated: AsyncStream<Void>
    private let terminatedContinuation: AsyncStream<Void>.Continuation

    init(shouldFail: @escaping @Sendable (ApprovalRecord, Int) -> Bool = { _, _ in false }) {
        self.shouldFail = shouldFail
        (attempts, attemptsContinuation) = AsyncStream.makeStream()
        (decisionStreamTerminated, terminatedContinuation) = AsyncStream.makeStream()
    }

    struct Refused: Error {}

    func publish(session: SessionRecord) async throws {
        let shouldThrow = state.withLock { state -> Bool in
            state.sessionAttempts.append(session)
            guard state.sessionFailuresLeft > 0 else { return false }
            state.sessionFailuresLeft -= 1
            return true
        }
        if shouldThrow { throw Refused() }
    }
    func removeSession(id: String) async throws {}

    func publish(approval: ApprovalRecord) async throws {
        let (attemptNumber, total) = state.withLock { state -> (Int, Int) in
            state.approvalAttempts.append(approval)
            state.attemptTimes.append(.now)
            let same = state.approvalAttempts.filter { $0.requestId == approval.requestId && $0.status == approval.status }
            return (same.count, state.approvalAttempts.count)
        }
        attemptsContinuation.yield(Attempt(record: approval, total: total))
        if shouldFail(approval, attemptNumber) { throw Refused() }
        state.withLock { $0.accepted.append(approval) }
    }

    /// Waits (bounded) for an attempt matching `predicate`.
    func waitForAttempt(where predicate: @escaping @Sendable (Attempt) -> Bool) async -> Attempt? {
        await firstMatch(in: attempts, where: predicate)
    }

    func decisions() -> AsyncStream<DecisionRecord> {
        state.withLock { $0.decisionStreamsOpened += 1 }
        let (stream, continuation) = AsyncStream<DecisionRecord>.makeStream()
        let terminated = terminatedContinuation
        continuation.onTermination = { _ in terminated.yield() }
        return stream
    }

    func publish(question: QuestionRecord) async throws {}
    func answers() -> AsyncStream<AnswerRecord> { AsyncStream { _ in } }

    func deleteRecords(olderThan: Date) async throws {
        state.withLock { $0.cutoffs.append(olderThan) }
    }
}

// MARK: - Suite

@Suite struct PhoneBridgeTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func approval(
        session: String = "s1",
        ttl: TimeInterval = 60,
        truncated: Bool = false
    ) -> PendingApproval {
        PendingApproval(
            id: UUID(),
            sessionId: session,
            toolName: "Bash",
            toolInput: .object(["command": .string("ls")]),
            summary: ToolSummary(text: "ls", isTruncated: truncated),
            createdAt: t0,
            expiresAt: t0 + ttl)
    }

    private func planApproval() -> PendingApproval {
        PendingApproval(
            id: UUID(), sessionId: "s1", toolName: "ExitPlanMode",
            toolInput: .object(["plan": .string("# Plan")]),
            summary: ToolSummary(text: "# Plan", isTruncated: false),
            createdAt: t0, expiresAt: t0 + 60, kind: .plan(text: "# Plan"))
    }

    private func decision(_ id: UUID, _ d: Decision = .allow, source: DecisionSource = .phone) -> DecisionRecord {
        DecisionRecord(requestId: id, decision: d, decidedAt: t0, source: source)
    }

    /// A two-question set: one single-select ("Pick one?": A, B) and one multi-select ("Pick some?": X, Y, Z).
    static func question(session: String = "s1", ttl: TimeInterval = 120) -> PendingQuestion {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func options(_ labels: [String]) -> [AskOption] { labels.map { AskOption(label: $0, description: nil) } }
        return PendingQuestion(
            id: UUID(), sessionId: session, agentId: nil,
            questions: [
                AskQuestion(text: "Pick one?", header: "One", options: options(["A", "B"]), multiSelect: false),
                AskQuestion(text: "Pick some?", header: "Some", options: options(["X", "Y", "Z"]), multiSelect: true),
            ],
            createdAt: t0, expiresAt: t0 + ttl)
    }

    private func answer(_ id: UUID, _ responses: [[String]]) -> AnswerRecord {
        AnswerRecord(requestId: id, responses: responses, answeredAt: t0)
    }

    /// Wires a queue, an in-memory cloud and a started bridge with millisecond retry delays.
    private struct Rig {
        let queue = ApprovalQueue()
        let questionQueue = QuestionQueue()
        let cloud = InMemoryCloud()
        let clock: TestClock
        let bridge: PhoneBridge

        init(start t0: Date, retryDelays: [TimeInterval] = [0.01, 0.01, 0.01]) async {
            let clock = TestClock(t0)
            self.clock = clock
            bridge = PhoneBridge(
                queue: queue, questionQueue: questionQueue, transport: cloud.macSide, clock: { clock.now },
                retryDelays: retryDelays)
            await bridge.start()
        }

        /// Submits `p` and returns once the queue holds it.
        func submit(_ p: PendingApproval) async -> Task<ApprovalOutcome, Never> {
            let outcome = Task { await queue.submit(p) }
            let id = p.id
            _ = await firstMatch(in: await queue.updates()) { $0.contains { $0.id == id } }
            return outcome
        }

        func published(_ id: UUID, _ status: ApprovalStatus) async -> ApprovalRecord? {
            await firstMatch(in: cloud.phoneSide.approvals()) { records in
                records.contains { $0.requestId == id && $0.status == status }
            }.flatMap { $0.first { $0.requestId == id && $0.status == status } }
        }

        func send(_ record: DecisionRecord) async throws {
            try await cloud.phoneSide.submit(decision: record)
        }

        /// Submits `q` and returns once the question queue holds it.
        func submit(_ q: PendingQuestion) async -> Task<QuestionOutcome, Never> {
            let outcome = Task { await questionQueue.submit(q) }
            let id = q.id
            _ = await firstMatch(in: await questionQueue.updates()) { $0.contains { $0.id == id } }
            return outcome
        }

        func published(question id: UUID, _ status: ApprovalStatus) async -> QuestionRecord? {
            await firstMatch(in: cloud.phoneSide.questions()) { records in
                records.contains { $0.requestId == id && $0.status == status }
            }.flatMap { $0.first { $0.requestId == id && $0.status == status } }
        }

        func send(_ record: AnswerRecord) async throws {
            try await cloud.phoneSide.submit(answer: record)
        }

        /// Answers a fresh sentinel question from the phone and waits for its outcome. The bridge
        /// handles answers in order, so everything sent before this has been processed on return.
        func flushAnswers() async throws {
            let sentinel = PhoneBridgeTests.question(ttl: 10_000)
            let outcome = await submit(sentinel)
            try await send(AnswerRecord(requestId: sentinel.id, responses: [["A"], ["X"]], answeredAt: sentinel.createdAt))
            #expect(await within(outcome) == .answered(["Pick one?": "A", "Pick some?": "X"], .phone))
        }

        /// Sends a decision for a fresh sentinel approval and waits for its outcome. The bridge
        /// handles decisions in order, so everything sent before this has been processed on return.
        func flush(_ makeApproval: () -> PendingApproval) async throws {
            let sentinel = makeApproval()
            let outcome = await submit(sentinel)
            try await send(DecisionRecord(
                requestId: sentinel.id, decision: .allow, decidedAt: sentinel.createdAt, source: .phone))
            #expect(await within(outcome) == .decided(.allow, .phone))
        }
    }

    // MARK: Publishing approvals

    @Test func pendingApprovalIsPublished() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        _ = await rig.submit(p)
        let record = try #require(await rig.published(p.id, .pending))
        #expect(record == ApprovalRecord(
            requestId: p.id, sessionId: "s1", status: .pending, tool: "Bash", summary: "ls",
            isTruncated: false, createdAt: t0, expiresAt: t0 + 60))
        await rig.bridge.stop()
    }

    @Test func resolvedAndExpiredStatusesPublished() async throws {
        let rig = await Rig(start: t0)
        let decided = approval(), cancelled = approval(), expiring = approval(ttl: 60)
        let decidedOutcome = await rig.submit(decided)
        let cancelledOutcome = await rig.submit(cancelled)
        let expiringOutcome = await rig.submit(expiring)

        #expect(await rig.queue.decide(requestId: decided.id, .allow, source: .mac))
        #expect(await within(decidedOutcome) == .decided(.allow, .mac))
        await rig.queue.cancel(requestId: cancelled.id)
        #expect(await within(cancelledOutcome) == .cancelled)
        #expect(await rig.published(decided.id, .resolved) != nil)
        #expect(await rig.published(cancelled.id, .resolved) != nil)

        rig.clock.set(t0 + 61)
        await rig.queue.expireDue(now: rig.clock.now)
        #expect(await within(expiringOutcome) == .expired)
        #expect(await rig.published(expiring.id, .expired) != nil)
        await rig.bridge.stop()
    }

    // Plan cards are Mac only: the phone gets no record for them.
    @Test func planNeverPublished() async throws {
        let rig = await Rig(start: t0)
        let plan = planApproval()
        let planOutcome = await rig.submit(plan)
        let tool = approval()
        _ = await rig.submit(tool)
        #expect(await rig.published(tool.id, .pending) != nil)

        await rig.queue.cancel(requestId: plan.id)
        #expect(await within(planOutcome) == .cancelled)
        try await rig.flush { approval() }
        let records = await firstMatch(in: rig.cloud.phoneSide.approvals()) { _ in true } ?? []
        #expect(!records.contains { $0.requestId == plan.id }, "the plan reached the phone")
        await rig.bridge.stop()
    }

    // A decision the phone sends for a plan is ignored (only the Mac's three plan choices can answer it).
    @Test func phoneDecisionForPlanIgnored() async throws {
        let rig = await Rig(start: t0)
        let plan = planApproval()
        let planOutcome = await rig.submit(plan)

        try await rig.send(decision(plan.id, .allow))
        try await rig.send(decision(plan.id, .deny))
        try await rig.flush { approval() }
        #expect(await rig.queue.pending.contains(plan))

        await rig.queue.cancel(requestId: plan.id)
        #expect(await within(planOutcome) == .cancelled)
        await rig.bridge.stop()
    }

    // MARK: Applying phone decisions

    @Test func phoneDecisionResolvesQueueAsPhoneSource() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        let outcome = await rig.submit(p)
        try await rig.send(decision(p.id, .deny))
        #expect(await within(outcome) == .decided(.deny, .phone))
        #expect(await rig.published(p.id, .resolved) != nil)
        await rig.bridge.stop()
    }

    @Test func phoneDecisionIsAlwaysRecordedAsPhoneEvenIfRecordClaimsMac() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        let outcome = await rig.submit(p)
        try await rig.send(decision(p.id, .allow, source: .mac))
        #expect(await within(outcome) == .decided(.allow, .phone))
        await rig.bridge.stop()
    }

    @Test func decisionForUnknownRequestIsIgnored() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        let outcome = await rig.submit(p)
        try await rig.send(decision(UUID(), .allow))
        try await rig.flush { approval() }
        #expect(await rig.queue.pending == [p])
        #expect(await rig.queue.decide(requestId: p.id, .deny, source: .mac))
        #expect(await within(outcome) == .decided(.deny, .mac))
        await rig.bridge.stop()
    }

    @Test func garbageAndReplayedDecisionFloodDoesNotDisturbPendingApprovals() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        let outcome = await rig.submit(p)
        for _ in 0..<500 { try await rig.send(decision(UUID(), Bool.random() ? .allow : .deny, source: .mac)) }
        try await rig.flush { approval() }
        #expect(await rig.queue.pending == [p])
        try await rig.send(decision(p.id, .allow))
        #expect(await within(outcome) == .decided(.allow, .phone))
        // Replays of the same record after it resolved are all ignored.
        for _ in 0..<50 { try await rig.send(decision(p.id, .deny)) }
        try await rig.flush { approval() }
        #expect(await rig.queue.pending.isEmpty)
        await rig.bridge.stop()
    }

    @Test func decisionAfterMacAnsweredIsIgnored() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        let outcome = await rig.submit(p)
        #expect(await rig.queue.decide(requestId: p.id, .allow, source: .mac))
        try await rig.send(decision(p.id, .deny))
        try await rig.flush { approval() }
        #expect(await within(outcome) == .decided(.allow, .mac))
        await rig.bridge.stop()
    }

    @Test func duplicatePhoneDecisionIsIgnored() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        let outcome = await rig.submit(p)
        try await rig.send(decision(p.id, .allow))
        try await rig.send(decision(p.id, .deny))
        try await rig.send(decision(p.id, .allow))
        try await rig.flush { approval() }
        #expect(await within(outcome) == .decided(.allow, .phone))
        await rig.bridge.stop()
    }

    @Test func decisionAfterExpiryIsIgnored() async throws {
        let rig = await Rig(start: t0)
        let p = approval(ttl: 60)
        let outcome = await rig.submit(p)
        rig.clock.set(t0 + 61)
        await rig.queue.expireDue(now: rig.clock.now)
        try await rig.send(decision(p.id, .allow))
        try await rig.flush { approval(ttl: 10_000) }
        #expect(await within(outcome) == .expired)
        await rig.bridge.stop()
    }

    @Test func decisionPastExpiryButBeforeTimerIsIgnored() async throws {
        let rig = await Rig(start: t0)
        let p = approval(ttl: 60)
        let outcome = await rig.submit(p)
        // The clock passes expiresAt but nobody has called expireDue yet.
        rig.clock.set(t0 + 61)
        #expect(await rig.queue.pending == [p])
        try await rig.send(decision(p.id, .allow))
        try await rig.flush { approval(ttl: 10_000) }
        #expect(await within(outcome) == .expired)
        #expect(await rig.published(p.id, .expired) != nil)
        await rig.bridge.stop()
    }

    @Test func phoneAllowForTruncatedApprovalIsIgnored() async throws {
        let rig = await Rig(start: t0)
        let p = approval(truncated: true)
        let outcome = await rig.submit(p)
        let record = try #require(await rig.published(p.id, .pending))
        #expect(record.isTruncated)

        try await rig.send(decision(p.id, .allow))
        try await rig.flush { approval() }
        #expect(await rig.queue.pending == [p])

        try await rig.send(decision(p.id, .deny))
        #expect(await within(outcome) == .decided(.deny, .phone))
        await rig.bridge.stop()
    }

    // MARK: Sessions

    @Test func sessionsSyncedAndRemovedSessionsDeleted() async throws {
        let rig = await Rig(start: t0)
        let a = Session(id: "a", project: "alpha", state: .working, lastTool: "Bash", updatedAt: t0)
        let b = Session(id: "b", project: "beta", state: .idle, lastTool: nil, updatedAt: t0 + 5)
        await rig.bridge.sync(sessions: [a, b])
        let both = await firstMatch(in: rig.cloud.phoneSide.sessions()) { $0.count == 2 }
        #expect(both == [
            SessionRecord(sessionId: "a", state: .working, project: "alpha", lastTool: "Bash", updatedAt: t0),
            SessionRecord(sessionId: "b", state: .idle, project: "beta", lastTool: nil, updatedAt: t0 + 5),
        ])

        await rig.bridge.sync(sessions: [b])
        let onlyB = await firstMatch(in: rig.cloud.phoneSide.sessions()) { $0.map(\.sessionId) == ["b"] }
        #expect(onlyB != nil)
        await rig.bridge.stop()
    }

    /// Waits (bounded) until the bridge has no publish task alive.
    private func waitUntilIdle(_ bridge: PhoneBridge) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while await bridge.inFlightPublishCount > 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    @Test func activityChangesDoNotResync() async throws {
        let transport = ScriptedTransport()
        let bridge = PhoneBridge(queue: ApprovalQueue(), transport: transport, clock: { self.t0 }, retryDelays: [])
        let quiet = Session(id: "a", project: "alpha", state: .working, lastTool: "Grep", updatedAt: t0)
        let busy = Session(
            id: "a", project: "alpha", state: .working, lastTool: "Grep", updatedAt: t0,
            activity: .searching, recentTools: ["Edit", "Grep"], toolCount: 2)
        await bridge.sync(sessions: [quiet])
        await waitUntilIdle(bridge)
        await bridge.sync(sessions: [busy])
        await waitUntilIdle(bridge)
        #expect(transport.state.withLock { $0.sessionAttempts.count } == 1)

        // A change the phone can see still publishes.
        var next = busy
        next.state = .finished
        await bridge.sync(sessions: [next])
        await waitUntilIdle(bridge)
        #expect(transport.state.withLock { $0.sessionAttempts.map(\.state) } == [.working, .finished])
    }

    @Test func droppedSessionPublishIsRetriedBySyncOfTheSameRecord() async throws {
        let transport = ScriptedTransport()
        transport.state.withLock { $0.sessionFailuresLeft = 1 }
        let bridge = PhoneBridge(queue: ApprovalQueue(), transport: transport, clock: { self.t0 }, retryDelays: [])
        let a = Session(id: "a", project: "alpha", state: .working, updatedAt: t0)
        await bridge.sync(sessions: [a])
        await waitUntilIdle(bridge)
        // No retry delays: the failed publish was dropped. The same list syncs again and publishes.
        await bridge.sync(sessions: [a])
        await waitUntilIdle(bridge)
        #expect(transport.state.withLock { $0.sessionAttempts.count } == 2)
        await bridge.sync(sessions: [a])
        await waitUntilIdle(bridge)
        #expect(transport.state.withLock { $0.sessionAttempts.count } == 2)
    }

    @Test func sessionPublishCancelledByStopIsPublishedAgainAfterRestart() async throws {
        let transport = ScriptedTransport()
        transport.state.withLock { $0.sessionFailuresLeft = 1 }
        // The first attempt fails and the bridge sleeps for a long retry delay: the publish is in flight.
        let bridge = PhoneBridge(queue: ApprovalQueue(), transport: transport, clock: { self.t0 }, retryDelays: [60])
        await bridge.start()
        let a = Session(id: "a", project: "alpha", state: .working, updatedAt: t0)
        await bridge.sync(sessions: [a])
        let deadline = ContinuousClock.now + .seconds(20)
        while transport.state.withLock({ $0.sessionAttempts.count }) < 1, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(transport.state.withLock { $0.sessionAttempts.count } == 1)

        await bridge.stop()
        await bridge.start()
        await bridge.sync(sessions: [a])
        await waitUntilIdle(bridge)
        #expect(transport.state.withLock { $0.sessionAttempts.count } == 2)
        await bridge.stop()
    }

    // MARK: Failures and retries

    @Test func transportFailureDoesNotBlockQueue() async throws {
        // Production retry delays: nothing here may wait on them.
        let rig = await Rig(start: t0, retryDelays: [1, 2, 4])
        rig.cloud.failNextPublishes(3)
        let p = approval()
        let outcome = await rig.submit(p)
        #expect(await rig.queue.decide(requestId: p.id, .allow, source: .mac))
        #expect(await within(outcome) == .decided(.allow, .mac))
        #expect(await rig.queue.pending.isEmpty)
        await rig.bridge.stop()
    }

    @Test func failedPublishRetriesWithBackoff() async throws {
        let delays: [TimeInterval] = [0.05, 0.1, 0.15]
        let transport = ScriptedTransport { _, attempt in attempt <= 2 }
        let queue = ApprovalQueue()
        let bridge = PhoneBridge(queue: queue, transport: transport, clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                                 retryDelays: delays)
        await bridge.start()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        // Two failures, then the third attempt succeeds.
        #expect(await transport.waitForAttempt { $0.total == 3 } != nil)
        let times = transport.state.withLock { $0.attemptTimes }
        #expect(times.count == 3)
        #expect(times[1] - times[0] >= .seconds(delays[0]))
        #expect(times[2] - times[1] >= .seconds(delays[1]))
        await queue.cancel(requestId: p.id)
        _ = await within(outcome)
        await bridge.stop()
    }

    @Test func publishIsDroppedAfterAllRetriesAndLeavesNothingRunning() async throws {
        let transport = ScriptedTransport { record, _ in record.status == .pending }
        let queue = ApprovalQueue()
        let bridge = PhoneBridge(queue: queue, transport: transport, clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                                 retryDelays: [0.01, 0.01, 0.01])
        await bridge.start()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        // Initial attempt plus one retry per delay, then dropped.
        #expect(await transport.waitForAttempt { $0.total == 4 } != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while await bridge.inFlightPublishCount > 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await bridge.inFlightPublishCount == 0)
        #expect(transport.state.withLock { $0.approvalAttempts.count } == 4)
        // The queue was never affected.
        #expect(await queue.pending == [p])
        await queue.cancel(requestId: p.id)
        _ = await within(outcome)
        await bridge.stop()
    }

    @Test func newerRecordSupersedesRetryingOne() async throws {
        // The first pending publish fails and goes to sleep before its retry. The approval is then
        // resolved. The retry of the stale pending record must never land after the resolved one.
        let transport = ScriptedTransport { record, attempt in record.status == .pending && attempt == 1 }
        let queue = ApprovalQueue()
        let bridge = PhoneBridge(queue: queue, transport: transport, clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                                 retryDelays: [0.1, 0.1])
        await bridge.start()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        #expect(await transport.waitForAttempt { $0.record.status == .pending } != nil)
        #expect(await queue.decide(requestId: p.id, .allow, source: .mac))
        #expect(await within(outcome) == .decided(.allow, .mac))
        #expect(await transport.waitForAttempt { $0.record.status == .resolved } != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while await bridge.inFlightPublishCount > 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        // The stale retry (if it had survived) would fire 0.1 s after its failure. This wait only
        // widens the window in which a regression can show; correct code passes without it.
        try await Task.sleep(for: .milliseconds(400))
        let accepted = transport.state.withLock { $0.accepted }.filter { $0.requestId == p.id }
        #expect(accepted.last?.status == .resolved)
        if let resolvedAt = accepted.firstIndex(where: { $0.status == .resolved }) {
            #expect(!accepted[resolvedAt...].contains { $0.status == .pending })
        } else {
            Issue.record("resolved record was never accepted")
        }
        await bridge.stop()
    }

    @Test func publishStormWithFailingTransportStaysBoundedAndQueueStillResolves() async throws {
        let rig = await Rig(start: t0, retryDelays: [1, 2, 4])
        rig.cloud.failNextPublishes(10_000)
        var outcomes: [Task<ApprovalOutcome, Never>] = []
        var approvals: [PendingApproval] = []
        for _ in 0..<40 {
            let p = approval()
            approvals.append(p)
            outcomes.append(await rig.submit(p))
        }
        for p in approvals {
            #expect(await rig.queue.decide(requestId: p.id, .allow, source: .mac))
        }
        for outcome in outcomes {
            #expect(await within(outcome) == .decided(.allow, .mac))
        }
        // At most one live publish per approval, however many records were published.
        #expect(await rig.bridge.inFlightPublishCount <= 40)
        await rig.bridge.stop()
    }

    // MARK: Questions

    @Test func questionPublishedAndResolved() async throws {
        let rig = await Rig(start: t0)
        let answered = Self.question(), released = Self.question(), cancelled = Self.question()
        let expiring = Self.question(ttl: 60)
        let answeredOutcome = await rig.submit(answered)
        let releasedOutcome = await rig.submit(released)
        let cancelledOutcome = await rig.submit(cancelled)
        let expiringOutcome = await rig.submit(expiring)

        let pending = try #require(await rig.published(question: answered.id, .pending))
        #expect(pending == QuestionRecord(
            requestId: answered.id, sessionId: "s1", status: .pending, questions: answered.questions,
            createdAt: t0, expiresAt: t0 + 120))

        #expect(await rig.questionQueue.answer(requestId: answered.id, ["Pick one?": "A"], source: .mac))
        #expect(await within(answeredOutcome) == .answered(["Pick one?": "A"], .mac))
        await rig.questionQueue.release(requestId: released.id)
        #expect(await within(releasedOutcome) == .released)
        await rig.questionQueue.cancel(requestId: cancelled.id)
        #expect(await within(cancelledOutcome) == .cancelled)
        #expect(await rig.published(question: answered.id, .resolved) != nil)
        #expect(await rig.published(question: released.id, .resolved) != nil)
        #expect(await rig.published(question: cancelled.id, .resolved) != nil)

        rig.clock.set(t0 + 61)
        await rig.questionQueue.expireDue(now: rig.clock.now)
        #expect(await within(expiringOutcome) == .expired)
        #expect(await rig.published(question: expiring.id, .expired) != nil)
        await rig.bridge.stop()
    }

    @Test func questionPublishRetriesAfterFailure() async throws {
        let rig = await Rig(start: t0)
        rig.cloud.failNextPublishes(2)
        let q = Self.question()
        _ = await rig.submit(q)
        #expect(await rig.published(question: q.id, .pending) != nil)
        await rig.bridge.stop()
    }

    @Test func phoneAnswerApplied() async throws {
        let rig = await Rig(start: t0)
        let q = Self.question()
        let outcome = await rig.submit(q)
        try await rig.send(answer(q.id, [["A"], ["Z", "X"]]))
        // Option order, not tap order; the source is always the phone.
        #expect(await within(outcome) == .answered(["Pick one?": "A", "Pick some?": "X, Z"], .phone))
        #expect(await rig.published(question: q.id, .resolved) != nil)
        await rig.bridge.stop()
    }

    @Test func phoneAnswerRejected() async throws {
        let rig = await Rig(start: t0)
        let q = Self.question()
        let outcome = await rig.submit(q)

        try await rig.send(answer(UUID(), [["A"], ["X"]]))             // unknown id
        try await rig.send(answer(q.id, [["A"]]))                      // too few responses
        try await rig.send(answer(q.id, [["A"], ["X"], ["Y"]]))        // too many responses
        try await rig.send(answer(q.id, [["A"], ["Nope"]]))            // label not among the options
        try await rig.send(answer(q.id, [["A"], []]))                  // empty selection
        try await rig.send(answer(q.id, [["A", "B"], ["X"]]))          // two labels for a single-select
        try await rig.send(answer(q.id, [["A"], ["X", "X"]]))          // repeated label
        try await rig.send(answer(q.id, [["a"], ["X"]]))               // label differs in case
        try await rig.flushAnswers()
        #expect(await rig.questionQueue.pending.map(\.id) == [q.id], "an invalid answer resolved the question")

        // The first valid answer still wins, and a replay of it changes nothing.
        try await rig.send(answer(q.id, [["B"], ["Y"]]))
        #expect(await within(outcome) == .answered(["Pick one?": "B", "Pick some?": "Y"], .phone))
        try await rig.send(answer(q.id, [["A"], ["X"]]))
        try await rig.flushAnswers()
        #expect(await rig.questionQueue.pending.isEmpty)
        await rig.bridge.stop()
    }

    @Test func phoneAnswerAfterExpiryRejected() async throws {
        let rig = await Rig(start: t0)
        let q = Self.question(ttl: 60)
        let outcome = await rig.submit(q)
        // Past `expiresAt` but before any timer ran: the bridge expires it with its own clock first.
        rig.clock.set(t0 + 61)
        try await rig.send(answer(q.id, [["A"], ["X"]]))
        try await rig.flushAnswers()
        #expect(await within(outcome) == .expired)
        #expect(await rig.published(question: q.id, .expired) != nil)
        await rig.bridge.stop()
    }

    @Test func cleanupDeletesQuestionsAndAnswers() async throws {
        let cloud = InMemoryCloud()
        let clock = TestClock(t0 + 601)  // cutoff: t0 + 1
        let bridge = PhoneBridge(
            queue: ApprovalQueue(), questionQueue: QuestionQueue(), transport: cloud.macSide,
            clock: { clock.now })
        func record(_ q: PendingQuestion, created: Date) -> QuestionRecord {
            QuestionRecord(
                requestId: q.id, sessionId: "s1", status: .pending, questions: q.questions,
                createdAt: created, expiresAt: created + 120)
        }
        let old = Self.question(), fresh = Self.question()
        try await cloud.macSide.publish(question: record(old, created: t0))
        try await cloud.macSide.publish(question: record(fresh, created: t0 + 601))
        try await cloud.phoneSide.submit(answer: AnswerRecord(requestId: old.id, responses: [["A"], ["X"]], answeredAt: t0))
        try await cloud.phoneSide.submit(
            answer: AnswerRecord(requestId: fresh.id, responses: [["A"], ["X"]], answeredAt: t0 + 601))

        await bridge.cleanup()

        let remaining = await firstMatch(in: cloud.phoneSide.questions()) { $0.count == 1 }
        #expect(remaining?.first?.requestId == fresh.id)
        let answers = await firstMatch(in: cloud.macSide.answers()) { _ in true }
        #expect(answers?.requestId == fresh.id)
    }

    // MARK: Lifecycle

    @Test func stopIsIdempotentStartTwiceIsNoOpAndStopEndsDecisionConsumption() async throws {
        let transport = ScriptedTransport()
        let queue = ApprovalQueue()
        let bridge = PhoneBridge(queue: queue, transport: transport, clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                                 retryDelays: [0.01])
        await bridge.stop()  // stop before start is harmless
        await bridge.start()
        await bridge.start()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        #expect(await transport.waitForAttempt { _ in true } != nil)
        // A duplicate start would have opened a second consumer and published twice.
        await bridge.stop()
        await bridge.stop()
        #expect(await firstMatch(in: transport.decisionStreamTerminated) { _ in true } != nil)
        #expect(transport.state.withLock { $0.decisionStreamsOpened } == 1)
        #expect(transport.state.withLock { $0.approvalAttempts.filter { $0.status == .pending }.count } == 1)
        await queue.cancel(requestId: p.id)
        _ = await within(outcome)
    }

    @Test func approvalResolvedWhileStoppedGetsTerminalRecordOnRestart() async throws {
        let rig = await Rig(start: t0)
        let p = approval()
        let outcome = await rig.submit(p)
        #expect(await rig.published(p.id, .pending) != nil)
        await rig.bridge.stop()
        #expect(await rig.queue.decide(requestId: p.id, .allow, source: .mac))
        #expect(await within(outcome) == .decided(.allow, .mac))
        await rig.bridge.start()
        #expect(await rig.published(p.id, .resolved) != nil)
        await rig.bridge.stop()
    }

    // MARK: Cleanup

    @Test func cleanupDeletesOldRecords() async throws {
        // Bridge passes clock() - 10 minutes to the transport.
        let transport = ScriptedTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bridge = PhoneBridge(queue: ApprovalQueue(), transport: transport, clock: { now })
        await bridge.cleanup()
        #expect(transport.state.withLock { $0.cutoffs } == [now - 600])

        // And the in-memory cloud removes approvals and decisions older than the cutoff only.
        let rig = await Rig(start: t0)
        let old = approval(), fresh = approval()
        _ = await rig.submit(old)
        _ = await rig.published(old.id, .pending)
        rig.clock.set(t0 + 601)
        let freshRecord = ApprovalRecord(
            requestId: fresh.id, sessionId: "s1", status: .pending, tool: "Bash", summary: "ls",
            isTruncated: false, createdAt: t0 + 601, expiresAt: t0 + 661)
        try await rig.cloud.macSide.publish(approval: freshRecord)
        await rig.bridge.cleanup()
        let remaining = await firstMatch(in: rig.cloud.phoneSide.approvals()) { $0.count == 1 }
        #expect(remaining?.first?.requestId == fresh.id)
        await rig.bridge.stop()
    }
}
