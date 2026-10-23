import BuddyKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

// SAFETY: registry tests use throwaway UserDefaults suites, never `.standard`.

private let t0 = Date(timeIntervalSince1970: 1_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
private let origin = CGPoint(x: 100, y: 100)

@Suite struct CharacterDirectorTests {
    // MARK: Long hover

    @Test func longHoverGivesLoveAfterTheThreshold() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        #expect(d.tick(now: at(1.8)).isEmpty)
        #expect(d.tick(now: at(1.9)) == [.emote(.love)])
        #expect(d.emote?.0 == .love)
        #expect(d.emote?.1 == at(1.9))
    }

    @Test func hoverEndedResetsTheHoverTimer() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        d.hoverEnded(now: at(1.5))
        d.hoverBegan(at: origin, now: at(1.6))
        #expect(d.tick(now: at(2.0)).isEmpty)
        #expect(d.tick(now: at(3.4)).isEmpty)
        #expect(d.tick(now: at(3.5)) == [.emote(.love)])
    }

    @Test func noHoverNoLove() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        d.hoverEnded(now: at(1))
        #expect(d.tick(now: at(10)).isEmpty)
    }

    @Test func loveNeedsCooldownAndMovement() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        #expect(d.tick(now: at(1.9)) == [.emote(.love)])
        // Cooldown elapsed (7.9 s after start) but the pointer has not moved: no love.
        #expect(d.tick(now: at(8)).isEmpty)
        // Moved 39 pt: still not enough.
        d.hoverMoved(to: CGPoint(x: 139, y: 100), now: at(8.5))
        #expect(d.tick(now: at(9)).isEmpty)
        // Moved 40 pt from where love fired.
        d.hoverMoved(to: CGPoint(x: 140, y: 100), now: at(9.5))
        #expect(d.tick(now: at(10)) == [.emote(.love)])
    }

    @Test func movementAloneDoesNotBeatTheCooldown() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        #expect(d.tick(now: at(1.9)) == [.emote(.love)])
        d.hoverMoved(to: CGPoint(x: 200, y: 100), now: at(2))
        #expect(d.tick(now: at(7.8)).isEmpty)
        #expect(d.tick(now: at(7.9)) == [.emote(.love)])
    }

    @Test func cooldownAloneDoesNotFireWhileInRange() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        _ = d.tick(now: at(1.9))
        d.hoverMoved(to: CGPoint(x: 120, y: 100), now: at(3))
        #expect(d.tick(now: at(30)).isEmpty)
    }

    // MARK: Clicks and dizzy

    @Test func singleClickBoopsAndAnnoys() {
        var d = CharacterDirector()
        d.click(now: at(0))
        #expect(d.tick(now: at(0)) == [.boop, .emote(.annoyed)])
        #expect(d.boopedAt == at(0))
        #expect(d.emote?.0 == .annoyed)
        #expect(d.dizzyUntil == nil)
    }

    @Test func secondClickInsideTheWindowAlsoBoops() {
        var d = CharacterDirector()
        d.click(now: at(0))
        _ = d.tick(now: at(0))
        d.click(now: at(0.8))
        #expect(d.tick(now: at(0.8)) == [.boop, .emote(.annoyed)])
        #expect(d.dizzyUntil == nil)
    }

    @Test func threeClicksWithinTheWindowMakeItDizzy() {
        var d = CharacterDirector()
        d.click(now: at(0))
        d.click(now: at(0.6))
        _ = d.tick(now: at(0.6))
        d.click(now: at(1.7))
        #expect(d.tick(now: at(1.7)) == [.dizzyStarted])
        #expect(d.dizzyUntil == at(1.7 + 3.3))
    }

    @Test func thirdClickAfterTheWindowIsJustABoop() {
        var d = CharacterDirector()
        d.click(now: at(0))
        d.click(now: at(0.9))
        _ = d.tick(now: at(0.9))
        d.click(now: at(1.8))
        #expect(d.tick(now: at(1.8)) == [.boop, .emote(.annoyed)])
        #expect(d.dizzyUntil == nil)
    }

    @Test func dizzyEndsWithHappy() {
        var d = CharacterDirector()
        for s in [0.0, 0.3, 0.6] { d.click(now: at(s)) }
        _ = d.tick(now: at(0.6))
        #expect(d.tick(now: at(3.8)).isEmpty)
        #expect(d.dizzyUntil != nil)
        #expect(d.tick(now: at(3.9)) == [.dizzyEnded, .emote(.happy)])
        #expect(d.dizzyUntil == nil)
        #expect(d.emote?.0 == .happy)
        #expect(d.tick(now: at(4)).isEmpty)
    }

    @Test func clicksDuringDizzyAreIgnored() {
        var d = CharacterDirector()
        for s in [0.0, 0.3, 0.6] { d.click(now: at(s)) }
        _ = d.tick(now: at(0.6))
        d.click(now: at(1))
        d.click(now: at(1.2))
        #expect(d.tick(now: at(1.2)).isEmpty)
        #expect(d.dizzyUntil == at(0.6 + 3.3))
    }

    @Test func clicksBeforeDizzyDoNotCountTowardTheNextRound() {
        var d = CharacterDirector()
        for s in [0.0, 0.3, 0.6] { d.click(now: at(s)) }
        _ = d.tick(now: at(4))
        // Dizzy is over; a fresh click is a plain boop, not a second dizzy.
        d.click(now: at(4.1))
        #expect(d.tick(now: at(4.1)) == [.boop, .emote(.annoyed)])
    }

    @Test func noLoveWhileDizzy() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        for s in [0.0, 0.3, 0.6] { d.click(now: at(s)) }
        _ = d.tick(now: at(0.6))
        // Past the 1.9 s hover threshold, but dizzy until 3.9 s.
        #expect(d.tick(now: at(2.5)).isEmpty)
        #expect(d.emote?.0 != .love)
    }

    @Test func hoverTimerRestartsWhenDizzyEnds() {
        var d = CharacterDirector()
        d.hoverBegan(at: origin, now: at(0))
        for s in [0.0, 0.3, 0.6] { d.click(now: at(s)) }
        _ = d.tick(now: at(0.6))
        #expect(d.tick(now: at(3.9)) == [.dizzyEnded, .emote(.happy)])
        // Love is a full hover after the dizzy, not instant.
        #expect(d.tick(now: at(4.0)).isEmpty)
        #expect(d.tick(now: at(5.7)).isEmpty)
        #expect(d.tick(now: at(5.8)) == [.emote(.love)])
    }

    // MARK: Greeting

    @Test func greetEmitsAndLastsFourSeconds() {
        var d = CharacterDirector()
        d.greet(now: at(0))
        #expect(d.tick(now: at(0)) == [.greet])
        #expect(d.greetingStartedAt == at(0))
        #expect(d.tick(now: at(3.9)).isEmpty)
        #expect(d.greetingStartedAt == at(0))
        #expect(d.tick(now: at(4)).isEmpty)
        #expect(d.greetingStartedAt == nil)
    }

    @Test func greetOnlyAfterLongAway() {
        var short = CharacterDirector()
        short.screenAway(from: at(0), to: at(179))
        #expect(short.tick(now: at(179)).isEmpty)
        #expect(short.greetingStartedAt == nil)

        var long = CharacterDirector()
        long.screenAway(from: at(0), to: at(180))
        #expect(long.tick(now: at(180)) == [.greet])
        #expect(long.greetingStartedAt == at(180))
    }

    // MARK: Events are delivered once

    @Test func eventsAreDrainedByTick() {
        var d = CharacterDirector()
        d.click(now: at(0))
        #expect(d.tick(now: at(0)).count == 2)
        #expect(d.tick(now: at(0.1)).isEmpty)
    }
}

