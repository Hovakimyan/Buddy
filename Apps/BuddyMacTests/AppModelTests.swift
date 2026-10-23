import BuddyKit
import Foundation
import Testing

// SAFETY: every test uses temp directories for settings, support dir and socket. Nothing here may touch
// ~/.claude or ~/Library/Application Support/Buddy.

// MARK: - Helpers

private func shortToken() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

/// Short on purpose: `sockaddr_un` paths are limited to 104 bytes.
private func tempSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/buddy-m\(shortToken()).sock")
}

private func eventJSON(
    _ name: String, session: String = "s1", cwd: String? = nil, tool: String? = nil, command: String? = nil
) -> String {
    var members: [String: JSONValue] = [
        "session_id": .string(session),
        "hook_event_name": .string(name),
    ]
    if let cwd { members["cwd"] = .string(cwd) }
    if let tool { members["tool_name"] = .string(tool) }
    if let command { members["tool_input"] = .object(["command": .string(command)]) }
    let data = try! JSONEncoder().encode(JSONValue.object(members))
    return String(decoding: data, as: UTF8.self)
}

/// Runs the blocking `HookClient` (the fake `buddy-hook`) off the cooperative pool.
private func runClient(_ json: String, socket: URL, waitTimeout: TimeInterval = 25) async -> String? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: HookClient.run(
                input: Data(json.utf8), socketPath: socket, connectTimeout: 5, waitTimeout: waitTimeout))
        }
    }
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

private struct Fixture {
    let root: URL
    let settings: URL
    let support: URL
    let hookSource: URL
    let socket: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = root.appendingPathComponent("claude/settings.json")
        // With a space, like the real ~/Library/Application Support/Buddy, so command quoting is exercised.
        support = root.appendingPathComponent("Application Support/Buddy", isDirectory: true)
        hookSource = root.appendingPathComponent("embedded-buddy-hook")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: hookSource)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookSource.path)
        socket = tempSocketURL()
    }

    var paths: AppModel.Paths {
        AppModel.Paths(settingsURL: settings, supportDirectory: support, hookBinarySource: hookSource)
    }

    var hookCommandPath: String { support.appendingPathComponent("bin/buddy-hook").path }

    func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: settings)
    }

    func settingsData() -> Data? { try? Data(contentsOf: settings) }

    func settingsDirectoryEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: settings.deletingLastPathComponent().path)) ?? []).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: socket)
    }
}

// MARK: - Suite

@MainActor
@Suite struct AppModelTests {
    private func makeModel(_ fixture: Fixture, socket: URL? = nil) -> AppModel {
        let engine = BuddyEngine(socketPath: socket ?? fixture.socket, transport: nil)
        return AppModel(engine: engine, paths: fixture.paths)
    }

    // MARK: Engine bridge

    @Test func snapshotUpdatesSessionsAndPending() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()
        #expect(model.errorMessage == nil)
        #expect(model.sessions.isEmpty)
        #expect(model.pending.isEmpty)

        _ = await runClient(eventJSON("SessionStart", cwd: "/Users/me/code/buddy"), socket: fixture.socket)
        #expect(await waitUntil { model.sessions.first?.project == "buddy" })
        #expect(model.sessions.first?.state == .idle)

        let client = Task { await runClient(
            eventJSON("PermissionRequest", tool: "Bash", command: "ls"), socket: fixture.socket) }
        #expect(await waitUntil { model.pending.count == 1 })
        #expect(model.pending.first?.toolName == "Bash")
        #expect(model.pending.first?.sessionId == "s1")

