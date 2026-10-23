import BuddyKit
import Foundation
import Observation
import OSLog

/// A screen on the navigation stack.
enum PhoneScreen: Hashable, Sendable {
    case approval(UUID)
    case question(UUID)
}

/// The app-level state: decides once at launch whether iCloud is usable, owns the `PhoneModel` that results, and
/// is where notification routes and pushes arrive. Kept free of UIKit types so it compiles into the test bundle;
/// the UIKit glue is in `BuddyPhoneApp.swift`.
@MainActor
@Observable
final class PhoneController {
    static let shared = PhoneController()

    private(set) var status: PhoneCloudStatus = .checking
    /// Nil until the check finished, and when iCloud is not available (then the app shows `status`).
    private(set) var model: PhoneModel?
    /// Whether this process should register for remote notifications (only with CloudKit running).
    private(set) var wantsRemoteNotifications = false
    /// The approval and question screens on the navigation stack (a notification opens one).
    var path: [PhoneScreen] = []
    /// Whether the last check failed in a way that may pass on a later try (a timeout, iCloud temporarily
    /// unavailable). `retrySelectionIfNeeded()` only acts then.
    private(set) var canRetrySelection = false

    @ObservationIgnored private let selector: PhoneCloudSelector
    @ObservationIgnored private let authenticator: any Authenticating
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let notifier: any LocalNotifying
    @ObservationIgnored private let denyTimeout: Duration
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isSelecting = false
    @ObservationIgnored private let log = Logger(subsystem: "com.sergeyhovakimyan.buddy", category: "phone")

    init(
        selector: PhoneCloudSelector = .live, authenticator: any Authenticating = LocalAuthenticator(),
        clock: @escaping @Sendable () -> Date = Date.init,
        notifier: any LocalNotifying = SystemLocalNotifier(),
        denyTimeout: Duration = .seconds(20)
    ) {
        self.selector = selector
        self.authenticator = authenticator
        self.clock = clock
        self.notifier = notifier
        self.denyTimeout = denyTimeout
    }

    /// Runs the launch check (once, however many callers) and returns when it is done.
    func start() async {
        if startTask == nil {
            isSelecting = true
            startTask = Task { await self.select() }
        }
        await startTask?.value
    }

    /// Runs the launch check again when it failed in a way that may pass later (a timeout, iCloud temporarily
    /// unavailable), for example when the app comes back to the foreground. Does nothing when connected, when the
    /// answer was final (no entitlement, no account), or while a check is already running. True when this call
    /// connected, so the caller can register for pushes.
    @discardableResult
    func retrySelectionIfNeeded() async -> Bool {
        guard model == nil, canRetrySelection, !isSelecting else { return false }
        // Before the task exists: `await task.value` lets a second caller in, and it must see a check running.
        isSelecting = true
        let task = Task { await self.select() }
        startTask = task
        await task.value
        return model != nil
    }

    private func select() async {
        defer { isSelecting = false }
        status = .checking
        let cloud = await selector.select()
        status = cloud.status
        canRetrySelection = cloud.isRetryable
        guard let connection = cloud.connection else { return }
        let clock = clock
        let model = PhoneModel(
            transport: connection.transport, authenticator: authenticator, clock: { clock() }, refresh: connection.refresh)
        model.start()
        self.model = model
        wantsRemoteNotifications = true
    }

    // MARK: Notifications

    /// A tap on the approval notification or on one of its actions.
    func handle(_ route: NotificationRoute) async {
        switch route {
        case .review(let id):
            path = [.approval(id)]  // shown at once; the screen waits for the request to load
            await start()
        case .question(let id):
            path = [.question(id)]  // likewise: the screen waits for the question to load
            await start()
        case .deny(let id):
            await start()
            guard let model else { return }
            do {
                try await model.denyFromNotification(id, timeout: denyTimeout)
            } catch {
                // Nothing was sent, so nothing was decided: the request falls back to the Mac card / terminal.
                log.error("deny from notification failed: \(error.localizedDescription, privacy: .public)")
                if Self.leavesTheRequestOpen(error) {
                    await notifier.post(
                        title: ApprovalNotification.denyFailedTitle, body: ApprovalNotification.denyFailedBody)
                }
            }
        }
    }

    /// Whether the person should be told to answer elsewhere: false when the request is already answered or expired
    /// (nothing is waiting for them), true when it may still be waiting.
    private static func leavesTheRequestOpen(_ error: Error) -> Bool {
        switch error as? PhoneError {
        case .notPending?, .expired?, .alreadyDecided?, .answeredEarlier?: false
        default: true
        }
    }

    /// A push arrived (silent or alert): fetch the cloud's changes now.
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async {
        guard ApprovalNotification.isApprovalPush(userInfo: userInfo) || QuestionNotification.isQuestionPush(userInfo: userInfo)
        else { return }
        await start()
        await model?.refresh()
    }
}
