import BuddyKit
import Foundation

/// Keeps the installed `buddy-hook` (`<support>/bin/buddy-hook`) in step with the one inside the app after an
/// update. Claude Code runs the copy, not the one in the bundle, so without this a new version of Buddy would
/// keep relaying through the old binary until the person pressed "Install hooks" again.
///
/// It only ever replaces that one file. It never reads or writes the settings file, and it does nothing when
/// Buddy's hooks are not installed.
enum HookCopyRefresh {
    enum Outcome: Equatable {
        /// Buddy's hooks are not in the settings file, so there is no installed copy to keep current.
        case notInstalled
        /// This build has no embedded `buddy-hook` (a `swift run` build, or a damaged bundle).
        case noBundledHook
        /// Another Buddy is running (an older one, typically): it may still be using the installed copy, and the
        /// copy is refreshed the next time Buddy starts alone.
        case otherInstanceRunning
        /// The hooks in the settings run a `buddy-hook` from somewhere else, so the copy in Application Support is not
        /// the one in use and is left alone.
        case pointsElsewhere
        case upToDate
        case refreshed(path: String)
        case failed(String)

        /// The one line for Settings. Nil when there is nothing worth saying.
        var message: String? {
            switch self {
            case .notInstalled: nil
            case .noBundledHook: "This build of Buddy has no buddy-hook to refresh the installed copy with."
            case .otherInstanceRunning:
                "Another Buddy is running, so the installed buddy-hook was left alone. It is checked again the next time Buddy starts on its own."
            case .pointsElsewhere:
                "Buddy's hooks run a buddy-hook from another place, so the copy in Application Support was left alone. Press Install hooks to point them at it."
            case .upToDate: "The installed buddy-hook is up to date."
            case .refreshed(let path): "Updated the installed buddy-hook to match this version of Buddy (\(path))."
            case .failed(let reason): "Could not update the installed buddy-hook (\(reason)). Press Install hooks to retry."
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// True when the copy in `supportDirectory` is missing, not executable, quarantined (an earlier Buddy copied the
    /// download's flag along, so Gatekeeper blocks it), or not byte-for-byte `source`.
    static func needsRefresh(source: URL, supportDirectory: URL) -> Bool {
        let fm = FileManager.default
        let installed = HookBinaryInstaller.destination(in: supportDirectory)
        guard fm.isExecutableFile(atPath: installed.path) else { return true }
        guard !HookBinaryInstaller.isQuarantined(installed) else { return true }
        return !fm.contentsEqual(atPath: source.resolvingSymlinksInPath().path, andPath: installed.path)
    }

    /// True when at least one Buddy hook command in `settings` runs the copy in `supportDirectory`: the command is that
    /// path, bare or quoted, optionally followed by ` --ask`. False for no settings, unreadable JSON, or no such command.
    static func pointsAtSupportCopy(settings: Data?, supportDirectory: URL) -> Bool {
        guard let settings,
              let root = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any],
              let events = root["hooks"] as? [String: Any] else { return false }
        let path = HookBinaryInstaller.destination(in: supportDirectory).path
        let forms: Set<String> = [path, ClaudeSettingsInstaller.shellQuote(path), "\"\(path)\""]
        for case let groups as [Any] in events.values {
            for case let group as [String: Any] in groups {
                for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                    guard let command = hook["command"] as? String else { continue }
                    let base = command.hasSuffix(" --ask") ? String(command.dropLast(" --ask".count)) : command
                    if forms.contains(base) { return true }
                }
            }
        }
        return false
    }

    /// `hooksInstalled` and `entriesUseSupportCopy` are what the caller read from the settings file (see
    /// `pointsAtSupportCopy`); nothing here reads it again. `otherInstanceRunning`: another Buddy has the same
    /// bundle id, so it may be using the copy right now.
    static func run(
        hooksInstalled: Bool, entriesUseSupportCopy: Bool = true, otherInstanceRunning: Bool = false,
        source: URL?, supportDirectory: URL
    ) -> Outcome {
        guard hooksInstalled else { return .notInstalled }
        guard !otherInstanceRunning else { return .otherInstanceRunning }
        guard let source else { return .noBundledHook }
        guard entriesUseSupportCopy else { return .pointsElsewhere }
        guard needsRefresh(source: source, supportDirectory: supportDirectory) else { return .upToDate }
        do {
            let installed = try HookBinaryInstaller.install(source: source, into: supportDirectory)
            return .refreshed(path: installed.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
