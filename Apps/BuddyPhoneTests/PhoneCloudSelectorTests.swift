import BuddyKit
import Foundation
import Synchronization
import Testing

/// Counts what the injected closures were asked to do.
private final class Calls: Sendable {
    private let state = Mutex((account: 0, connection: 0))
    var account: Int { state.withLock { $0.account } }
    var connection: Int { state.withLock { $0.connection } }

    func selector(entitled: Bool, account: PhoneLinkAccount) -> PhoneCloudSelector {
        PhoneCloudSelector(
            hasEntitlement: { entitled },
            account: { () -> PhoneLinkAccount in
                self.state.withLock { $0.account += 1 }
                return account
            },
            makeConnection: { () -> PhoneConnection in
                self.state.withLock { $0.connection += 1 }
                return PhoneConnection(transport: InMemoryCloud().phoneSide, refresh: {})
            })
    }
}

@Suite struct PhoneCloudSelectorTests {
    @Test func noEntitlementMeansNoConnectionAndNoCloudKitCall() async {
        let calls = Calls()
        let cloud = await calls.selector(entitled: false, account: .available).select()
        #expect(cloud.connection == nil)
        guard case .off(let reason) = cloud.status else {
            Issue.record("expected off, got \(cloud.status)")
            return
        }
        #expect(reason.contains("entitlement"))
        #expect(calls.account == 0)  // the account (and so any CKContainer) is never touched
        #expect(calls.connection == 0)
    }

    @Test func availableAccountGetsAConnection() async {
        let calls = Calls()
        let cloud = await calls.selector(entitled: true, account: .available).select()
        #expect(cloud.connection != nil)
        #expect(cloud.status == .on)
        #expect(calls.connection == 1)
    }

    @Test func unavailableAccountsFallBackWithAReason() async {
        let cases: [(PhoneLinkAccount, String)] = [
            (.noAccount, "not signed in"), (.restricted, "restricted"), (.temporarilyUnavailable, "temporarily"),
            (.couldNotDetermine, "could not determine"), (.failed("offline"), "offline"),
        ]
        for (account, fragment) in cases {
            let calls = Calls()
            let cloud = await calls.selector(entitled: true, account: account).select()
            #expect(cloud.connection == nil, "\(account)")
            guard case .off(let reason) = cloud.status else { Issue.record("expected off for \(account)"); continue }
            #expect(reason.contains(fragment), "\(account): \(reason)")
            #expect(calls.connection == 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aCheckThatNeverReturnsTimesOutAndStatesWhy() async {
        let calls = Calls()
        var selector = calls.selector(entitled: true, account: .available)
        selector.account = { await withUnsafeContinuation { (_: UnsafeContinuation<PhoneLinkAccount, Never>) in } }
        selector.accountTimeout = .milliseconds(100)
        let cloud = await selector.select()
        #expect(cloud.connection == nil)
        #expect(cloud.status == .off(reason: "the iCloud check timed out; Buddy tries again when you reopen it"))
        #expect(calls.connection == 0)
        #expect(cloud.isRetryable)
    }

    // Backs the scenePhase re-check: only failures that may pass later are tried again.
    @Test func onlyTransientFailuresAreRetryable() async {
        let transient: [PhoneLinkAccount] = [.temporarilyUnavailable, .couldNotDetermine, .timedOut, .failed("offline")]
        let final: [PhoneLinkAccount] = [.noAccount, .restricted]
        for account in transient {
            let cloud = await Calls().selector(entitled: true, account: account).select()
            #expect(cloud.isRetryable, "\(account)")
        }
        for account in final {
            let cloud = await Calls().selector(entitled: true, account: account).select()
            #expect(!cloud.isRetryable, "\(account)")
        }
        #expect(await Calls().selector(entitled: true, account: .available).select().isRetryable == false)
        #expect(await Calls().selector(entitled: false, account: .available).select().isRetryable == false)
    }

    @Test func statusTextsStateWhatIsGoingOn() {
        #expect(PhoneCloudStatus.checking.text == "Checking iCloud")
        #expect(PhoneCloudStatus.on.text == "Connected to iCloud")
        #expect(PhoneCloudStatus.off(reason: "not signed in").text == "iCloud not available: not signed in")
    }

    @Test func theTestProcessHasNoCloudKitEntitlementSoTheLiveSelectorStaysOff() async {
        // The live closures read this process's real entitlements: none in the test bundle, so CloudKit is never reached.
        #expect(!CloudEntitlement.currentProcessHasCloudKit)
        let cloud = await PhoneCloudSelector.live.select()
        #expect(cloud.connection == nil)
        guard case .off(let reason) = cloud.status else {
            Issue.record("expected off")
            return
        }
        #expect(reason.contains("entitlement"))
    }
}
