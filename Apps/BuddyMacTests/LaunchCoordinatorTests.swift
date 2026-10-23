import BuddyKit
import Foundation
import Testing

// SAFETY: the presenter, the copy and the relaunch are fakes (no alert, no file copied into the real
// /Applications, nothing quit), the setup memory is in memory and the settings are in a temp directory.

@MainActor
private final class FakePresenter: MovePresenting {
    var answer = true
    private(set) var confirmed: [MoveToApplications.Offer] = []
    private(set) var failures: [String] = []

    func confirmMove(_ offer: MoveToApplications.Offer) -> Bool {
        confirmed.append(offer)
        return answer
    }

    func showMoveFailure(_ message: String) { failures.append(message) }
}

@MainActor
private final class FakeRunningApp: RunningApp {
    var hasExited = false
    /// Whether asking it to quit makes it exit (an older Buddy that quits properly) or not (one that hangs).
    let quitsWhenAsked: Bool
    private(set) var quitRequests = 0
    private let onQuit: () -> Void

    init(quitsWhenAsked: Bool, onQuit: @escaping () -> Void) {
        self.quitsWhenAsked = quitsWhenAsked
        self.onQuit = onQuit
    }

    func requestQuit() {
        quitRequests += 1
        onQuit()
        if quitsWhenAsked { hasExited = true }
    }
}

private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
private final class Harness {
    let root: URL
    let model: AppModel
    let presenter = FakePresenter()
    /// In memory: the tests never touch real preferences.
    let memory = VolatileSetupMemory()
    var copies: [(URL, URL)] = []
    var relaunches: [URL] = []
    var copyError: Error?
    var relaunchError: Error?
    var setupOpened = 0
    /// What happened, in order: "quit", "copy", "relaunch".
    var events: [String] = []
    var others: [FakeRunningApp] = []
    /// A private defaults domain for the model (never `.standard`), removed in `cleanUp`.
    private let suiteName = "buddy-test-\(UUID().uuidString)"

    init(settings: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-launch-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let settings { try Data(settings.utf8).write(to: settingsURL) }
        let paths = AppModel.Paths(
            settingsURL: settingsURL, supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            hookBinarySource: nil)
        model = AppModel(
            engine: BuddyEngine(socketPath: root.appendingPathComponent("never.sock"), transport: nil), paths: paths,
            setupMemory: memory, defaults: UserDefaults(suiteName: suiteName)!)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func coordinator(
        bundle: String = "/Users/tester/Downloads/BuddyMac.app", environment: [String: String] = [:],
        underTests: Bool = false
    ) -> LaunchCoordinator {
        LaunchCoordinator(
            model: model, presenter: presenter,
            relaunch: { [self] url in
                if let relaunchError { throw relaunchError }
                events.append("relaunch")
                relaunches.append(url)
            },
            others: OtherInstances(find: { [self] in others }), quitTimeout: .milliseconds(150),
            copy: { [self] from, to in
                if let copyError { throw copyError }
                events.append("copy")
                copies.append((from, to))
            },
            bundleURL: URL(fileURLWithPath: bundle, isDirectory: true), environment: environment,
            home: URL(fileURLWithPath: "/Users/tester", isDirectory: true), isUnderTests: underTests,
            originalLocation: { _ in nil }, exists: { _ in false })
    }

    /// An older Buddy that is running. `quits` says whether it exits when asked.
    func addRunningBuddy(quits: Bool) {
        others.append(FakeRunningApp(quitsWhenAsked: quits, onQuit: { [self] in events.append("quit") }))
    }

    func run(_ coordinator: LaunchCoordinator) async {
        await coordinator.run { setupOpened += 1 }
    }
}

@MainActor
@Suite struct LaunchCoordinatorTests {
    @Test func acceptingCopiesRelaunchesAndSkipsTheSetupWindow() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.run(h.coordinator())
        #expect(h.presenter.confirmed.count == 1)
        #expect(h.copies.count == 1)
        #expect(h.copies.first?.0.path == "/Users/tester/Downloads/BuddyMac.app")
        #expect(h.copies.first?.1.path == "/Applications/BuddyMac.app")
        #expect(h.relaunches.map(\.path) == ["/Applications/BuddyMac.app"])
        #expect(h.presenter.failures.isEmpty)
        // This instance is going away: the copy shows the setup window, so the flag stays unused.
        #expect(h.setupOpened == 0)
        #expect(!h.memory.windowShown)
    }