@MainActor
private struct TestCharacter: BuddyCharacter {
    let id: String
    var displayName: String { id }
    var soundFolder: String { id }
    func accent(for state: CharacterState) -> Color { .gray }
    func view(_ input: CharacterInput) -> AnyView { AnyView(EmptyView()) }
}

@MainActor @Suite struct CharacterRegistryTests {
    private func withTempDefaults<T>(_ body: (UserDefaults) -> T) -> T {
        let name = "buddy-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return body(defaults)
    }

    private let characters: [any BuddyCharacter] = [TestCharacter(id: "one"), TestCharacter(id: "two")]

    @Test func unsetOrUnknownIdFallsBackToTheFirst() {
        withTempDefaults { defaults in
            #expect(CharacterRegistry.current(defaults: defaults, from: characters).id == "one")
            defaults.set("missing", forKey: CharacterRegistry.defaultsKey)
            #expect(CharacterRegistry.current(defaults: defaults, from: characters).id == "one")
        }
    }

    @Test func storedIdPicksThatCharacter() {
        withTempDefaults { defaults in
            #expect(CharacterRegistry.defaultsKey == "character.id")
            defaults.set("two", forKey: "character.id")
            #expect(CharacterRegistry.current(defaults: defaults, from: characters).id == "two")
        }
    }
}
