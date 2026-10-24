import BuddyKit
import Foundation
import IOKit.pwr_mgt
import Testing

@MainActor
@Suite struct KeepAwakeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ state: SessionState, quietFor: TimeInterval, agents: Int = 0, awaitingMessage: Bool = false) -> Session {
        Session(
            id: UUID().uuidString, project: "p", state: state, updatedAt: now - quietFor,
            agents: (0..<agents).map { Subagent(id: "a\($0)", updatedAt: now) }, awaitingMessage: awaitingMessage)
    }

    @Test func workOrAPersonBeingWaitedOnKeepsTheMacAwakeHoweverLongItTakes() {
        #expect(KeepAwake.shouldHold(sessions: [session(.working, quietFor: 3600)], now: now))
        #expect(KeepAwake.shouldHold(sessions: [session(.waiting, quietFor: 3600)], now: now))
        #expect(KeepAwake.shouldHold(sessions: [session(.finished, quietFor: 3600, agents: 1)], now: now))
    }

    @Test func aQuietSessionLetsTheMacSleepTenMinutesAfterItsLastActivity() {
        #expect(KeepAwake.shouldHold(sessions: [session(.finished, quietFor: KeepAwake.grace - 1)], now: now))
        #expect(!KeepAwake.shouldHold(sessions: [session(.finished, quietFor: KeepAwake.grace)], now: now))
        #expect(!KeepAwake.shouldHold(sessions: [session(.idle, quietFor: 7200)], now: now))
        // A finished session that can take a typed message any time does not keep the Mac up for ever.
        #expect(!KeepAwake.shouldHold(sessions: [session(.idle, quietFor: 3600, awaitingMessage: true)], now: now))
        #expect(!KeepAwake.shouldHold(sessions: [], now: now))
    }

    @Test func theAssertionIsTakenOnceAndReleasedOnce() {
        var created = 0
        var released: [IOPMAssertionID] = []
        let keepAwake = KeepAwake(create: { created += 1; return 42 }, release: { released.append($0) })
        keepAwake.update(holding: true)
        keepAwake.update(holding: true)
        #expect(created == 1)
        #expect(keepAwake.isHolding)
        keepAwake.update(holding: false)
        keepAwake.update(holding: false)
        #expect(released == [42])
        #expect(!keepAwake.isHolding)
    }
}
