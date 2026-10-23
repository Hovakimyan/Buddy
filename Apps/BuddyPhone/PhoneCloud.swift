import BuddyKit
import Foundation

/// Why the phone is or is not connected to the Mac through iCloud; shown on the session list.
enum PhoneCloudStatus: Equatable, Sendable {
    case checking
    case on
    case off(reason: String)

    var text: String {
        switch self {
        case .checking: "Checking iCloud"
        case .on: "Connected to iCloud"
        case .off(let reason): "iCloud not available: \(reason)"
        }
    }
}

/// What the model needs from the cloud: the transport, and the entry point that fetches now (a push arrived,
/// the user pulled to refresh).
struct PhoneConnection: Sendable {
    var transport: any PhoneClientTransport
    var refresh: @Sendable () async -> Void
}

/// The result of the one-time check at launch: a connection, or none and why.
struct PhoneCloud: Sendable {
    var connection: PhoneConnection?
    var status: PhoneCloudStatus
    /// True when the failure may pass on a later try (a timeout, iCloud temporarily unavailable or not
    /// answering), so the app checks again when it returns to the foreground. False for a final answer.
    var isRetryable = false
}

/// Decides, once at launch, whether the phone gets a CloudKit connection. The same rules as the Mac's
/// `PhoneLinkSelector` (entitlement first, then the account, raced against a deadline), with iPhone wording.
/// Every input is injected so tests never touch the real entitlements, iCloud, or a `CKContainer`.
struct PhoneCloudSelector: Sendable {
    var hasEntitlement: @Sendable () -> Bool
    var account: @Sendable () async -> PhoneLinkAccount
    var makeConnection: @Sendable () -> PhoneConnection
    /// A hung iCloud daemon must not keep the app from showing its screen: past this the cloud is simply off.
    var accountTimeout: Duration = .seconds(3)

    /// No entitlement means no CloudKit call of any kind (`CKContainer` would crash the process); an unavailable
    /// account means no connection. Either way the app shows why, with an empty list.
    func select() async -> PhoneCloud {
        guard hasEntitlement() else {
            return PhoneCloud(
                connection: nil,
                status: .off(reason: "this build is not signed with the iCloud entitlement (see docs/cloudkit-setup.md)"))
        }
        switch await CloudAccountCheck.withinTimeout(account, timeout: accountTimeout) {
        case .available:
            return PhoneCloud(connection: makeConnection(), status: .on)
        case .noAccount:
            return PhoneCloud(connection: nil, status: .off(reason: "not signed in to iCloud on this iPhone"))
        case .restricted:
            return PhoneCloud(connection: nil, status: .off(reason: "iCloud is restricted on this iPhone"))
        case .temporarilyUnavailable:
            return PhoneCloud(
                connection: nil, status: .off(reason: "iCloud is temporarily unavailable; Buddy tries again when you reopen it"),
                isRetryable: true)
        case .couldNotDetermine:
            return PhoneCloud(
                connection: nil, status: .off(reason: "could not determine the iCloud account status"), isRetryable: true)
        case .timedOut:
            return PhoneCloud(
                connection: nil, status: .off(reason: "the iCloud check timed out; Buddy tries again when you reopen it"),
                isRetryable: true)
        case .failed(let message):
            return PhoneCloud(
                connection: nil, status: .off(reason: "the iCloud check failed (\(message))"), isRetryable: true)
        }
    }

    /// The real checks. `CKContainer` is created only after the entitlement check passed.
    static let live = PhoneCloudSelector(
        hasEntitlement: { CloudEntitlement.currentProcessHasCloudKit },
        account: { await CloudAccountCheck.live() },
        makeConnection: {
            let transport = CloudKitTransport.live(role: .phone)
            return PhoneConnection(transport: transport, refresh: { await transport.refresh() })
        })
}
