import BuddyKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep on its own while Claude Code works, so a long run or a request waiting for the
/// iPhone is not cut off. It lets go `grace` after the last activity, and the Mac sleeps as usual. Only idle sleep is
/// held off: the display still sleeps, and closing the lid or choosing Sleep still sleeps the Mac.
@MainActor
final class KeepAwake {
    /// How long after the last session activity the Mac stays awake.
    static let grace: TimeInterval = 600

    /// Whether a session needs the Mac awake now: one is working, waits for a request's answer, has agents running,
    /// or did something in the last `grace` (which covers a finished turn waiting for a phone message: it waits at
    /// most as long).
    static func shouldHold(sessions: [Session], now: Date, grace: TimeInterval = KeepAwake.grace) -> Bool {
        sessions.contains { session in
            session.state == .working || session.state == .waiting || !session.agents.isEmpty
                || now.timeIntervalSince(session.updatedAt) < grace
        }
    }

    private let create: () -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var assertion: IOPMAssertionID?

    var isHolding: Bool { assertion != nil }

    init(
        create: @escaping () -> IOPMAssertionID? = KeepAwake.createAssertion,
        release: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }
    ) {
        self.create = create
        self.release = release
    }

    isolated deinit {
        if let assertion { release(assertion) }
    }

    /// Takes or lets go of the assertion; does nothing when it already is as asked.
    func update(holding: Bool) {
        if holding, assertion == nil {
            assertion = create()
        } else if !holding, let held = assertion {
            release(held)
            assertion = nil
        }
    }

    nonisolated private static func createAssertion() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Buddy: Claude Code is working" as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }
}
