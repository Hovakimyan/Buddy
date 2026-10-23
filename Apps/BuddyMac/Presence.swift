import AppKit
import CoreGraphics

/// Whether a question may wait for an answer in Buddy. While the `--ask` hook waits, Claude Code shows no prompt in the
/// terminal, so the engine asks this when a question arrives and lets the terminal ask at once when the answer is no.
enum Presence {
    /// The key `CGSessionCopyCurrentDictionary()` holds (true) while the screen is locked; absent otherwise.
    static let screenLockedKey = "CGSSessionScreenIsLocked"

    /// False when the person turned answering in Buddy off, or when nobody can see the card: the screen is locked or
    /// asleep and the phone link is not live. Otherwise true.
    static func canAskInBuddy(enabled: Bool, screenLocked: Bool, screenAsleep: Bool, phoneLinkLive: Bool) -> Bool {
        guard enabled else { return false }
        return !(screenLocked || screenAsleep) || phoneLinkLive
    }

    /// Whether a login session dictionary says the screen is locked.
    static func isLocked(sessionInfo: [String: Any]?) -> Bool {
        (sessionInfo?[screenLockedKey] as? Bool) ?? false
    }

    /// Whether this login session's screen is locked right now.
    static func screenIsLocked() -> Bool {
        isLocked(sessionInfo: CGSessionCopyCurrentDictionary() as? [String: Any])
    }
}

/// The screen's state as far as `Presence` needs it: asleep from the workspace's screen sleep and wake notifications
/// (awake until told otherwise), locked read when asked.
@MainActor
final class ScreenPresence {
    private(set) var asleep = false
    private let readLocked: () -> Bool
    private let center: NotificationCenter
    // Unsafe only so `deinit` can remove them; everything else touches them on the main actor.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        readLocked: @escaping () -> Bool = Presence.screenIsLocked
    ) {
        self.center = center
        self.readLocked = readLocked
        observers = [
            observe(NSWorkspace.screensDidSleepNotification, asleep: true),
            observe(NSWorkspace.screensDidWakeNotification, asleep: false),
        ]
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    var locked: Bool { readLocked() }

    private func observe(_ name: Notification.Name, asleep: Bool) -> any NSObjectProtocol {
        // Posted on the main thread (the workspace's centre always is; tests post there too).
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = asleep }
        }
    }
}
