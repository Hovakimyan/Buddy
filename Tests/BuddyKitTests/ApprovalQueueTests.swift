import Foundation
import Testing
@testable import BuddyKit

@Suite struct ApprovalQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func approval(session: String = "s1", tool: String = "Bash", ttl: TimeInterval = 60) -> PendingApproval {
        let input = JSONValue.object(["command": .string("ls")])
        return PendingApproval(
            id: UUID(),
            sessionId: session,
            toolName: tool,
            toolInput: input,
            summary: ToolSummary.make(toolName: tool, toolInput: input),
            createdAt: t0,
            expiresAt: t0 + ttl)
    }

    /// Returns once the queue holds exactly `count` pending approvals. Driven by the updates
    /// stream (which starts with the current snapshot), so there is no polling or sleeping.
    private func waitUntilPending(_ queue: ApprovalQueue, count: Int) async {
        for await snapshot in await queue.updates() where snapshot.count == count {
            return
        }
    }

    @Test func submitSuspendsUntilDecided() async {
        let queue = ApprovalQueue()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        await waitUntilPending(queue, count: 1)
        #expect(await queue.pending == [p])
        #expect(await queue.decide(requestId: p.id, .allow, source: .mac))
        #expect(await outcome.value == .decided(.allow, .mac))
        #expect(await queue.pending.isEmpty)
    }

    @Test func submitFromAnAlreadyCancelledTaskIsNeverShown() async {
        // The hook went away before its request reached the queue: nothing may wait for a human.
        let queue = ApprovalQueue()
        let p = approval()
        let (outcomes, continuation) = AsyncStream<ApprovalOutcome>.makeStream()
        Task {
            withUnsafeCurrentTask { $0?.cancel() }
            continuation.yield(await queue.submit(p))
        }
        // Bounded, so a regression (a submit that waits forever) fails instead of hanging.
        let outcome = await withTaskGroup(of: ApprovalOutcome?.self) { group in
            group.addTask {
                for await outcome in outcomes { return outcome }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(outcome == .cancelled)
        #expect(await queue.pending.isEmpty)
        #expect(await queue.decide(requestId: p.id, .allow, source: .mac) == false)
    }

    @Test func decideReturnsTrueOnceThenFalse() async {
        let queue = ApprovalQueue()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        await waitUntilPending(queue, count: 1)
        #expect(await queue.decide(requestId: p.id, .allow, source: .phone))
        #expect(await queue.decide(requestId: p.id, .deny, source: .mac) == false)
        #expect(await outcome.value == .decided(.allow, .phone))
    }

    @Test func wrongRequestIdReturnsFalse() async {
        let queue = ApprovalQueue()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        await waitUntilPending(queue, count: 1)
        #expect(await queue.decide(requestId: UUID(), .allow, source: .mac) == false)
        #expect(await queue.pending == [p])
        #expect(await queue.decide(requestId: p.id, .deny, source: .mac))
        #expect(await outcome.value == .decided(.deny, .mac))
    }

    @Test func expireDueResolvesExpired() async {
        let queue = ApprovalQueue()
        let p = approval(ttl: 60)
        let outcome = Task { await queue.submit(p) }
        await waitUntilPending(queue, count: 1)
        await queue.expireDue(now: t0 + 59)
        #expect(await queue.pending == [p])
        await queue.expireDue(now: t0 + 60)
        #expect(await outcome.value == .expired)
        #expect(await queue.pending.isEmpty)
    }

    @Test func decideAfterExpiryReturnsFalse() async {
        let queue = ApprovalQueue()
        let p = approval()
        let outcome = Task { await queue.submit(p) }
        await waitUntilPending(queue, count: 1)
        await queue.expireDue(now: t0 + 61)
        #expect(await queue.decide(requestId: p.id, .allow, source: .mac) == false)
        #expect(await outcome.value == .expired)
    }

    @Test func cancelBySessionResolvesCancelled() async {
        let queue = ApprovalQueue()
        let a1 = approval(session: "a")
        let a2 = approval(session: "a", tool: "Edit")
        let b = approval(session: "b")
        let o1 = Task { await queue.submit(a1) }
        let o2 = Task { await queue.submit(a2) }
        let ob = Task { await queue.submit(b) }
        await waitUntilPending(queue, count: 3)
        await queue.cancel(sessionId: "a")
        #expect(await o1.value == .cancelled)
        #expect(await o2.value == .cancelled)
        #expect(await queue.pending == [b])
        #expect(await queue.decide(requestId: a1.id, .allow, source: .mac) == false)
        await queue.cancel(requestId: b.id)
        #expect(await ob.value == .cancelled)
        #expect(await queue.pending.isEmpty)
    }

    @Test func twoSessionsResolveIndependently() async {
        let queue = ApprovalQueue()
        let a = approval(session: "a")
        let b = approval(session: "b")
        let oa = Task { await queue.submit(a) }
        let ob = Task { await queue.submit(b) }
        await waitUntilPending(queue, count: 2)
        #expect(await queue.decide(requestId: a.id, .allow, source: .mac))
        #expect(await oa.value == .decided(.allow, .mac))
        #expect(await queue.pending == [b])
        #expect(await queue.decide(requestId: b.id, .deny, source: .phone))
        #expect(await ob.value == .decided(.deny, .phone))
    }

    @Test func updatesStreamEmitsOnEnqueueAndResolve() async {
        let queue = ApprovalQueue()
        let p = approval()
        var stream = await queue.updates().makeAsyncIterator()
        #expect(await stream.next() == [])  // current snapshot on subscribe
        let outcome = Task { await queue.submit(p) }
        #expect(await stream.next() == [p])
        _ = await queue.decide(requestId: p.id, .allow, source: .mac)
        #expect(await stream.next() == [])
        #expect(await outcome.value == .decided(.allow, .mac))
    }
}
