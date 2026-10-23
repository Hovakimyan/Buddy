import SwiftUI
import UIKit
import UserNotifications

/// The UIKit glue, kept thin: it registers the notification category, asks for permission, registers for remote
/// notifications, and hands pushes and notification responses to `PhoneController` (whose routing is tested).
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([ApprovalNotification.category(), QuestionNotification.category()])
        Task { @MainActor in
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await PhoneController.shared.start()
            // Pushes (and registering for them) only work, and are only wanted, with CloudKit running.
            if PhoneController.shared.wantsRemoteNotifications { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await PhoneController.shared.handleRemoteNotification(userInfo: userInfo)
        return .newData
    }

    // A notification that arrives while the app is open still shows, with its actions.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.actionIdentifier
        let route = NotificationRoute.resolve(
            actionIdentifier: identifier, userInfo: response.notification.request.content.userInfo)
        guard let route else { return }
        switch route {
        case .deny:
            // Woken in the background by a lock-screen tap: hold a background-task assertion until the Deny has
            // gone out (or the system says time is up), so iOS does not suspend the app mid-request. The async
            // delegate method has no completion handler: the system completes the response when it returns.
            await BackgroundTaskRunner.live.run("buddy.deny") { await PhoneController.shared.handle(route) }
        case .review, .question:
            await PhoneController.shared.handle(route)
        }
    }
}

extension BackgroundTaskRunner {
    /// UIKit's background-task assertion. The expiration handler runs on the main thread.
    static let live = BackgroundTaskRunner { name, onExpire in
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { onExpire() }
        }
        return { if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) } }
    }
}

@main
struct BuddyPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    private let controller = PhoneController.shared

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                // A timed-out or temporarily unavailable iCloud check is tried again; connecting needs the push
                // registration the launch path would have done.
                if await controller.retrySelectionIfNeeded() { UIApplication.shared.registerForRemoteNotifications() }
                await controller.model?.refresh()
            }
        }
    }
}

struct RootView: View {
    @Bindable var controller: PhoneController

    var body: some View {
        NavigationStack(path: $controller.path) {
            SessionListView(controller: controller)
                // `.id` gives every request its own screen state (arming delay, failure text, "gave up" timer).
                .navigationDestination(for: PhoneScreen.self) { screen in
                    switch screen {
                    case .approval(let id): ApprovalView(controller: controller, requestId: id).id(id)
                    case .question(let id): QuestionView(controller: controller, requestId: id).id(id)
                    }
                }
        }
        .task { await controller.start() }
    }
}
