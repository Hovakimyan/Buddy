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
        center.setNotificationCategories([
            ApprovalNotification.category(), ApprovalNotification.nowCategory(), QuestionNotification.category(),
        ])
        Task { @MainActor in
            #if DEBUG
            if !DemoCloud.isRequested { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            #else
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            #endif
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

    // Both delegate methods use the completion-handler form and call the handler on the main thread. UIKit finishes
    // the response where the handler is called, and finishing it off the main thread aborts the app
    // (`_performBlockAfterCATransactionCommitSynchronizes`): the async form, which returns on a background thread,
    // made a tapped notification open the app and close it at once.

    // A notification that arrives while the app is open still shows, with its actions.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let done = MainThreadCompletion { completionHandler([.banner, .list, .sound]) }
        Task { @MainActor in done.call() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = NotificationRoute.resolve(
            actionIdentifier: response.actionIdentifier, userInfo: response.notification.request.content.userInfo)
        let done = MainThreadCompletion(completionHandler)
        Task { @MainActor in
            defer { done.call() }
            guard let route else { return }
            switch route {
            case .deny, .allowNow, .answer:
                // Woken in the background by a notification action: hold a background-task assertion until the answer has
                // gone out (or the system says time is up), so iOS does not suspend the app mid-request. The response
                // is completed (on the main thread) only after that.
                await BackgroundTaskRunner.live.run("buddy.notification") { await PhoneController.shared.handle(route) }
            case .review, .question:
                await PhoneController.shared.handle(route)
            }
        }
    }
}

/// A UIKit completion handler carried to the main actor and called there, once.
private struct MainThreadCompletion: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @MainActor func call() { body() }
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
                    case .session(let id): SessionView(controller: controller, sessionId: id).id(id)
                    }
                }
        }
        .task {
            #if DEBUG
            if let screen = DemoCloud.requestedScreen { controller.path = [screen] }
            #endif
            await controller.start()
        }
    }
}
