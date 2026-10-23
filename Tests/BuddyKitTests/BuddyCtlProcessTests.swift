import Foundation
import Testing

/// Runs the real `buddyctl` executable. Tests that pass `--apply` always set both override
/// variables, so they cannot reach the user's real Claude settings or Application Support
/// directory; the tests for a partial override never apply (see below).
@Suite struct BuddyCtlProcessTests {
    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ arguments: [String], environment: [String: String]) throws -> Run {
        let process = Process()
        process.executableURL = try HookProcess.executable(named: "buddyctl")
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/buddyctl-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // The refusal tests deliberately never pass --apply: they must stay harmless (read-only) even if
    // the check regresses, because without it the unset override falls back to the real
    // ~/.claude or ~/Library/Application Support/Buddy.

    @Test(arguments: ["install-hooks", "uninstall-hooks"])
    func onlyTheSettingsOverrideIsRefused(command: String) throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"dark"}"#.utf8)
        try original.write(to: settings)

        let result = try run([command], environment: ["BUDDY_SETTINGS": settings.path])
        #expect(result.status == 1)
        #expect(result.stderr.contains("BUDDY_SETTINGS") && result.stderr.contains("BUDDY_HOME"))
        #expect(result.stdout.isEmpty)
        #expect(try Data(contentsOf: settings) == original)
    }

    @Test(arguments: ["install-hooks", "uninstall-hooks"])
    func onlyTheHomeOverrideIsRefused(command: String) throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home")

        let result = try run([command], environment: ["BUDDY_HOME": home.path])
        #expect(result.status == 1)
        #expect(result.stderr.contains("BUDDY_SETTINGS") && result.stderr.contains("BUDDY_HOME"))
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test func emptyOverrideCountsAsUnset() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let result = try run(
            ["install-hooks"], environment: ["BUDDY_SETTINGS": settings.path, "BUDDY_HOME": ""])
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
    }

    @Test func applyWithBothOverridesInstallsIntoThem() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let home = dir.appendingPathComponent("home")

        let result = try run(
            ["install-hooks", "--apply"],
            environment: ["BUDDY_SETTINGS": settings.path, "BUDDY_HOME": home.path])
        #expect(result.status == 0, "\(result.stderr)")
        let written = try String(contentsOf: settings, encoding: .utf8)
        #expect(written.contains(home.appendingPathComponent("bin/buddy-hook").path))
        #expect(FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("bin/buddy-hook").path))

        let removal = try run(
            ["uninstall-hooks", "--apply"],
            environment: ["BUDDY_SETTINGS": settings.path, "BUDDY_HOME": home.path])
        #expect(removal.status == 0, "\(removal.stderr)")
        #expect(!(try String(contentsOf: settings, encoding: .utf8)).contains("buddy-hook"))
    }
}
