import BuddyKit
import Foundation

// buddyctl: installs/uninstalls Buddy's hooks in Claude Code's settings.json.
//   buddyctl install-hooks   [--apply]
//   buddyctl uninstall-hooks [--apply]
// Without --apply it only prints the diff. Test overrides: BUDDY_SETTINGS (settings.json path) and
// BUDDY_HOME (Buddy support directory, default ~/Library/Application Support/Buddy). Set both or
// neither: with only one, the other would fall back to the real location and a test path could end
// up in the real settings file (or the real hook binary be replaced), so that is an error.

struct CLIError: Error {
    let message: String
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func settingsURL(_ env: [String: String]) -> URL {
    if let path = env["BUDDY_SETTINGS"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
}

func buddyHome(_ env: [String: String]) -> URL {
    if let path = env["BUDDY_HOME"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Buddy", isDirectory: true)
}

/// An override counts as set only when non-empty.
func requireBothOrNeitherOverride(_ env: [String: String]) throws {
    let settingsSet = !(env["BUDDY_SETTINGS"] ?? "").isEmpty
    let homeSet = !(env["BUDDY_HOME"] ?? "").isEmpty
    guard settingsSet == homeSet else {
        let only = settingsSet ? "BUDDY_SETTINGS" : "BUDDY_HOME"
        let missing = settingsSet ? "BUDDY_HOME" : "BUDDY_SETTINGS"
        throw CLIError(message: "\(only) is set but \(missing) is not. Set both BUDDY_SETTINGS and BUDDY_HOME (a test setup) or neither (the real ~/.claude and Application Support); nothing was read or written.")
    }
}

func readSettings(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
        return try Data(contentsOf: url)
    } catch {
        throw CLIError(message: "cannot read \(url.path): \(error.localizedDescription)")
    }
}

func report(_ plan: InstallPlan, settings: URL, apply: Bool) {
    if !plan.changed {
        print("\(settings.path): no changes needed.")
    } else {
        print("Changes to \(settings.path):")
        print(plan.diff)
        if !apply { print("\nDry run: nothing was written. Re-run with --apply to write these changes.") }
    }
}

/// Copies the freshly built `buddy-hook` (found next to this executable) into `<home>/bin`, mode 0755.
func installHookBinary(home: URL) throws -> URL {
    guard let own = Bundle.main.executableURL else {
        throw CLIError(message: "cannot locate the buddyctl executable")
    }
    let source = own.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("buddy-hook")
    guard FileManager.default.isExecutableFile(atPath: source.path) else {
        throw CLIError(message: "buddy-hook not found next to buddyctl at \(source.path); build it first")
    }
    return try HookBinaryInstaller.install(source: source, into: home)
}

func installHooks(apply: Bool, env: [String: String]) throws {
    let settings = settingsURL(env)
    let home = buddyHome(env)
    let hookPath = HookBinaryInstaller.destination(in: home).path
    let command = ClaudeSettingsInstaller.shellQuote(hookPath)

    let plan = try ClaudeSettingsInstaller.planInstall(existing: readSettings(settings), hookCommand: command)
    report(plan, settings: settings, apply: apply)
    guard apply else { return }

    // Install the binary first so settings never reference a hook that is not there.
    let installed = try installHookBinary(home: home)
    print("Installed \(installed.path)")
    try ClaudeSettingsInstaller.apply(plan, to: settings, now: Date())
    if plan.changed { print("Updated \(settings.path) (a timestamped backup was kept next to it if the file existed).") }
}

func uninstallHooks(apply: Bool, env: [String: String]) throws {
    let settings = settingsURL(env)
    let plan = try ClaudeSettingsInstaller.planUninstall(existing: readSettings(settings))
    report(plan, settings: settings, apply: apply)
    guard apply else { return }
    try ClaudeSettingsInstaller.apply(plan, to: settings, now: Date())
    if plan.changed { print("Updated \(settings.path) (a timestamped backup was kept next to it).") }
}

let usage = """
usage: buddyctl install-hooks [--apply]
       buddyctl uninstall-hooks [--apply]
Prints the settings.json diff; writes only with --apply.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["install-hooks", "uninstall-hooks"].contains(command),
      Set(arguments.dropFirst()).isSubset(of: ["--apply"]), arguments.count <= 2 else {
    printErr(usage)
    exit(2)
}
let apply = arguments.contains("--apply")
let environment = ProcessInfo.processInfo.environment

do {
    try requireBothOrNeitherOverride(environment)
    if command == "install-hooks" {
        try installHooks(apply: apply, env: environment)
    } else {
        try uninstallHooks(apply: apply, env: environment)
    }
} catch InstallerError.malformedSettings {
    printErr("error: settings file is not valid Claude settings JSON (expected an object with an object `hooks`); nothing was written.")
    exit(1)
} catch let error as CLIError {
    printErr("error: \(error.message)")
    exit(1)
} catch {
    printErr("error: \(error.localizedDescription)")
    exit(1)
}
