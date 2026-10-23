import BuddyKit
import Foundation
import Testing

// SAFETY: UserDefaults here are throwaway suites, never `.standard`; every settings path, support directory and socket
// is in a temp location. Nothing here may touch ~/.claude or ~/Library/Application Support/Buddy.

/// A throwaway defaults domain, removed afterwards.
@MainActor
private func withTempDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
    let name = "buddy-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    return try await body(defaults)
}

/// Short on purpose: `sockaddr_un` paths are limited to 104 bytes.
private func tempSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/buddy-s\(String(UUID().uuidString.prefix(8)).lowercased()).sock")
}

/// Polls until `condition` holds (an upper bound only); returns whether it did.
@MainActor
private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Runs the blocking `HookClient` (the fake `buddy-hook`) off the cooperative pool.
private func sendEvent(_ name: String, session: String = "s1", cwd: String?, socket: URL) async -> String? {
    var members: [String: JSONValue] = ["session_id": .string(session), "hook_event_name": .string(name)]
    if let cwd { members["cwd"] = .string(cwd) }
    let json = String(decoding: try! JSONEncoder().encode(JSONValue.object(members)), as: UTF8.self)
    return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: HookClient.run(
                input: Data(json.utf8), socketPath: socket, connectTimeout: 5, waitTimeout: 5))
        }
    }
}

/// Buddy entries from an older version: no question group, so an install would change them.
private let outdatedSettings = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/bin/buddy-hook'"}]}]}}"#

/// Exactly what this version installs.
private func currentSettings() throws -> String {
    let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: "'/x/bin/buddy-hook'")
    return String(decoding: plan.newData, as: UTF8.self)
}

/// A model whose settings, support directory, socket and defaults are temp ones (never the real ones), remembering
/// setup progress in `memory`. Its embedded `buddy-hook` is a stub script, so installs work.
@MainActor
private final class Harness {
    let root: URL
    let settingsURL: URL
    let socket = tempSocketURL()
    let memory: any SetupMemory
    let model: AppModel
    private let suiteName = "buddy-test-\(UUID().uuidString)"

    init(settings: String?, memory: any SetupMemory = VolatileSetupMemory()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-setup-\(UUID().uuidString)", isDirectory: true)
        settingsURL = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let settings { try Data(settings.utf8).write(to: settingsURL) }
        let hookSource = root.appendingPathComponent("embedded-buddy-hook")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: hookSource)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookSource.path)
        self.memory = memory
        let paths = AppModel.Paths(
            settingsURL: settingsURL, supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            hookBinarySource: hookSource)
        model = AppModel(
            engine: BuddyEngine(socketPath: socket, transport: nil), paths: paths, setupMemory: memory,
            defaults: UserDefaults(suiteName: suiteName)!)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: socket)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}

private let allIDs: [SetupStepID] = [.applications, .connect, .openSessions, .check, .iPhone, .openAtLogin]

@Suite struct SetupStepsTests {
    private func steps(
        inApplications: Bool = true, hookStatus: HookInstallStatus = .current, sawEventProject: String? = nil,
        cloudEnabled: Bool = true, openAtLogin: Bool = false
    ) -> [SetupStep] {
        SetupSteps.make(
            inApplications: inApplications, hookStatus: hookStatus, sawEventProject: sawEventProject,
            cloudEnabled: cloudEnabled, openAtLogin: openAtLogin)
    }

    private func step(_ id: SetupStepID, in list: [SetupStep]) throws -> SetupStep {
        try #require(list.first { $0.id == id })
    }

    @Test func aFreshInstallListsEveryStepInOrderAndNoneIsDone() {
        let list = steps(inApplications: false, hookStatus: .notInstalled)
        #expect(list.map(\.id) == allIDs)
        #expect(list.map(\.done) == [false, false, false, false, false, false])
    }

    @Test func eachStepIsDoneByItsOwnInput() {
        let list = steps(inApplications: true, hookStatus: .current, sawEventProject: "my-app", openAtLogin: true)
        #expect(list.map(\.id) == allIDs)
        // The iPhone step is never marked done: Buddy cannot see the phone app; it stays optional.
        #expect(list.map(\.done) == [true, true, true, true, false, true])
    }

    @Test func theIPhoneStepIsAbsentWithoutCloudKit() {
        let list = steps(cloudEnabled: false)
        #expect(list.map(\.id) == [.applications, .connect, .openSessions, .check, .openAtLogin])
    }