        let id = try #require(model.pending.first?.id)
        #expect(await model.decide(id, .allow))
        #expect(await client.value == HookOutput.stdout(for: .decision(.allow), event: HookEvent(sessionId: "s", name: .permissionRequest)))
        #expect(await waitUntil { model.pending.isEmpty })
        await model.stop()
    }

    @Test func decideForwardsToEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()

        let client = Task { await runClient(
            eventJSON("PermissionRequest", tool: "Bash", command: "rm -rf /tmp/x"), socket: fixture.socket) }
        #expect(await waitUntil { model.pending.count == 1 })
        let id = try #require(model.pending.first?.id)

        let applied = await model.decide(id, .deny)

        #expect(applied)
        #expect(await client.value == HookOutput.stdout(for: .decision(.deny), event: HookEvent(sessionId: "s", name: .permissionRequest)))
        // A second decision for the same request is a no-op.
        #expect(await model.decide(id, .allow) == false)
        await model.stop()
    }

    @Test func truncatedCommandCannotBeAllowedFromTheMacButCanBeDenied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()

        let long = "echo start; " + String(repeating: "x", count: 400) + "; rm -rf ~/important"
        let client = Task { await runClient(
            eventJSON("PermissionRequest", tool: "Bash", command: long), socket: fixture.socket) }
        #expect(await waitUntil { model.pending.count == 1 })
        let request = try #require(model.pending.first)
        #expect(request.summary.isTruncated)

        // Allow is refused without reaching the engine: the request is still pending, and the hook still waits.
        #expect(await model.decide(request.id, .allow) == false)
        #expect(model.pending.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.pending.first?.id == request.id)

        // Deny still works.
        #expect(await model.decide(request.id, .deny))
        #expect(await client.value == HookOutput.stdout(for: .decision(.deny), event: HookEvent(sessionId: "s", name: .permissionRequest)))
        #expect(await waitUntil { model.pending.isEmpty })
        await model.stop()
    }

    @Test func fullyShownCommandCanStillBeAllowedFromTheMac() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()

        let client = Task { await runClient(
            eventJSON("PermissionRequest", tool: "Bash", command: "ls -la"), socket: fixture.socket) }
        #expect(await waitUntil { model.pending.count == 1 })
        let id = try #require(model.pending.first?.id)
        #expect(await model.decide(id, .allow))
        #expect(await client.value == HookOutput.stdout(for: .decision(.allow), event: HookEvent(sessionId: "s", name: .permissionRequest)))
        await model.stop()
    }

    /// The island reads the model only through `IslandFeed`; plans, answers and releases reach the engine.
    @Test func theModelFeedsTheIslandAndForwardsUnknownRequestsAsNoOps() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()
        let feed: any IslandFeed = model
        #expect(feed.sessions.isEmpty)
        #expect(await feed.decidePlan(UUID(), .acceptEdits) == false)
        #expect(await feed.answer(UUID(), []) == false)
        await feed.releaseQuestion(UUID())
        #expect(await feed.decide(UUID(), .deny) == false)

        _ = await runClient(eventJSON("SessionStart", cwd: "/Users/me/code/buddy"), socket: fixture.socket)
        #expect(await waitUntil { feed.sessions.first?.project == "buddy" })
        await model.stop()
    }

    @Test func decideForUnknownRequestIsNoOp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()

        #expect(await model.decide(UUID(), .allow) == false)
        #expect(model.errorMessage == nil)
        #expect(model.pending.isEmpty)
        await model.stop()
    }

    @Test func engineStartFailureSurfacesErrorWithoutCrashing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // A regular file where the socket should go: the server refuses to replace it.
        let blocker = tempSocketURL()
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let model = makeModel(fixture, socket: blocker)

        await model.start()

        let message = try #require(model.engineError)
        #expect(message.contains("not a socket"))
        #expect(model.errorMessage == nil)
        #expect(model.engineRunning == false)
        #expect(try Data(contentsOf: blocker) == Data("x".utf8))
        await model.stop()
    }

    @Test func notListeningNoticeAppearsOnlyAfterAStartAttemptFinished() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        // Launching: nothing has been attempted yet, so "not running" is not a problem.
        #expect(model.engineRunning == false)
        #expect(model.hasAttemptedStart == false)
        #expect(model.notListeningNotice == nil)

        await model.start()
        #expect(model.hasAttemptedStart)
        #expect(model.notListeningNotice == nil)  // running

        await model.stop()
        #expect(model.notListeningNotice == "Not listening")
    }

    @Test func notListeningNoticeCarriesTheStartFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let blocker = tempSocketURL()
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let model = makeModel(fixture, socket: blocker)
        #expect(model.notListeningNotice == nil)

        await model.start()
        let notice = try #require(model.notListeningNotice)
        #expect(notice.hasPrefix("Not listening: "))
        #expect(notice.contains("not a socket"))
    }

    @Test func tooLongSocketPathSurfacesError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 200) + ".sock")
        let model = makeModel(fixture, socket: long)

        await model.start()

        #expect(model.engineError?.contains("too long") == true)
        #expect(model.engineRunning == false)
    }

    @Test func engineErrorSurvivesUnrelatedInstallActions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let blocker = tempSocketURL()
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let model = makeModel(fixture, socket: blocker)
        await model.start()
        let failure = try #require(model.engineError)

        // A successful install, a failing one and an uninstall must all leave the engine error alone.
        let plan = try model.planInstall()
        try model.applyInstall(plan)
        #expect(model.engineError == failure)
        #expect(throws: AppModel.ActionError.settingsChangedSinceReview) { try model.applyInstall(plan) }
        model.report(AppModel.ActionError.hookBinaryUnavailable)
        #expect(model.engineError == failure)
        try model.applyUninstall(try model.planUninstall())
        #expect(model.engineError == failure)
        #expect(model.engineRunning == false)
    }

    @Test func addressInUseKeepsErrorUntilARetrySucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = makeModel(fixture)
        await first.start()
        #expect(first.engineRunning)

        let second = makeModel(fixture)  // same socket path, live server
        await second.start()
        #expect(second.engineError?.contains("already listening") == true)
        #expect(second.engineRunning == false)

        await first.stop()
        await second.start()  // retry after the first released the socket
        #expect(second.engineRunning)
        #expect(second.engineError == nil)
        await second.stop()
    }

    @Test func startIsIdempotentWhileRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()
        await model.start()
        #expect(model.engineRunning)
        #expect(model.engineError == nil)
        await model.stop()
    }

    @Test func successfulStartMarksEngineRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        await model.start()
        #expect(model.engineRunning)
        await model.stop()
        #expect(model.engineRunning == false)
    }

    // MARK: Hook status

    @Test func hooksInstalledReflectsSettingsFileOnStart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let plain = makeModel(fixture)
        #expect(plain.hooksInstalled == false)

        try fixture.writeSettings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/bin/buddy-hook'"}]}]}}"#)
        let model = makeModel(fixture)
        await model.start()
        #expect(model.hooksInstalled)
        await model.stop()
    }

    @Test func unrelatedHooksDoNotCountAsInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#)
        let model = makeModel(fixture)
        await model.start()
        #expect(model.hooksInstalled == false)
        await model.stop()
    }

    // MARK: Plan / apply

    @Test func planInstallReturnsDiffWithoutWriting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = #"{"theme":"dark"}"#
        try fixture.writeSettings(original)
        let model = makeModel(fixture)

        let plan = try model.planInstall()

        #expect(plan.changed)
        #expect(plan.diff.contains("buddy-hook"))
        #expect(plan.diff.contains(fixture.hookCommandPath))
        #expect(fixture.settingsData() == Data(original.utf8))
        #expect(fixture.settingsDirectoryEntries() == ["settings.json"])
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
        #expect(model.hooksInstalled == false)
    }

    @Test func planInstallWithMissingSettingsCreatesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)

        let plan = try model.planInstall()

        #expect(plan.changed)
        #expect(!FileManager.default.fileExists(atPath: fixture.settings.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test func planInstallOnMalformedSettingsThrowsAndWritesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings("[1, 2, 3]")
        let model = makeModel(fixture)

        #expect(throws: InstallerError.malformedSettings) { try model.planInstall() }
        #expect(fixture.settingsData() == Data("[1, 2, 3]".utf8))
        #expect(fixture.settingsDirectoryEntries() == ["settings.json"])
    }

    @Test func applyInstallCopiesBinaryThenWritesSettings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(#"{"theme":"dark"}"#)
        let model = makeModel(fixture)
        let plan = try model.planInstall()

        try model.applyInstall(plan)

        let binary = URL(fileURLWithPath: fixture.hookCommandPath)
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        let mode = try FileManager.default.attributesOfItem(atPath: binary.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
        let written = try #require(fixture.settingsData())
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains(ClaudeSettingsInstaller.shellQuote(fixture.hookCommandPath)))
        #expect(text.contains("\"theme\""))
        #expect(model.hooksInstalled)
        let backups = fixture.settingsDirectoryEntries().filter { $0.hasPrefix("settings.json.buddy-backup-") }
        #expect(backups.count == 1)
        #expect(model.resultMessage?.contains(backups[0]) == true)
        // Already installed: planning again finds nothing to change.
        #expect(try model.planInstall().changed == false)
    }

    @Test func applyInstallWithMissingHookBinaryWritesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(#"{"theme":"dark"}"#)
        let missing = fixture.root.appendingPathComponent("no-such-hook")
        let engine = BuddyEngine(socketPath: fixture.socket, transport: nil)
        let model = AppModel(
            engine: engine,
            paths: AppModel.Paths(
                settingsURL: fixture.settings, supportDirectory: fixture.support, hookBinarySource: missing))
        let plan = try model.planInstall()

        #expect {
            try model.applyInstall(plan)
        } throws: { error in
            if case HookBinaryInstallerError.sourceNotExecutable(let path) = error {
                return URL(fileURLWithPath: path).lastPathComponent == "no-such-hook"
            }
            return false
        }

        #expect(fixture.settingsData() == Data(#"{"theme":"dark"}"#.utf8))
        #expect(fixture.settingsDirectoryEntries() == ["settings.json"])
        #expect(model.hooksInstalled == false)
    }

    @Test func applyInstallWithoutEmbeddedBinaryWritesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let engine = BuddyEngine(socketPath: fixture.socket, transport: nil)
        let model = AppModel(
            engine: engine,
            paths: AppModel.Paths(settingsURL: fixture.settings, supportDirectory: fixture.support, hookBinarySource: nil))
        let plan = try model.planInstall()

        #expect(throws: AppModel.ActionError.hookBinaryUnavailable) { try model.applyInstall(plan) }

        #expect(!FileManager.default.fileExists(atPath: fixture.settings.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    // MARK: BUDDY_SETTINGS / BUDDY_HOME: both or neither (mirrors buddyctl)

    @Test func standardPathsNeedBothOverridesOrNeither() {
        // Only builds the paths from a made-up environment: nothing is read, nothing is written.
        let settingsOnly = AppModel.Paths.standard(environment: ["BUDDY_SETTINGS": "/tmp/buddy-x/settings.json"])
        #expect(settingsOnly.configurationError?.contains("BUDDY_SETTINGS is set but BUDDY_HOME is not") == true)
        let homeOnly = AppModel.Paths.standard(environment: ["BUDDY_HOME": "/tmp/buddy-x/home"])
        #expect(homeOnly.configurationError?.contains("BUDDY_HOME is set but BUDDY_SETTINGS is not") == true)

        let both = AppModel.Paths.standard(environment: ["BUDDY_SETTINGS": "/tmp/buddy-x/s.json", "BUDDY_HOME": "/tmp/buddy-x/h"])
        #expect(both.configurationError == nil)
        #expect(both.settingsURL.path == "/tmp/buddy-x/s.json")
        #expect(both.supportDirectory.path == "/tmp/buddy-x/h")
        #expect(AppModel.Paths.standard(environment: [:]).configurationError == nil)
        // Empty counts as unset, like buddyctl.
        #expect(AppModel.Paths.standard(environment: ["BUDDY_SETTINGS": "", "BUDDY_HOME": ""]).configurationError == nil)
        #expect(AppModel.Paths.standard(environment: ["BUDDY_SETTINGS": "/tmp/buddy-x/s.json", "BUDDY_HOME": ""]).configurationError != nil)
    }

    @Test func aHalfSetOverrideShowsAnErrorAndRefusesEveryInstallAction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(#"{"theme":"dark"}"#)
        let paths = AppModel.Paths(
            settingsURL: fixture.settings, supportDirectory: fixture.support, hookBinarySource: fixture.hookSource,
            configurationError: "BUDDY_SETTINGS is set but BUDDY_HOME is not.")
        let model = AppModel(engine: BuddyEngine(socketPath: fixture.socket, transport: nil), paths: paths)

        // Visible from the start, before any action.
        #expect(model.errorMessage?.contains("BUDDY_SETTINGS is set but BUDDY_HOME is not") == true)
        #expect(model.hooksInstalled == false)

        #expect { try model.planInstall() } throws: { error in
            if case AppModel.ActionError.invalidConfiguration = error { return true }
            return false
        }
        #expect { try model.planUninstall() } throws: { error in
            if case AppModel.ActionError.invalidConfiguration = error { return true }
            return false
        }
        // Even a plan made elsewhere cannot be applied: nothing is copied and nothing is written.
        let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: "'/tmp/x/buddy-hook'")
        #expect { try model.applyInstall(plan) } throws: { error in
            if case AppModel.ActionError.invalidConfiguration = error { return true }
            return false
        }
        #expect { try model.applyUninstall(plan) } throws: { error in
            if case AppModel.ActionError.invalidConfiguration = error { return true }
            return false
        }
        #expect(fixture.settingsData() == Data(#"{"theme":"dark"}"#.utf8))
        #expect(fixture.settingsDirectoryEntries() == ["settings.json"])
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
        #expect(AppModel.describe(AppModel.ActionError.invalidConfiguration("x")).contains("Nothing was read or written"))
    }

    @Test func settingsWriteFailureAfterBinaryCopyIsReportedAsSuch() throws {
        let fixture = try Fixture()
        let settingsDirectory = fixture.settings.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: settingsDirectory.path)
            fixture.cleanUp()
        }
        try fixture.writeSettings(#"{"theme":"dark"}"#)
        let model = makeModel(fixture)
        let plan = try model.planInstall()
        // A read-only directory makes the backup (the first write step) fail, leaving settings.json untouched.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: settingsDirectory.path)

        var thrown: AppModel.ActionError?
        do { try model.applyInstall(plan) } catch let error as AppModel.ActionError { thrown = error }
        let error = try #require(thrown)
        guard case .settingsWriteFailedAfterBinaryInstall(let binary, _) = error else {
            Issue.record("unexpected error \(error)")
            return
        }

        #expect(binary == fixture.hookCommandPath)
        #expect(FileManager.default.isExecutableFile(atPath: fixture.hookCommandPath))
        #expect(fixture.settingsData() == Data(#"{"theme":"dark"}"#.utf8))
        let text = AppModel.describe(error)
        #expect(text.contains("installed"))
        #expect(text.contains("NOT changed"))
        #expect(model.hooksInstalled == false)
    }

    @Test func applyInstallWhenSettingsBecameMalformedThrowsAndWritesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(#"{"theme":"dark"}"#)
        let model = makeModel(fixture)
        let plan = try model.planInstall()
        try fixture.writeSettings("{ not json")

        #expect(throws: InstallerError.malformedSettings) { try model.applyInstall(plan) }

        #expect(fixture.settingsData() == Data("{ not json".utf8))
        #expect(fixture.settingsDirectoryEntries() == ["settings.json"])
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test func applyInstallRefusesAPlanThatNoLongerMatchesTheFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(#"{"theme":"dark"}"#)
        let model = makeModel(fixture)
        let plan = try model.planInstall()
        let edited = #"{"theme":"light"}"#
        try fixture.writeSettings(edited)

        #expect(throws: AppModel.ActionError.settingsChangedSinceReview) { try model.applyInstall(plan) }

        #expect(fixture.settingsData() == Data(edited.utf8))
        #expect(fixture.settingsDirectoryEntries() == ["settings.json"])
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test func applyInstallRejectsAnUninstallPlan() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        try model.applyInstall(try model.planInstall())
        let uninstall = try model.planUninstall()
        let before = fixture.settingsData()

        #expect(throws: AppModel.ActionError.settingsChangedSinceReview) { try model.applyInstall(uninstall) }
        #expect(fixture.settingsData() == before)
    }

    @Test func uninstallRemovesBuddyEntriesAndKeepsOthers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(
            #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#)
        let model = makeModel(fixture)
        try model.applyInstall(try model.planInstall())
        #expect(model.hooksInstalled)

        let plan = try model.planUninstall()
        #expect(plan.changed)
        try model.applyUninstall(plan)

        #expect(model.hooksInstalled == false)
        let text = String(decoding: try #require(fixture.settingsData()), as: UTF8.self)
        #expect(text.contains("/usr/bin/true"))
        #expect(!text.contains("buddy-hook"))
    }

    @Test func planUninstallNeverWrites() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)

        let plan = try model.planUninstall()

        #expect(plan.changed == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.settings.deletingLastPathComponent().path))
    }

    @Test func describeMapsKnownErrorsToReadableText() {
        #expect(AppModel.describe(InstallerError.malformedSettings).contains("nothing was written"))
        #expect(AppModel.describe(HookSocketError.pathTooLong).contains("too long"))
        #expect(AppModel.describe(AppModel.ActionError.settingsChangedSinceReview).contains("changed"))
    }
}
