import Foundation

/// Runs work inside a background-task assertion (UIKit's `beginBackgroundTask`), so a Deny tapped on the lock
/// screen can finish its network round trip before iOS suspends the app again. Kept free of UIKit so the "ended
/// exactly once" rule is unit-tested; the real `begin` is in `BuddyPhoneApp.swift`.
struct BackgroundTaskRunner: Sendable {
    /// What ends the assertion. Calling it more than once is the caller's bug (`run` never does).
    typealias End = @MainActor @Sendable () -> Void

    /// Starts an assertion called `name`. `onExpire` is called if the system is about to suspend the app before the
    /// work is done. Returns the function that ends the assertion.
    var begin: @MainActor @Sendable (_ name: String, _ onExpire: @escaping @MainActor @Sendable () -> Void) -> End

    /// No assertion (tests, and anywhere a background task is not needed).
    static let none = BackgroundTaskRunner { _, _ in {} }

    /// Runs `work` and ends the assertion exactly once: when the work finishes, or when the system expires it
    /// (whichever is first), after which the work is cancelled. Returns when the work has finished.
    @MainActor
    func run(_ name: String, _ work: @escaping @MainActor () async -> Void) async {
        let ending = EndOnce()
        let task = Task { @MainActor in await work() }
        ending.arm(begin(name) {
            task.cancel()
            ending.fire()
        })
        await task.value
        ending.fire()
    }
}

/// Ends something at most once, even when the request to end arrives before it has been armed (an expiration
/// handler can fire before `begin` has returned).
@MainActor
private final class EndOnce {
    private var end: BackgroundTaskRunner.End?
    private var requested = false
    private var done = false

    func arm(_ end: @escaping BackgroundTaskRunner.End) {
        self.end = end
        if requested { finish() }
    }

    func fire() {
        requested = true
        finish()
    }

    private func finish() {
        guard !done, let end else { return }
        done = true
        end()
    }
}
