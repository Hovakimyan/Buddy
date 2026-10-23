import Foundation
import Observation
import ServiceManagement

/// What macOS says about Buddy as a login item (`SMAppService.Status`, minus the framework type so tests need none).
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    /// Registered, but the person still has to allow it in System Settings > General > Login Items.
    case requiresApproval
    case notRegistered
    /// macOS cannot find this app as a login item (for example when it runs from an unusual location).
    case notFound

    /// What the toggle shows: on while registered, including while waiting for approval.
    var isOn: Bool { self == .enabled || self == .requiresApproval }

    var text: String {
        switch self {
        case .enabled: "Buddy opens when you log in."
        case .notRegistered: "Buddy does not open when you log in."
        case .requiresApproval: "Waiting for your approval: allow Buddy in System Settings > General > Login Items."
        case .notFound: "macOS cannot find Buddy as a login item. Move it to Applications and open it from there."
        }
    }
}

/// The login-item service, behind a protocol so tests use a fake and never register anything.
@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// The real thing: this app as a main-app login item. Only the running app ever builds this.
struct SystemLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }

    /// Opens System Settings at Login Items, where a pending approval is given.
    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Used where no real login item may be touched (the model's test initializer): it reports nothing registered
/// and refuses to register.
struct NoLoginItem: LoginItemService {
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? { "Launch at login is not available here." }
    }

    var status: LoginItemStatus { .notFound }
    func register() throws { throw Unavailable() }
    func unregister() throws { throw Unavailable() }
}

/// The "Launch at login" setting: the real status after every change (never an assumption) and the error text
/// of a change that failed.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: LoginItemStatus
    /// Why the last change failed. Cleared by the next successful change or refresh.
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LoginItemService

    init(service: any LoginItemService) {
        self.service = service
        self.status = service.status
    }

    var isOn: Bool { status.isOn }

    /// Re-reads the status, for when the person may have changed it in System Settings.
    func refresh() {
        status = service.status
    }

    /// Registers or unregisters, then shows the status macOS reports. A registration that is already
    /// in place (or already gone) is not repeated.
    func set(_ enabled: Bool) {
        errorMessage = nil
        if enabled != service.status.isOn {
            do {
                if enabled { try service.register() } else { try service.unregister() }
            } catch {
                errorMessage = "Could not \(enabled ? "turn on" : "turn off") launch at login: \(error.localizedDescription)"
            }
        }
        status = service.status
    }
}
