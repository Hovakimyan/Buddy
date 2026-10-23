import AppKit
import BuddyKit
import Foundation
import Synchronization
import Testing

// SAFETY: no test touches ~/.claude, ~/Library/Application Support/Buddy or the standard defaults. Sockets are in /tmp.

@Suite struct PresenceTests {
    /// The whole truth table: off means never; otherwise a locked or sleeping screen needs a live phone link.
    @Test(arguments: [false, true], [false, true])
    func truthTable(locked: Bool, asleep: Bool) {
        for live in [false, true] {
            #expect(!Presence.canAskInBuddy(enabled: false, screenLocked: locked, screenAsleep: asleep, phoneLinkLive: live))
            let expected = !(locked || asleep) || live
            #expect(
                Presence.canAskInBuddy(enabled: true, screenLocked: locked, screenAsleep: asleep, phoneLinkLive: live)
                    == expected, "locked \(locked) asleep \(asleep) live \(live)")
        }
    }

    @Test func theLockFlagIsReadFromTheSessionDictionary() {
        #expect(Presence.isLocked(sessionInfo: ["CGSSessionScreenIsLocked": true]))
        #expect(Presence.isLocked(sessionInfo: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]))
        #expect(!Presence.isLocked(sessionInfo: ["CGSSessionScreenIsLocked": false]))
        // The key is only there while locked.
        #expect(!Presence.isLocked(sessionInfo: ["kCGSSessionOnConsoleKey": true]))
        #expect(!Presence.isLocked(sessionInfo: nil))
    }

    @MainActor
    @Test func screenSleepFollowsTheWorkspaceNotifications() {
        let center = NotificationCenter()
        let screen = ScreenPresence(center: center, readLocked: { false })
        #expect(!screen.asleep)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(screen.asleep)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!screen.asleep)
    }
}

/// The closure the model hands the engine (`canAskInBuddy`), kept for the test to call.
private final class AskGate: Sendable {
    private let state = Mutex<(@Sendable () async -> Bool)?>(nil)
    func set(_ gate: @escaping @Sendable () async -> Bool) { state.withLock { $0 = gate } }
    func call() async -> Bool? {
        guard let gate = state.withLock({ $0 }) else { return nil }
        return await gate()
    }
}

private final class Flag: Sendable {
    private let state = Mutex(false)
    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

@MainActor
@Suite struct AppModelQuestionSettingTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "buddy-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func paths() -> AppModel.Paths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-pr-\(UUID().uuidString)")
        return AppModel.Paths(
            settingsURL: root.appendingPathComponent("settings.json"),
            supportDirectory: root.appendingPathComponent("support"), hookBinarySource: nil)
    }

    @Test func answeringInBuddyIsOnByDefaultAndRemembered() {
        let (store, name) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = AppModel(
            engine: BuddyEngine(socketPath: URL(fileURLWithPath: "/tmp/buddy-unused.sock"), transport: nil),
            paths: paths(), defaults: store)
        #expect(AppModel.questionsEnabledKey == "questions.enabled")
        #expect(model.questionsEnabled)
        model.questionsEnabled = false
        #expect(store.object(forKey: "questions.enabled") as? Bool == false)
        let again = AppModel(
            engine: BuddyEngine(socketPath: URL(fileURLWithPath: "/tmp/buddy-unused.sock"), transport: nil),
            paths: paths(), defaults: store)
        #expect(!again.questionsEnabled)
    }

    /// The engine the app builds asks the model, on the main actor, at every ask: the setting, the screen and the
    /// phone link. Without a phone link a locked or sleeping screen releases the question at once.
    @Test func theEngineIsGivenTheRealGate() async {
        let (store, name) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let center = NotificationCenter()
        let locked = Flag()
        let gate = AskGate()
        let socket = URL(fileURLWithPath: "/tmp/buddy-g\(UUID().uuidString.prefix(8).lowercased()).sock")
        let selector = PhoneLinkSelector(
            hasEntitlement: { false }, account: { .available },
            makeTransport: { CloudKitTransport(role: .mac, database: FakeCloudDatabase()) })
        let model = AppModel(
            selector: selector,
            makeEngine: { transport, canAskInBuddy in
                gate.set(canAskInBuddy)
                return BuddyEngine(socketPath: socket, transport: transport, canAskInBuddy: canAskInBuddy)
            },
            paths: paths(), defaults: store,
            screen: ScreenPresence(center: center, readLocked: { locked.value }))
        await model.start()
        defer { try? FileManager.default.removeItem(at: socket) }
        #expect(model.phoneLinkStatus != .on)

        #expect(await gate.call() == true)
        locked.value = true
        #expect(await gate.call() == false)
        locked.value = false
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(await gate.call() == false)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(await gate.call() == true)
        model.questionsEnabled = false
        #expect(await gate.call() == false)
        await model.stop()
    }

    /// With the phone link on, the phone can answer: a locked screen does not release the question.
    @Test func aLivePhoneLinkKeepsTheQuestionWhileTheScreenIsLocked() async {
        let (store, name) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let gate = AskGate()
        let socket = URL(fileURLWithPath: "/tmp/buddy-g\(UUID().uuidString.prefix(8).lowercased()).sock")
        let selector = PhoneLinkSelector(
            hasEntitlement: { true }, account: { .available },
            makeTransport: { CloudKitTransport(role: .mac, database: FakeCloudDatabase()) })
        let model = AppModel(
            selector: selector,
            makeEngine: { transport, canAskInBuddy in
                gate.set(canAskInBuddy)
                return BuddyEngine(socketPath: socket, transport: transport, canAskInBuddy: canAskInBuddy)
            },
            paths: paths(), defaults: store,
            screen: ScreenPresence(center: NotificationCenter(), readLocked: { true }))
        await model.start()
        defer { try? FileManager.default.removeItem(at: socket) }
        #expect(model.phoneLinkStatus == .on)
        #expect(await gate.call() == true)
        model.questionsEnabled = false
        #expect(await gate.call() == false)
        await model.stop()
    }
}
