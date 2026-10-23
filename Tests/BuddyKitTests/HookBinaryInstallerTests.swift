import Foundation
import Testing
@testable import BuddyKit

@Suite struct HookBinaryInstallerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-binstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSource(in dir: URL, contents: String = "#!/bin/sh\nexit 0\n", mode: Int = 0o755) throws -> URL {
        let url = dir.appendingPathComponent("source-hook")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try #require(value).intValue
    }

    private func entries(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    @Test func destinationIsBinBuddyHook() {
        let support = URL(fileURLWithPath: "/tmp/x/Buddy", isDirectory: true)
        #expect(HookBinaryInstaller.destination(in: support).path == "/tmp/x/Buddy/bin/buddy-hook")
    }

    @Test func copiesIntoNewSupportDirectoryWithModes() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(in: root, mode: 0o700)
        let support = root.appendingPathComponent("Support/Buddy", isDirectory: true)

        let installed = try HookBinaryInstaller.install(source: source, into: support)

        #expect(installed == HookBinaryInstaller.destination(in: support))
        #expect(try Data(contentsOf: installed) == Data(contentsOf: source))
        #expect(try permissions(installed) == 0o755)
        #expect(try permissions(support) == 0o700)
        #expect(try permissions(support.appendingPathComponent("bin")) == 0o755)
        #expect(try entries(support.appendingPathComponent("bin")) == ["buddy-hook"])
    }

    @Test func replacesExistingBinaryWithoutLeavingStagingFiles() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Buddy", isDirectory: true)
        let first = try makeSource(in: root, contents: "old")
        try HookBinaryInstaller.install(source: first, into: support)
        let second = try makeSource(in: root, contents: "new")

        let installed = try HookBinaryInstaller.install(source: second, into: support)

        #expect(try String(contentsOf: installed, encoding: .utf8) == "new")
        #expect(try entries(support.appendingPathComponent("bin")) == ["buddy-hook"])
    }

    @Test(arguments: [0o644, 0o700, 0o600])
    func replacingABinaryWithOtherPermissionsEndsUpAs0755(existingMode: Int) throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Buddy", isDirectory: true)
        let installed = HookBinaryInstaller.destination(in: support)
        try FileManager.default.createDirectory(
            at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed)
        try FileManager.default.setAttributes([.posixPermissions: existingMode], ofItemAtPath: installed.path)
        let source = try makeSource(in: root, contents: "new")

        try HookBinaryInstaller.install(source: source, into: support)

        #expect(try String(contentsOf: installed, encoding: .utf8) == "new")
        #expect(try permissions(installed) == 0o755)
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        #expect(try entries(installed.deletingLastPathComponent()) == ["buddy-hook"])
    }

    @Test func missingSourceThrowsAndTouchesNothing() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Buddy", isDirectory: true)
        let missing = root.appendingPathComponent("nope")

        #expect(throws: HookBinaryInstallerError.sourceNotExecutable(missing.path)) {
            try HookBinaryInstaller.install(source: missing, into: support)
        }
        #expect(!FileManager.default.fileExists(atPath: support.path))
    }

    @Test func nonExecutableSourceIsRejected() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(in: root, mode: 0o644)
        let support = root.appendingPathComponent("Buddy", isDirectory: true)

        #expect(throws: HookBinaryInstallerError.self) {
            try HookBinaryInstaller.install(source: source, into: support)
        }
        #expect(!FileManager.default.fileExists(atPath: support.path))
    }

    @Test func failedCopyKeepsExistingBinaryAndLeavesNoStagingFile() throws {
        let root = try tempDir()
        let support = root.appendingPathComponent("Buddy", isDirectory: true)
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            try? FileManager.default.removeItem(at: root)
        }
        let first = try makeSource(in: root, contents: "old")
        let installed = try HookBinaryInstaller.install(source: first, into: support)
        let second = try makeSource(in: root, contents: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)

        #expect(throws: (any Error).self) {
            try HookBinaryInstaller.install(source: second, into: support)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        #expect(try String(contentsOf: installed, encoding: .utf8) == "old")
        #expect(try entries(bin) == ["buddy-hook"])
    }

    private func setQuarantine(_ url: URL) {
        let value = "0083;6ad80eda;Safari;E1A1CBFF-F123-47A2-8652-D9B119F61B4F"
        _ = value.withCString {
            setxattr(url.path, HookBinaryInstaller.quarantineAttribute, $0, strlen($0), 0, XATTR_NOFOLLOW)
        }
    }

    /// A Buddy opened through "Open Anyway" still has the quarantine flag on its bundle. The copy Claude Code runs
    /// must not inherit it, or Gatekeeper blocks every hook.
    @Test func theCopyNeverCarriesTheQuarantineFlag() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(in: root)
        setQuarantine(source)
        #expect(HookBinaryInstaller.isQuarantined(source))
        let support = root.appendingPathComponent("Buddy", isDirectory: true)

        let installed = try HookBinaryInstaller.install(source: source, into: support)
        #expect(!HookBinaryInstaller.isQuarantined(installed))
        #expect(HookBinaryInstaller.isQuarantined(source), "the source keeps its flag")

        // Replacing an existing (flagged) copy also ends up clean.
        setQuarantine(installed)
        try HookBinaryInstaller.install(source: source, into: support)
        #expect(!HookBinaryInstaller.isQuarantined(installed))
    }
}
