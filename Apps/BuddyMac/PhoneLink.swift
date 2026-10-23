import BuddyKit
import Foundation

/// Why the phone link is or is not running; shown in the menu and Settings.
enum PhoneLinkStatus: Equatable, Sendable {
    case checking
    case on
    case off(reason: String)

    var text: String {
        switch self {
        case .checking: "Phone link: checking iCloud"
        case .on: "Phone link on"
        case .off(let reason): "Phone link off: \(reason)"
        }
    }
}

/// The result of one check: a transport, or none and why.
struct PhoneLink {
    var transport: CloudKitTransport?
    var status: PhoneLinkStatus
    /// True when the answer may change on its own (iCloud still starting after login, slow, offline, not
    /// signed in yet), so the app checks again later. False when on, or when nothing but a new build or a
    /// changed device policy could turn it on.
    var retryable = false
}

/// Decides whether the Mac gets a CloudKit transport: at launch, then again on `retryDelays` while the answer is
/// a retryable "off". Every input is injected so tests never touch the real entitlements, iCloud, or a `CKContainer`.
struct PhoneLinkSelector: Sendable {
    var hasEntitlement: @Sendable () -> Bool
    var account: @Sendable () async -> PhoneLinkAccount
    var makeTransport: @Sendable () -> CloudKitTransport
    /// How long the iCloud account check may take. A hung iCloud daemon must not keep the engine (and its
    /// hook socket) from starting: past this the phone link is simply off.
    var accountTimeout: Duration = .seconds(3)
    /// The pauses between checks after a retryable "off"; the last one repeats for as long as Buddy runs.
    var retryDelays: [Duration] = [.seconds(10), .seconds(30), .seconds(60), .seconds(120), .seconds(300)]

    /// The pause before retry number `attempt` (0-based).
    func retryDelay(attempt: Int) -> Duration {
        guard let last = retryDelays.last else { return .seconds(300) }
        return attempt < retryDelays.count ? retryDelays[attempt] : last
    }

    /// No entitlement means no CloudKit call of any kind; an unavailable account means no transport. Either
    /// way the Mac card keeps working (spec section 5).
    func select() async -> PhoneLink {
        guard hasEntitlement() else {
            return PhoneLink(
                transport: nil,
                status: .off(reason: "this build is not signed with the iCloud entitlement (see docs/cloudkit-setup.md)"))
        }
        switch await CloudAccountCheck.withinTimeout(account, timeout: accountTimeout) {
        case .available:
            return PhoneLink(transport: makeTransport(), status: .on)
        case .noAccount:
            return PhoneLink(transport: nil, status: .off(reason: "not signed in to iCloud"), retryable: true)
        case .restricted:
            return PhoneLink(transport: nil, status: .off(reason: "iCloud is restricted on this Mac"))
        case .temporarilyUnavailable:
            return PhoneLink(
                transport: nil, status: .off(reason: "iCloud is temporarily unavailable; trying again"), retryable: true)
        case .couldNotDetermine:
            return PhoneLink(
                transport: nil, status: .off(reason: "could not determine the iCloud account status; trying again"),
                retryable: true)
        case .timedOut:
            return PhoneLink(transport: nil, status: .off(reason: "iCloud check timed out; trying again"), retryable: true)
        case .failed(let message):
            return PhoneLink(
                transport: nil, status: .off(reason: "iCloud check failed (\(message)); trying again"), retryable: true)
        }
    }

    /// The real checks. `CKContainer` is created only after the entitlement check passed.
    static let live = PhoneLinkSelector(
        hasEntitlement: { CloudEntitlement.currentProcessHasCloudKit },
        account: { await CloudAccountCheck.live() },
        makeTransport: { CloudKitTransport.live(role: .mac) })
}
