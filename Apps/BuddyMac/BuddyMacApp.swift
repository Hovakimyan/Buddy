import AppKit
import BuddyKit
import SwiftUI

/// Owns the model and starts/stops the engine with the app, independent of any window being open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Socket path: `$BUDDY_SOCKET` when set, otherwise `~/Library/Application Support/Buddy/buddy.sock`.
    /// The engine is built at start, once the phone link is decided: CloudKit when this build has the iCloud
    /// entitlement and the iCloud account is available, otherwise none (Mac-only, nothing breaks). A question only waits
    /// for an answer in Buddy when the model says someone can give one (`AppModel.canAskInBuddy`).
    /// Under any `BUDDY_*` override (a safe manual run) the login item and the setup window's memory are inert, so such
    /// a run registers nothing and consumes nothing real.
    let model = AppModel(
        selector: .live,
        makeEngine: { transport, canAskInBuddy in
            BuddyEngine(
                socketPath: HookSocketServer.defaultSocketPath(), transport: transport, canAskInBuddy: canAskInBuddy)
        },
        loginItem: LaunchEnvironment.loginItem(environment: ProcessInfo.processInfo.environment),
        setupMemory: LaunchEnvironment.setupMemory(environment: ProcessInfo.processInfo.environment))

    /// What happens once at launch: the offer to move to Applications, then the setup window.
    private(set) lazy var launch = LaunchCoordinator(
        model: model, presenter: AlertMovePresenter(), relaunch: AppRelauncher.relaunchAndQuit)

    /// The notch island, alive as long as the app (it is the only owner).
    private(set) lazy var island = IslandWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        island.start()
        // After an update the hooks in Claude Code's settings still run the old copy of buddy-hook; bring it up to date.
        model.refreshInstalledHookCopy(otherInstanceRunning: OtherInstances.live.isRunning)
        // A phone link that only comes on later (iCloud was slow right after login) registers then.
        model.onPhoneLinkOn = { NSApplication.shared.registerForRemoteNotifications() }
        Task {
            await model.start()
            // Silent pushes (a phone decision arrived) only exist, and registering only works, with CloudKit.
            if model.wantsRemoteNotifications { NSApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        model.handleRemoteNotification(userInfo)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop the engine first so the socket file is removed and waiting hooks are released.
        island.stop()
        Task {
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct BuddyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model, launch: delegate.launch, island: delegate.island)
        }
        .menuBarExtraStyle(.window)

        Window("Buddy Settings", id: SettingsView.windowID) {
            SettingsView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Set up Buddy", id: SetupWindow.windowID) {
            SetupWindow(model: delegate.model, launch: delegate.launch)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