    @Test func outdatedHooksAreNotDoneAndAskForTheUpdate() throws {
        let connect = try step(.connect, in: steps(hookStatus: .outdated, sawEventProject: "my-app"))
        #expect(!connect.done)
        #expect(connect.title == "Update Buddy's hooks so you can answer Claude's questions from the notch")
        #expect(connect.body == "Buddy adds small hooks to `~/.claude/settings.json` so Claude Code can tell Buddy what it is doing. A backup is made first.")
        #expect(try step(.connect, in: steps(hookStatus: .notInstalled)).title == "Connect Buddy to Claude Code")
        #expect(try step(.connect, in: steps(hookStatus: .current)).done)
    }

    @Test func openSessionsAndTheCheckAreDoneOnceAnEventWasSeen() throws {
        let before = steps(sawEventProject: nil)
        #expect(try !step(.openSessions, in: before).done)
        #expect(try !step(.check, in: before).done)
        #expect(try step(.check, in: before).body == "Type anything in a Claude session.")
        let after = steps(sawEventProject: "my-app")
        #expect(try step(.openSessions, in: after).done)
        #expect(try step(.check, in: after).done)
        #expect(try step(.check, in: after).body == "Buddy sees your session in my-app.")
    }

    @Test func theTitlesAndBodiesAreTheSpecsWords() throws {
        let list = steps(inApplications: false, hookStatus: .notInstalled)
        #expect(list.map(\.title) == [
            "Move Buddy to Applications", "Connect Buddy to Claude Code", "Open sessions pick it up", "Check it works",
            "Optional: iPhone", "Open at login",
        ])
        #expect(try step(.connect, in: list).body
            == "Buddy adds small hooks to `~/.claude/settings.json` so Claude Code can tell Buddy what it is doing. A backup is made first.")
        #expect(try step(.openSessions, in: list).body
            == "Claude sessions that are already open pick up Buddy within a few seconds. If one doesn't show up in step 4, quit it (`/exit`) and run `claude --continue` to pick up where you were.")
        #expect(try step(.check, in: list).body == "Type anything in a Claude session.")
        #expect(try step(.iPhone, in: list).body
            == "Install Buddy on your iPhone from TestFlight, signed in to the same Apple Account, and allow notifications.")
        #expect(try !step(.applications, in: list).body.isEmpty)
    }

    @Test func onlyTheFourRequiredStepsNeedAttention() {
        func attention(
            inApplications: Bool = true, hookStatus: HookInstallStatus = .current, project: String? = "my-app"
        ) -> Bool {
            SetupSteps.needsAttention(
                inApplications: inApplications, hookStatus: hookStatus, sawEventProject: project, cloudEnabled: true,
                openAtLogin: false)
        }
        // All four required steps done: the iPhone step and the login toggle (both off) do not count.
        #expect(!attention())
        #expect(attention(inApplications: false))
        #expect(attention(hookStatus: .notInstalled))
        #expect(attention(hookStatus: .outdated))
        #expect(attention(project: nil))
    }

    /// The bodies keep the spec's backticks; the window shows those parts as inline code.
    @Test func backtickedWordsRenderAsInlineCode() {
        let rendered = SetupWindow.rendered("Run `claude --continue` now.")
        #expect(String(rendered.characters) == "Run claude --continue now.")
        let code = rendered.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map { String(rendered[$0.range].characters) }
        #expect(code == ["claude --continue"])
    }

    /// House style: the ellipsis character, like "Install hooks…".
    @Test func theMenuItemIsCalledSetupSteps() {
        #expect(SetupSteps.menuTitle == "Setup steps\u{2026}")
    }

    /// The project is a folder name, not Markdown: the sentence that names it shows as plain text.
    @Test func theProjectNameIsNeverReadAsMarkdown() throws {
        let check = try step(.check, in: steps(sawEventProject: "_scratch_ `x` [a](b)"))
        let shown = SetupWindow.displayed(check)
        #expect(String(shown.characters) == "Buddy sees your session in _scratch_ `x` [a](b).")
        #expect(shown.runs.allSatisfy { $0.inlinePresentationIntent == nil && $0.link == nil })
        // The other bodies keep their inline code.
        let connect = SetupWindow.displayed(try step(.connect, in: steps()))
        #expect(connect.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }
}

