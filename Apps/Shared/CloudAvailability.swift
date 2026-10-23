import BuddyKit
import CloudKit
import Foundation
import Security

/// Whether the running process was signed with the iCloud/CloudKit entitlement for Buddy's container.
///
/// This must be checked BEFORE touching CloudKit: `CKContainer(identifier:)` raises an Objective-C
/// exception (an immediate crash in Swift) when the process lacks the entitlement, and that is the
/// normal state of the default ad-hoc development build (Mac and iPhone alike).
///
/// The Mac reads its own code signature (`SecTask`, public on macOS). iOS has no public API for that, so the
/// iPhone app carries the answer in its Info.plist instead: a build phase writes `BuddyCloudKit` = true only
/// when the build is code signed with an entitlements file granting CloudKit for the container (see
/// `Apps/project.yml`). On a device iOS refuses to launch an app whose iCloud entitlements no profile allows, so
/// a running app with the flag has the entitlement.
enum CloudEntitlement {
    static let containerKey = "com.apple.developer.icloud-container-identifiers"
    static let servicesKey = "com.apple.developer.icloud-services"
    /// The iPhone app's Info.plist key (a Boolean), written at build time.
    static let infoPlistKey = "BuddyCloudKit"

    /// True when `value(key)` says the process may use CloudKit with `container`.
    static func isGranted(container: String, value: (String) -> Any?) -> Bool {
        guard let containers = value(containerKey) as? [Any], containers.contains(where: { ($0 as? String) == container }),
            let services = value(servicesKey) as? [Any], services.contains(where: { ($0 as? String) == "CloudKit" })
        else { return false }
        return true
    }

    /// True only when `info` (an Info.plist) has `infoPlistKey` set to the Boolean true.
    static func isFlagged(info: [String: Any]?) -> Bool {
        (info?[infoPlistKey] as? Bool) == true
    }

    #if os(macOS)
        /// The current process's entitlement value, read from its code signature.
        static func currentProcessValue(_ key: String) -> Any? {
            guard let task = SecTaskCreateFromSelf(nil) else { return nil }
            return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        }

        static var currentProcessHasCloudKit: Bool {
            isGranted(container: CloudKitSchema.containerIdentifier, value: currentProcessValue)
        }
    #else
        static var currentProcessHasCloudKit: Bool {
            isFlagged(info: Bundle.main.infoDictionary)
        }
    #endif
}

/// The iCloud account state, reduced to what the user can act on.
enum PhoneLinkAccount: Equatable, Sendable {
    case available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine
    /// The check did not answer in time (never returned by CloudKit itself).
    case timedOut
    case failed(String)
}

enum CloudAccountCheck {
    /// The real account check. Call only after `CloudEntitlement.currentProcessHasCloudKit` said yes:
    /// `CKContainer` is created here.
    static func live() async -> PhoneLinkAccount {
        do {
            switch try await CKContainer(identifier: CloudKitSchema.containerIdentifier).accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Races `account` against `timeout`. Unstructured on purpose: a task group would wait for the check to
    /// finish even after the deadline, and CloudKit calls may ignore cancellation. A hung iCloud daemon must not
    /// keep the app from starting: past the deadline the answer is `.timedOut`.
    static func withinTimeout(
        _ account: @escaping @Sendable () async -> PhoneLinkAccount, timeout: Duration
    ) async -> PhoneLinkAccount {
        let (results, continuation) = AsyncStream<PhoneLinkAccount>.makeStream()
        let check = Task { continuation.yield(await account()) }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.yield(.timedOut)
        }
        var iterator = results.makeAsyncIterator()
        let first = await iterator.next() ?? .timedOut
        check.cancel()
        timer.cancel()
        continuation.finish()
        return first
    }
}