    @Test func decliningKeepsRunningAndMovesNothing() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.presenter.answer = false
        await h.run(h.coordinator())
        #expect(h.presenter.confirmed.count == 1)
        #expect(h.copies.isEmpty)
        #expect(h.relaunches.isEmpty)
        #expect(h.presenter.failures.isEmpty)
        // It carries on as a normal first launch, with the move still to do.
        #expect(h.setupOpened == 1)
        #expect(!h.model.inApplications)
    }

    @Test func aFailedCopyShowsAnErrorAndKeepsRunning() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.copyError = Boom()
        await h.run(h.coordinator())
        #expect(h.relaunches.isEmpty)
        #expect(h.presenter.failures.count == 1)
        #expect(h.presenter.failures[0].contains("boom"))
        #expect(h.presenter.failures[0].contains("keeps running"))
        #expect(h.setupOpened == 1)
    }

    @Test func aFailedRelaunchShowsAnErrorAndKeepsRunning() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.relaunchError = Boom()
        await h.run(h.coordinator())
        #expect(h.copies.count == 1)
        #expect(h.presenter.failures.count == 1)
        #expect(h.presenter.failures[0].contains("Open it from Applications"))
        #expect(h.setupOpened == 1)
    }

    @Test func offersOncePerLaunch() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.presenter.answer = false
        let coordinator = h.coordinator()
        await h.run(coordinator)
        await h.run(coordinator)
        #expect(h.presenter.confirmed.count == 1)
        #expect(h.setupOpened == 1)
    }

    @Test(arguments: ["BUDDY_SOCKET", "BUDDY_SETTINGS", "BUDDY_HOME", "BUDDY_SNAPSHOT_DIR"])
    func anOverrideNeverAsksOrMoves(key: String) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.run(h.coordinator(environment: [key: "/tmp/x"]))
        #expect(h.presenter.confirmed.isEmpty)
        #expect(h.copies.isEmpty)
        #expect(h.relaunches.isEmpty)
    }

    @Test func underTestsNeverAsksOrMoves() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.run(h.coordinator(underTests: true))
        #expect(h.presenter.confirmed.isEmpty)
        #expect(h.copies.isEmpty)
    }

    @Test func fromApplicationsThereIsNoOfferAndTheSetupWindowStillShows() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.run(h.coordinator(bundle: "/Applications/BuddyMac.app"))
        #expect(h.presenter.confirmed.isEmpty)
        #expect(h.setupOpened == 1)
        #expect(h.model.inApplications)
    }

    /// A first launch opens the window even with the hooks already there (it shows them done).
    @Test func theFirstLaunchOpensTheSetupWindowWhateverTheHooks() async throws {
        let h = try Harness(settings: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/bin/buddy-hook'"}]}]}}"#)
        defer { h.cleanUp() }
        await h.run(h.coordinator(bundle: "/Applications/BuddyMac.app"))
        #expect(h.setupOpened == 1)
    }

    @Test func theSetupWindowShowsOnceAcrossLaunchesWhileTheHooksAreCurrent() async throws {
        let current = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: "'/x/bin/buddy-hook'").newData
        let h = try Harness(settings: String(decoding: current, as: UTF8.self))
        defer { h.cleanUp() }
        await h.run(h.coordinator(bundle: "/Applications/BuddyMac.app"))
        #expect(!h.memory.windowShown)  // not yet: the window has not appeared
        h.model.setupWindowDidAppear()  // what the window does when it shows
        #expect(h.memory.windowShown)
        await h.run(h.coordinator(bundle: "/Applications/BuddyMac.app"))  // a second launch, same memory
        #expect(h.setupOpened == 1)
    }

    @Test func outdatedHooksReopenTheSetupWindowOnALaterLaunch() async throws {
        let h = try Harness(settings: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/bin/buddy-hook'"}]}]}}"#)
        defer { h.cleanUp() }
        h.memory.windowShown = true
        await h.run(h.coordinator(bundle: "/Applications/BuddyMac.app"))
        #expect(h.setupOpened == 1)
    }

    /// The setup window's "Move to Applications" asks again with the same alert and does the same move.
    @Test func theMoveCanBeOfferedAgainFromTheSetupWindow() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.presenter.answer = false
        let coordinator = h.coordinator()
        await h.run(coordinator)
        #expect(h.copies.isEmpty)
        h.presenter.answer = true
        await coordinator.moveToApplications()
        #expect(h.presenter.confirmed.count == 2)
        #expect(h.events == ["copy", "relaunch"])
    }

    /// The window was on screen, then moved the app: the copy in Applications must open it again, so the person is
    /// not left halfway through setup with nothing on screen.
    @Test func aMoveFromTheSetupWindowReopensItInTheCopy() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.presenter.answer = false
        let coordinator = h.coordinator()
        await h.run(coordinator)
        h.model.setupWindowDidAppear()
        #expect(h.memory.windowShown)
        h.presenter.answer = true
        await coordinator.moveToApplications()
        #expect(h.relaunches.map(\.path) == ["/Applications/BuddyMac.app"])
        #expect(!h.memory.windowShown)
        #expect(h.model.shouldOpenSetupAtLaunch())  // what the copy decides at its launch (same defaults domain)
    }

    /// Declined, or a failed relaunch: this instance keeps running with its window, so nothing changes.
    @Test func aMoveFromTheSetupWindowThatDoesNotHappenKeepsTheMark() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.presenter.answer = false
        let coordinator = h.coordinator()
        await h.run(coordinator)
        h.model.setupWindowDidAppear()
        await coordinator.moveToApplications()
        #expect(h.memory.windowShown)
        h.presenter.answer = true
        h.relaunchError = Boom()
        await coordinator.moveToApplications()
        #expect(h.memory.windowShown)
    }

    @Test func aRunningOlderBuddyIsQuitAndGoneBeforeAnythingIsCopied() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.addRunningBuddy(quits: true)
        await h.run(h.coordinator())
        #expect(h.presenter.confirmed.first?.otherInstanceRunning == true)
        #expect(h.others.first?.quitRequests == 1)
        #expect(h.events == ["quit", "copy", "relaunch"])
        #expect(h.presenter.failures.isEmpty)
    }

    @Test func anOlderBuddyThatDoesNotQuitAbortsTheMoveAndChangesNothing() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.addRunningBuddy(quits: false)
        await h.run(h.coordinator())
        #expect(h.others.first?.quitRequests == 1)
        #expect(h.events == ["quit"])  // asked, but nothing copied and nothing relaunched
        #expect(h.copies.isEmpty)
        #expect(h.relaunches.isEmpty)
        #expect(h.presenter.failures.count == 1)
        #expect(h.presenter.failures[0].contains("did not quit"))
        #expect(h.presenter.failures[0].contains("keeps running"))
    }

    @Test func decliningNeverAsksTheOlderBuddyToQuit() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.addRunningBuddy(quits: true)
        h.presenter.answer = false
        await h.run(h.coordinator())
        #expect(h.others.first?.quitRequests == 0)
        #expect(h.events.isEmpty)
    }

    @Test func withNoOtherBuddyNobodyIsAskedToQuit() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.run(h.coordinator())
        #expect(h.presenter.confirmed.first?.otherInstanceRunning == false)
        #expect(h.events == ["copy", "relaunch"])
    }
}