@MainActor
@Suite struct AppModelSetupTests {
    @Test func theFirstLaunchOpensTheWindowAndInstallsNothing() throws {
        let h = try Harness(settings: #"{"theme":"dark"}"#)
        defer { h.cleanUp() }
        let before = try Data(contentsOf: h.settingsURL)
        #expect(h.model.shouldOpenSetupAtLaunch())
        // Deciding to show it changed nothing on disk.
        #expect(try Data(contentsOf: h.settingsURL) == before)
        let entries = try FileManager.default.contentsOfDirectory(atPath: h.settingsURL.deletingLastPathComponent().path)
        #expect(entries == ["settings.json"])
        #expect(h.model.hookStatus == .notInstalled)
        #expect(h.model.setupNeedsAttention)
    }

    @Test func theShownMarkIsSetOnlyWhenTheWindowAppears() throws {
        let memory = VolatileSetupMemory()
        let h = try Harness(settings: currentSettings(), memory: memory)
        defer { h.cleanUp() }
        #expect(h.model.shouldOpenSetupAtLaunch())
        #expect(!memory.windowShown)  // decided, not yet on screen: a failed open must not use it up
        h.model.setupWindowDidAppear()
        #expect(memory.windowShown)
        #expect(!h.model.shouldOpenSetupAtLaunch())
    }

    @Test func outdatedHooksOpenTheWindowOnEveryLaunch() throws {
        let memory = VolatileSetupMemory()
        memory.windowShown = true
        memory.seenEventProject = "my-app"
        let h = try Harness(settings: outdatedSettings, memory: memory)
        defer { h.cleanUp() }
        #expect(h.model.hookStatus == .outdated)
        #expect(h.model.shouldOpenSetupAtLaunch())
        // Seen events do not make up for it: the connect step is not done.
        let connect = try #require(h.model.setupSteps.first { $0.id == .connect })
        #expect(!connect.done)
        #expect(h.model.setupNeedsAttention)
    }

    @Test func theHookStatusFollowsTheSettingsFile() throws {
        let h = try Harness(settings: nil)
        defer { h.cleanUp() }
        #expect(h.model.hookStatus == .notInstalled)
        try Data(outdatedSettings.utf8).write(to: h.settingsURL)
        h.model.refreshHooksInstalled()
        #expect(h.model.hookStatus == .outdated)
        try Data(currentSettings().utf8).write(to: h.settingsURL)
        h.model.refreshHooksInstalled()
        #expect(h.model.hookStatus == .current)
    }

    @Test func aShownWindowWithCurrentHooksStaysClosed() throws {
        let memory = VolatileSetupMemory()
        memory.windowShown = true
        let h = try Harness(settings: currentSettings(), memory: memory)
        defer { h.cleanUp() }
        #expect(!h.model.shouldOpenSetupAtLaunch())
    }

    /// The first hook event names the project; the next launch (same defaults) still knows it.
    @Test func theSeenProjectSurvivesARelaunch() async throws {
        try await withTempDefaults { defaults in
            let h = try Harness(settings: currentSettings(), memory: DefaultsSetupMemory(defaults: defaults))
            defer { h.cleanUp() }
            #expect(h.model.seenEventProject == nil)
            await h.model.start()
            _ = await sendEvent("UserPromptSubmit", cwd: "/Users/tester/code/my-app", socket: h.socket)
            #expect(await waitUntil { h.model.seenEventProject == "my-app" })
            let check = try #require(h.model.setupSteps.first { $0.id == .check })
            #expect(check.done)
            #expect(check.body == "Buddy sees your session in my-app.")
            await h.model.stop()

            let again = try Harness(settings: currentSettings(), memory: DefaultsSetupMemory(defaults: defaults))
            defer { again.cleanUp() }
            #expect(again.model.seenEventProject == "my-app")
            #expect(again.model.setupSteps.first { $0.id == .check }?.done == true)
            #expect(again.model.setupSteps.first { $0.id == .openSessions }?.done == true)
        }
    }

    /// A session first seen without a working directory is named "unknown": that is no project to show, so Buddy
    /// waits for an event that names one.
    @Test func aSessionWithoutAProjectDoesNotCompleteTheCheck() async throws {
        let h = try Harness(settings: currentSettings())
        defer { h.cleanUp() }
        await h.model.start()
        _ = await sendEvent("UserPromptSubmit", cwd: nil, socket: h.socket)
        #expect(await waitUntil { h.model.sessions.count == 1 })
        #expect(h.model.seenEventProject == nil)
        #expect(h.memory.seenEventProject == nil)
        _ = await sendEvent("UserPromptSubmit", cwd: "/Users/tester/code/my-app", socket: h.socket)
        #expect(await waitUntil { h.model.seenEventProject == "my-app" })
        await h.model.stop()
    }

    /// Updating outdated hooks starts steps 3 and 4 over: only an event after the update proves the new hooks work.
    /// Sessions seen before the update do not count again.
    @Test func updatingOutdatedHooksChecksAgain() async throws {
        let h = try Harness(settings: outdatedSettings)
        defer { h.cleanUp() }
        await h.model.start()
        _ = await sendEvent("UserPromptSubmit", session: "s1", cwd: "/Users/tester/code/old-a", socket: h.socket)
        #expect(await waitUntil { h.model.seenEventProject == "old-a" })
        _ = await sendEvent("UserPromptSubmit", session: "s2", cwd: "/Users/tester/code/old-b", socket: h.socket)
        #expect(await waitUntil { h.model.sessions.count == 2 })
        #expect(h.model.hookStatus == .outdated)

        try h.model.applyInstall(h.model.planInstall())
        #expect(h.model.hookStatus == .current)
        #expect(h.model.seenEventProject == nil)
        #expect(h.memory.seenEventProject == nil)
        #expect(h.model.setupSteps.first { $0.id == .openSessions }?.done == false)

        // A snapshot that still lists the old session (s2 ended) does not bring the check back.
        _ = await sendEvent("SessionEnd", session: "s2", cwd: nil, socket: h.socket)
        #expect(await waitUntil { h.model.sessions.count == 1 })
        #expect(h.model.seenEventProject == nil)

        _ = await sendEvent("UserPromptSubmit", session: "s1", cwd: "/Users/tester/code/new-c", socket: h.socket)
        #expect(await waitUntil { h.model.seenEventProject == "new-c" })
        #expect(h.memory.seenEventProject == "new-c")
        await h.model.stop()
    }

    /// Installing after an uninstall starts steps 3 and 4 over too: the event seen before proves nothing about the hooks
    /// installed now.
    @Test func reinstallingAfterAnUninstallChecksAgain() async throws {
        let h = try Harness(settings: currentSettings())
        defer { h.cleanUp() }
        await h.model.start()
        _ = await sendEvent("UserPromptSubmit", session: "s1", cwd: "/Users/tester/code/old-a", socket: h.socket)
        #expect(await waitUntil { h.model.seenEventProject == "old-a" })

        try h.model.applyUninstall(h.model.planUninstall())
        #expect(h.model.hookStatus == .notInstalled)
        try h.model.applyInstall(h.model.planInstall())
        #expect(h.model.hookStatus == .current)
        #expect(h.model.seenEventProject == nil)
        #expect(h.memory.seenEventProject == nil)
        #expect(h.model.setupSteps.first { $0.id == .check }?.done == false)

        _ = await sendEvent("UserPromptSubmit", session: "s1", cwd: "/Users/tester/code/new-b", socket: h.socket)
        #expect(await waitUntil { h.model.seenEventProject == "new-b" })
        await h.model.stop()
    }

    /// Confirming with current hooks (it only refreshes the binary) keeps a check that is done.
    @Test func reinstallingCurrentHooksKeepsTheCheck() throws {
        let memory = VolatileSetupMemory()
        memory.seenEventProject = "my-app"
        let h = try Harness(settings: currentSettings(), memory: memory)
        defer { h.cleanUp() }
        #expect(h.model.hookStatus == .current)
        try h.model.applyInstall(h.model.planInstall())
        #expect(h.model.hookStatus == .current)
        try h.model.applyInstall(h.model.planInstall())
        #expect(h.model.seenEventProject == "my-app")
        #expect(memory.seenEventProject == "my-app")
    }

    @Test func theDemoIsNotAHookEvent() throws {
        let h = try Harness(settings: currentSettings())
        defer { h.cleanUp() }
        h.model.startDemo(DemoFeed(wait: { _ in try? await Task.sleep(for: .seconds(3600)) }))
        #expect(h.model.isDemoRunning)
        #expect(h.model.seenEventProject == nil)
        h.model.stopDemo()
    }

    @Test func theDefaultsMemoryRoundTripsInItsOwnSuite() async {
        await withTempDefaults { defaults in
            let memory = DefaultsSetupMemory(defaults: defaults)
            #expect(!memory.windowShown)
            #expect(memory.seenEventProject == nil)
            memory.windowShown = true
            memory.seenEventProject = "my-app"
            let reread = DefaultsSetupMemory(defaults: defaults)
            #expect(reread.windowShown)
            #expect(reread.seenEventProject == "my-app")
        }
    }

    @Test func overridesGetInertStoresThatNeverTouchTheRealOnes() async {
        await withTempDefaults { defaults in
            for key in ["BUDDY_SOCKET", "BUDDY_SETTINGS", "BUDDY_HOME", "BUDDY_ANYTHING"] {
                let environment = [key: "/tmp/x"]
                #expect(LaunchEnvironment.isOverridden(environment))
                #expect(LaunchEnvironment.loginItem(environment: environment) is NoLoginItem)
                let memory = LaunchEnvironment.setupMemory(environment: environment, defaults: defaults)
                #expect(memory is VolatileSetupMemory)
                memory.windowShown = true
                memory.seenEventProject = "my-app"
                #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("setup.") }.isEmpty)
            }
            #expect(!LaunchEnvironment.isOverridden(["HOME": "/x", "BUDDYISH": "1"]))
            #expect(LaunchEnvironment.setupMemory(environment: [:], defaults: defaults) is DefaultsSetupMemory)
        }
    }
}
