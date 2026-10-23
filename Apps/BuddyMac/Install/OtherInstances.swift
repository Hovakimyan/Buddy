import AppKit
import Foundation

/// One running copy of Buddy other than this process.
@MainActor
protocol RunningApp: AnyObject {
    /// True once the process has exited.
    var hasExited: Bool { get }
    /// Asks it to quit the normal way (it stops its engine and removes its socket first).
    func requestQuit()
}

/// Other running instances of this app (same bundle id). An older Buddy that is still running when a newer one
/// is opened is the normal update situation: it holds the hook socket and may be using the installed hook copy, and a
/// bundle must never be replaced under a running process.
@MainActor
struct OtherInstances {
    let find: () -> [any RunningApp]

    var isRunning: Bool { find().contains { !$0.hasExited } }

    /// Asks every other instance to quit and waits up to `timeout` for all of them to exit. False when one did not:
    /// the caller must then leave everything as it is.
    func quitAndWait(timeout: Duration, poll: Duration = .milliseconds(100)) async -> Bool {
        let apps = find().filter { !$0.hasExited }
        guard !apps.isEmpty else { return true }
        for app in apps { app.requestQuit() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if apps.allSatisfy({ $0.hasExited }) { return true }
            try? await Task.sleep(for: poll)
        }
        return apps.allSatisfy { $0.hasExited }
    }

    /// The real lookup through `NSRunningApplication`, excluding this process.
    static var live: OtherInstances {
        OtherInstances {
            guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
            let me = ProcessInfo.processInfo.processIdentifier
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me }
                .map { LiveRunningApp(app: $0) }
        }
    }
}

@MainActor
private final class LiveRunningApp: RunningApp {
    private let app: NSRunningApplication

    init(app: NSRunningApplication) { self.app = app }

    var hasExited: Bool { app.isTerminated }
    func requestQuit() { _ = app.terminate() }
}
