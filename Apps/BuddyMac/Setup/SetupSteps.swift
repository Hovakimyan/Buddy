import BuddyKit
import Foundation

/// The steps of the setup window, in the order it shows them.
enum SetupStepID: Equatable, Sendable {
    case applications, connect, openSessions, check, iPhone, openAtLogin

    /// The steps Buddy cannot work well without. The iPhone and the login item are extras: they never put a dot on
    /// the menu or reopen the window.
    var isRequired: Bool {
        switch self {
        case .applications, .connect, .openSessions, .check: true
        case .iPhone, .openAtLogin: false
        }
    }
}

/// One step as the window shows it. `body` may hold Markdown inline code (backticks), rendered as such.
struct SetupStep: Equatable, Identifiable, Sendable {
    let id: SetupStepID
    let done: Bool
    let title: String
    let body: String
}

/// What a new person does after installing Buddy, and which of it is done. Pure: every input is passed in.
enum SetupSteps {
    /// The menu item that opens the window.
    static let menuTitle = "Setup steps\u{2026}"

    /// The steps, in order. The iPhone step is listed only in builds with CloudKit (`cloudEnabled`), and is never done:
    /// Buddy cannot see the phone app. Outdated hooks are not done, whatever else happened.
    static func make(
        inApplications: Bool, hookStatus: HookInstallStatus, sawEventProject: String?, cloudEnabled: Bool,
        openAtLogin: Bool
    ) -> [SetupStep] {
        let sawEvent = sawEventProject != nil
        var steps = [
            SetupStep(
                id: .applications, done: inApplications, title: "Move Buddy to Applications",
                body: "Buddy belongs in Applications, where it stays put when you empty Downloads or eject the disk image."),
            SetupStep(
                id: .connect, done: hookStatus == .current,
                title: hookStatus == .outdated
                    ? "Update Buddy's hooks so you can answer Claude's questions from the notch"
                    : "Connect Buddy to Claude Code",
                body: "Buddy adds small hooks to `~/.claude/settings.json` so Claude Code can tell Buddy what it is doing. A backup is made first."),
            SetupStep(
                id: .openSessions, done: sawEvent, title: "Open sessions pick it up",
                body: "Claude sessions that are already open pick up Buddy within a few seconds. If one doesn't show up in step 4, quit it (`/exit`) and run `claude --continue` to pick up where you were."),
            SetupStep(
                id: .check, done: sawEvent, title: "Check it works",
                body: sawEventProject.map { "Buddy sees your session in \($0)." } ?? "Type anything in a Claude session."),
        ]
        if cloudEnabled {
            steps.append(SetupStep(
                id: .iPhone, done: false, title: "Optional: iPhone",
                body: "Install Buddy on your iPhone from TestFlight, signed in to the same Apple Account, and allow notifications."))
        }
        steps.append(SetupStep(id: .openAtLogin, done: openAtLogin, title: "Open at login", body: ""))
        return steps
    }

    /// True while a required step is not done: the menu item shows a dot.
    static func needsAttention(
        inApplications: Bool, hookStatus: HookInstallStatus, sawEventProject: String?, cloudEnabled: Bool,
        openAtLogin: Bool
    ) -> Bool {
        needsAttention(make(
            inApplications: inApplications, hookStatus: hookStatus, sawEventProject: sawEventProject,
            cloudEnabled: cloudEnabled, openAtLogin: openAtLogin))
    }

    static func needsAttention(_ steps: [SetupStep]) -> Bool {
        steps.contains { $0.id.isRequired && !$0.done }
    }
}

/// What the setup window remembers across launches: that it has been shown once, and the project of the first hook
/// event Buddy saw (so "Check it works" stays done after a relaunch).
@MainActor
protocol SetupMemory: AnyObject {
    var windowShown: Bool { get set }
    var seenEventProject: String? { get set }
}

/// The real memory, in `UserDefaults`.
@MainActor
final class DefaultsSetupMemory: SetupMemory {
    static let windowShownKey = "setup.windowShown"
    static let seenEventProjectKey = "setup.seenEventProject"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var windowShown: Bool {
        get { defaults.bool(forKey: Self.windowShownKey) }
        set { defaults.set(newValue, forKey: Self.windowShownKey) }
    }

    var seenEventProject: String? {
        get { defaults.string(forKey: Self.seenEventProjectKey) }
        set { defaults.set(newValue, forKey: Self.seenEventProjectKey) }
    }
}

/// A memory that lives only in this process: for test runs and for runs under `BUDDY_*` overrides, which must not
/// touch the real preferences.
@MainActor
final class VolatileSetupMemory: SetupMemory {
    var windowShown = false
    var seenEventProject: String?
}
