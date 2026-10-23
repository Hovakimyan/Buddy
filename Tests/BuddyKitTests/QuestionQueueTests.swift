import Foundation
import Testing
@testable import BuddyKit

@Suite struct QuestionQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func question(session: String = "s1", agent: String? = nil, ttl: TimeInterval = 120) -> PendingQuestion {
        PendingQuestion(
            id: UUID(),
            sessionId: session,
            agentId: agent,
            questions: [AskQuestion(
                text: "Which one?", header: "Pick",
                options: [AskOption(label: "A", description: nil), AskOption(label: "B", description: nil)],
                multiSelect: false)],
            createdAt: t0,
            expiresAt: t0 + ttl)
    }

    /// Returns once the queue holds exactly `count` pending questions (driven by `updates()`).
    private func waitUntilPending(_ queue: QuestionQueue, count: Int) async {
        for await snapshot in await queue.updates() where snapshot.count == count {
            return
        }
    }

    @Test func answerResolvesOnceThenFalse() async {
        let queue = QuestionQueue()
        let q = question()
        let outcome = Task { await queue.submit(q) }
        await waitUntilPending(queue, count: 1)
        #expect(await queue.pending == [q])
        #expect(await queue.answer(requestId: q.id, ["Which one?": "A"], source: .mac))
        #expect(await queue.answer(requestId: q.id, ["Which one?": "B"], source: .phone) == false)
        #expect(await outcome.value == .answered(["Which one?": "A"], .mac))
        #expect(await queue.pending.isEmpty)
        // Nothing else can resolve it again either.
        await queue.release(requestId: q.id)
        await queue.cancel(requestId: q.id)
        #expect(await queue.answer(requestId: UUID(), [:], source: .mac) == false)
    }

    @Test func resubmittingAPendingIdIsCancelled() async {
        let queue = QuestionQueue()
        let q = question()
        let original = Task { await queue.submit(q) }
        await waitUntilPending(queue, count: 1)
        #expect(await queue.submit(q) == .cancelled)
        #expect(await queue.pending == [q])
        await queue.release(requestId: q.id)
        #expect(await original.value == .released)
    }

    @Test func expiryResolvesOnlyDueQuestions() async {
        let queue = QuestionQueue()
        let short = question(ttl: 10), long = question(ttl: 120)
        let shortOutcome = Task { await queue.submit(short) }
        let longOutcome = Task { await queue.submit(long) }
        await waitUntilPending(queue, count: 2)

        await queue.expireDue(now: t0 + 9)
        #expect(await queue.pending.count == 2)
        await queue.expireDue(now: t0 + 10)
        #expect(await shortOutcome.value == .expired)
        #expect(await queue.pending == [long])
        #expect(await queue.answer(requestId: short.id, ["Which one?": "A"], source: .mac) == false)

        await queue.expireDue(now: t0 + 120)
        #expect(await longOutcome.value == .expired)
        #expect(await queue.pending.isEmpty)
    }

    @Test func releaseResolvesAsReleased() async {
        let queue = QuestionQueue()
        let q = question()
        let outcome = Task { await queue.submit(q) }
        await waitUntilPending(queue, count: 1)
        await queue.release(requestId: q.id)
        #expect(await outcome.value == .released)
        #expect(await queue.answer(requestId: q.id, ["Which one?": "A"], source: .mac) == false)
    }

    @Test func cancelBySessionAndByAsker() async {
        let queue = QuestionQueue()
        let main = question(session: "s1")
        let sub = question(session: "s1", agent: "agent-1")
        let otherSub = question(session: "s1", agent: "agent-2")
        let other = question(session: "s2")
        // One at a time, so they enter the queue in this order (unstructured tasks started together need not).
        var outcomes: [Task<QuestionOutcome, Never>] = []
        for (i, q) in [main, sub, otherSub, other].enumerated() {
            outcomes.append(Task { await queue.submit(q) })
            await waitUntilPending(queue, count: i + 1)
        }

        // One asker only: the subagent's question goes, its parallel sibling and the main one stay.
        await queue.cancel(sessionId: "s1", agentId: "agent-1")
        #expect(await outcomes[1].value == .cancelled)
        #expect(await queue.pending == [main, otherSub, other])

        // The main conversation (nil agent) is an asker of its own.
        await queue.cancel(sessionId: "s1", agentId: nil)
        #expect(await outcomes[0].value == .cancelled)
        #expect(await queue.pending == [otherSub, other])

        // The whole session, every asker; the other session is untouched.
        await queue.cancel(sessionId: "s1")
        #expect(await outcomes[2].value == .cancelled)
        #expect(await queue.pending == [other])

        await queue.cancel(requestId: other.id)
        #expect(await outcomes[3].value == .cancelled)
        #expect(await queue.pending.isEmpty)
    }

    @Test func submitFromAnAlreadyCancelledTaskIsNeverShown() async {
        let queue = QuestionQueue()
        let q = question()
        let outcome = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.submit(q)
        }
        #expect(await outcome.value == .cancelled)
        #expect(await queue.pending.isEmpty)
        #expect(await queue.answer(requestId: q.id, ["Which one?": "A"], source: .mac) == false)
    }
}
