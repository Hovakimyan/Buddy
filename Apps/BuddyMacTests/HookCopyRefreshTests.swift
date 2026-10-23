import BuddyKit
import Foundation
import Testing

// SAFETY: every path below is inside a fresh temp directory. Nothing here may touch ~/.claude or
// ~/Library/Application Support/Buddy, and no test starts an engine.

private struct RefreshFixture {
    let root: URL
    let settings: URL
    let support: URL
    let bundled: URL

    init(bundledText: String = "#!/bin/sh\necho new\n") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = root.appendingPathComponent("claude/settings.json")
        support = root.appendingPathComponent("Application Support/Buddy", isDirectory: true)
        bundled = root.appendingPathComponent("bundled-buddy-hook")
        try Self.writeExecutable(bundledText, to: bundled)
    }

    var installed: URL { HookBinaryInstaller.destination(in: support) }

    static func writeExecutable(_ text: String, to url: URL, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func installOldCopy(_ text: String = "#!/bin/sh\necho old\n", mode: Int = 0o755) throws {
        try Self.writeExecutable(text, to: installed, mode: mode)
    }

    func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: settings)
    }

    func installedText() -> String? {
        (try? Data(contentsOf: installed)).map { String(decoding: $0, as: UTF8.self) }
    }

    func binEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)) ?? []).sorted()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// The settings file with Buddy's hooks in it, running the copy in the support directory like a real install.
    var installedSettingsText: String {
        settingsText(command: ClaudeSettingsInstaller.shellQuote(installed.path))
    }

    func settingsText(command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":""# + escaped + #""}]}]}}"#
    }

    var paths: AppModel.Paths {
        AppModel.Paths(settingsURL: settings, supportDirectory: support, hookBinarySource: bundled)
    }
}

@Suite struct HookCopyRefreshTests {
    @Test func doesNothingWhenHooksAreNotInstalled() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        let outcome = HookCopyRefresh.run(hooksInstalled: false, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .notInstalled)
        #expect(outcome.message == nil)
        // Not even the support directory is created.
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test func doesNotTouchAnOldCopyWhenHooksAreNotInstalled() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy()
        _ = HookCopyRefresh.run(hooksInstalled: false, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(fixture.installedText() == "#!/bin/sh\necho old\n")
    }

    @Test func aBuildWithoutAnEmbeddedHookChangesNothing() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy()
        let outcome = HookCopyRefresh.run(hooksInstalled: true, source: nil, supportDirectory: fixture.support)
        #expect(outcome == .noBundledHook)
        #expect(outcome.message?.contains("no buddy-hook") == true)
        #expect(fixture.installedText() == "#!/bin/sh\necho old\n")
    }

    @Test func anotherRunningBuddyKeepsTheCopyUntouched() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy()
        let outcome = HookCopyRefresh.run(
            hooksInstalled: true, otherInstanceRunning: true, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .otherInstanceRunning)
        #expect(outcome.message?.contains("Another Buddy is running") == true)
        #expect(fixture.installedText() == "#!/bin/sh\necho old\n")
        // Not installed still wins: there is nothing to say when the hooks are not there.
        #expect(HookCopyRefresh.run(
            hooksInstalled: false, otherInstanceRunning: true, source: fixture.bundled, supportDirectory: fixture.support)
            == .notInstalled)
    }

    @Test func hooksThatRunAnotherBuddyHookLeaveTheSupportCopyAlone() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        let outcome = HookCopyRefresh.run(
            hooksInstalled: true, entriesUseSupportCopy: false, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .pointsElsewhere)
        #expect(outcome.message?.contains("Install hooks") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test func recognisesWhichCopyTheSettingsRun() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        func points(_ command: String) -> Bool {
            HookCopyRefresh.pointsAtSupportCopy(
                settings: Data(fixture.settingsText(command: command).utf8), supportDirectory: fixture.support)
        }
        #expect(points(ClaudeSettingsInstaller.shellQuote(fixture.installed.path)))
        #expect(points(fixture.installed.path))
        #expect(points("\"\(fixture.installed.path)\""))
        #expect(points(ClaudeSettingsInstaller.shellQuote(fixture.installed.path) + " --ask"))
        #expect(!points("'/somewhere/else/bin/buddy-hook'"))
        #expect(!points("/usr/bin/true"))
        #expect(!HookCopyRefresh.pointsAtSupportCopy(settings: nil, supportDirectory: fixture.support))
        #expect(!HookCopyRefresh.pointsAtSupportCopy(settings: Data("not json".utf8), supportDirectory: fixture.support))
        #expect(!HookCopyRefresh.pointsAtSupportCopy(settings: Data(#"{"hooks":[]}"#.utf8), supportDirectory: fixture.support))
    }

    @Test func aDifferingCopyIsReplacedStagedAndExecutable() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy(mode: 0o644)  // also fixes permissions
        let outcome = HookCopyRefresh.run(hooksInstalled: true, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .refreshed(path: fixture.installed.path))
        #expect(outcome.message?.contains(fixture.installed.path) == true)
        #expect(fixture.installedText() == "#!/bin/sh\necho new\n")
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.installed.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
        // No staging file is left behind.
        #expect(fixture.binEntries() == ["buddy-hook"])
    }

    @Test func aMissingCopyIsRestoredWhenHooksAreInstalled() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        let outcome = HookCopyRefresh.run(hooksInstalled: true, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .refreshed(path: fixture.installed.path))
        #expect(fixture.installedText() == "#!/bin/sh\necho new\n")
    }

    @Test func anIdenticalExecutableCopyIsLeftAlone() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy("#!/bin/sh\necho new\n")
        let before = try FileManager.default.attributesOfItem(atPath: fixture.installed.path)[.systemFileNumber] as? NSNumber
        let outcome = HookCopyRefresh.run(hooksInstalled: true, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .upToDate)
        #expect(outcome.message == "The installed buddy-hook is up to date.")
        // The same file (same inode): it was not rewritten.
        let after = try FileManager.default.attributesOfItem(atPath: fixture.installed.path)[.systemFileNumber] as? NSNumber
        #expect(before == after)
        #expect(fixture.binEntries() == ["buddy-hook"])
    }

    @Test func anIdenticalButNotExecutableCopyIsRepaired() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy("#!/bin/sh\necho new\n", mode: 0o644)
        let outcome = HookCopyRefresh.run(hooksInstalled: true, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .refreshed(path: fixture.installed.path))
        #expect(FileManager.default.isExecutableFile(atPath: fixture.installed.path))
    }

    @Test func anIdenticalButQuarantinedCopyIsReplacedWithoutTheFlag() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy("#!/bin/sh\necho new\n")
        let value = "0083;6ad80eda;Safari;E1A1CBFF-F123-47A2-8652-D9B119F61B4F"
        _ = value.withCString {
            setxattr(fixture.installed.path, HookBinaryInstaller.quarantineAttribute, $0, strlen($0), 0, XATTR_NOFOLLOW)
        }
        #expect(HookCopyRefresh.needsRefresh(source: fixture.bundled, supportDirectory: fixture.support))
        let outcome = HookCopyRefresh.run(hooksInstalled: true, source: fixture.bundled, supportDirectory: fixture.support)
        #expect(outcome == .refreshed(path: fixture.installed.path))
        #expect(!HookBinaryInstaller.isQuarantined(fixture.installed))
    }

    @Test func aFailureKeepsTheOldCopyAndSaysSo() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.installOldCopy()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.bundled.path)  // not executable
        let outcome = HookCopyRefresh.run(hooksInstalled: true, source: fixture.bundled, supportDirectory: fixture.support)
        guard case .failed(let reason) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(reason.contains("not executable"))
        #expect(outcome.isFailure)
        #expect(outcome.message?.contains("Install hooks") == true)
        #expect(fixture.installedText() == "#!/bin/sh\necho old\n")
        #expect(fixture.binEntries() == ["buddy-hook"])
    }
}