@MainActor
@Suite struct OtherInstancesTests {
    @Test func quitAndWaitReturnsTrueOnceEveryoneExited() async {
        let a = FakeRunningApp(quitsWhenAsked: true, onQuit: {})
        let b = FakeRunningApp(quitsWhenAsked: true, onQuit: {})
        let others = OtherInstances(find: { [a, b] })
        #expect(others.isRunning)
        #expect(await others.quitAndWait(timeout: .seconds(1), poll: .milliseconds(5)))
        #expect(a.quitRequests == 1 && b.quitRequests == 1)
        #expect(!others.isRunning)
    }

    @Test func quitAndWaitIsFalseWhenOneStaysAlive() async {
        let gone = FakeRunningApp(quitsWhenAsked: true, onQuit: {})
        let stuck = FakeRunningApp(quitsWhenAsked: false, onQuit: {})
        let others = OtherInstances(find: { [gone, stuck] })
        #expect(await others.quitAndWait(timeout: .milliseconds(60), poll: .milliseconds(5)) == false)
        #expect(others.isRunning)
    }

    @Test func nothingRunningMeansNothingToWaitFor() async {
        let others = OtherInstances(find: { [] })
        #expect(!others.isRunning)
        #expect(await others.quitAndWait(timeout: .seconds(1)))
    }

    @Test func anAppThatAlreadyExitedIsNotAskedAgain() async {
        let exited = FakeRunningApp(quitsWhenAsked: true, onQuit: {})
        exited.hasExited = true
        let others = OtherInstances(find: { [exited] })
        #expect(!others.isRunning)
        #expect(await others.quitAndWait(timeout: .seconds(1)))
        #expect(exited.quitRequests == 0)
    }
}
