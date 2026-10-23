import Foundation
import Synchronization
import Testing

/// A fake UIKit assertion: counts begins and ends, and lets the test fire the expiration handler.
@MainActor
final class FakeAssertion {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var names: [String] = []
    private var expire: (@MainActor @Sendable () -> Void)?

    var runner: BackgroundTaskRunner {
        BackgroundTaskRunner { name, onExpire in
            MainActor.assumeIsolated {
                self.begins += 1
                self.names.append(name)
                self.expire = onExpire
            }
            return { MainActor.assumeIsolated { self.ends += 1 } }
        }
    }

    func expireNow() { expire?() }
}

@MainActor
@Suite struct BackgroundWorkTests {
    // Checklist: a lock-screen Deny holds a background-task assertion and ends it exactly once.
    @Test func theAssertionIsBegunBeforeAndEndedOnceAfterTheWork() async {
        let assertion = FakeAssertion()
        var ranWhileHeld = false
        await assertion.runner.run("buddy.deny") { ranWhileHeld = assertion.begins == 1 && assertion.ends == 0 }
        #expect(ranWhileHeld)
        #expect(assertion.names == ["buddy.deny"])
        #expect(assertion.begins == 1)
        #expect(assertion.ends == 1)
    }

    @Test func expiryEndsTheAssertionOnceCancelsTheWorkAndTheFinishDoesNotEndItAgain() async {
        let assertion = FakeAssertion()
        var sawCancel = false
        await assertion.runner.run("buddy.deny") {
            assertion.expireNow()
            assertion.expireNow()  // the system may call it again: still one end
            sawCancel = Task.isCancelled
        }
        #expect(assertion.begins == 1)
        #expect(assertion.ends == 1)
        // The work runs in its own task; expiry cancels that task.
        #expect(sawCancel)
    }

    @Test func expiryThatArrivesBeforeBeginReturnsStillEndsOnce() async {
        let ends = Mutex(0)
        let runner = BackgroundTaskRunner { _, onExpire in
            MainActor.assumeIsolated { onExpire() }  // fires inside begin, before the end function exists
            return { ends.withLock { $0 += 1 } }
        }
        await runner.run("buddy.deny") {}
        #expect(ends.withLock { $0 } == 1)
    }

    @Test func noneRunsTheWorkWithoutAnAssertion() async {
        var ran = false
        await BackgroundTaskRunner.none.run("x") { ran = true }
        #expect(ran)
    }
}