@MainActor
@Suite struct AppModelHookRefreshTests {
    private func makeModel(_ fixture: RefreshFixture, paths: AppModel.Paths? = nil) -> AppModel {
        // The engine is never started, so no socket is opened.
        AppModel(
            engine: BuddyEngine(socketPath: fixture.root.appendingPathComponent("never.sock"), transport: nil),
            paths: paths ?? fixture.paths)
    }

    @Test func refreshesTheCopyButNeverTheSettingsFile() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(fixture.installedSettingsText)
        try fixture.installOldCopy()
        let settingsBefore = try Data(contentsOf: fixture.settings)
        let model = makeModel(fixture)
        #expect(model.hookRefresh == nil)

        model.refreshInstalledHookCopy()

        #expect(model.hookRefresh == .refreshed(path: fixture.installed.path))
        #expect(fixture.installedText() == "#!/bin/sh\necho new\n")
        #expect(try Data(contentsOf: fixture.settings) == settingsBefore)
        // No backup or any other file appeared next to the settings.
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.settings.deletingLastPathComponent().path)
        #expect(entries == ["settings.json"])
    }

    @Test func hooksPointingElsewhereAreReportedAndTheCopyIsNotTouched() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(fixture.settingsText(command: "'/old/buddyctl/bin/buddy-hook'"))
        let model = makeModel(fixture)
        model.refreshInstalledHookCopy()
        #expect(model.hookRefresh == .pointsElsewhere)
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test func anotherRunningBuddyKeepsTheModelFromRefreshing() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(fixture.installedSettingsText)
        try fixture.installOldCopy()
        let model = makeModel(fixture)
        model.refreshInstalledHookCopy(otherInstanceRunning: true)
        #expect(model.hookRefresh == .otherInstanceRunning)
        #expect(fixture.installedText() == "#!/bin/sh\necho old\n")
    }

    @Test func doesNothingWhenTheSettingsHaveNoBuddyHooks() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#)
        let model = makeModel(fixture)
        model.refreshInstalledHookCopy()
        #expect(model.hookRefresh == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test func doesNothingWithoutASettingsFile() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        let model = makeModel(fixture)
        model.refreshInstalledHookCopy()
        #expect(model.hookRefresh == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.settings.path))
    }

    @Test func anUnusableConfigurationRefusesToTouchAnything() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(fixture.installedSettingsText)
        try fixture.installOldCopy()
        var paths = fixture.paths
        paths.configurationError = "BUDDY_SETTINGS is set but BUDDY_HOME is not."
        let model = makeModel(fixture, paths: paths)
        model.refreshInstalledHookCopy()
        #expect(model.hookRefresh == nil)
        #expect(fixture.installedText() == "#!/bin/sh\necho old\n")
    }

    @Test func anUpToDateCopyReportsThat() throws {
        let fixture = try RefreshFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSettings(fixture.installedSettingsText)
        try fixture.installOldCopy("#!/bin/sh\necho new\n")
        let model = makeModel(fixture)
        model.refreshInstalledHookCopy()
        #expect(model.hookRefresh == .upToDate)
    }
}
