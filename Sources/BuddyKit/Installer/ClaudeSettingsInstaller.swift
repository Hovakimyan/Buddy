#if os(macOS)
import Foundation

/// The outcome of planning an install or uninstall against a Claude settings file. Nothing is
/// written until the plan is passed to `ClaudeSettingsInstaller.apply`.
public struct InstallPlan: Sendable {
    /// The full settings file content after the change (the existing content when `changed` is false).
    public let newData: Data
    /// Line diff of the pretty-printed before/after text: `+ ` added, `- ` removed. Empty when unchanged.
    public let diff: String
    public let changed: Bool

    public init(newData: Data, diff: String, changed: Bool) {
        self.newData = newData
        self.diff = diff
        self.changed = changed
    }
}

/// How the hooks in a settings file compare with what this version of Buddy would install.
public enum HookInstallStatus: Sendable, Equatable {
    /// No Buddy hook entry at all (or the file is empty or unreadable).
    case notInstalled
    /// Buddy entries exist but an install would change them (for example a missing question hook).
    case outdated
    /// An install would change nothing.
    case current
}

public enum InstallerError: Error, Equatable {
    /// The settings file is not a JSON object, or `hooks` (or one of its event entries) has the wrong type.
    case malformedSettings
}

/// Merges Buddy's hook entries into (and removes them from) Claude Code's `settings.json`.
/// Entries belonging to other tools, and all unrelated settings, are left untouched.
public enum ClaudeSettingsInstaller {
    public static let events: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .notification, .stop, .stopFailure, .sessionEnd, .permissionRequest, .subagentStart, .subagentStop,
    ]

    /// Events whose hook group carries `"matcher": "*"`.
    private static let matcherEvents: Set<HookEventName> = [
        .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest,
    ]

    private static let hookExecutableName = "buddy-hook"
    /// The relay waits up to 610 s for a human decision, so the permission hook must outlive that.
    private static let permissionTimeout = 620
    private static let defaultTimeout = 5
    /// The question hook's relay waits up to 610 s for an answer, so its hook must outlive that.
    private static let askTimeout = 620
    private static let askMatcher = "AskUserQuestion"
    private static let askFlag = " --ask"

    // MARK: - Planning

    /// `hookCommand` is the already shell-quoted command line and is written verbatim.
    public static func planInstall(existing: Data?, hookCommand: String) throws -> InstallPlan {
        var root = try parse(existing)
        var hooks = try hooksObject(of: root)

        for event in events {
            let current = try eventGroups(hooks[event.rawValue])
            var installed = install(into: current, event: event, hookCommand: hookCommand)
            if event == .preToolUse {
                installed = installAsk(into: installed, hookCommand: hookCommand)
            }
            hooks[event.rawValue] = installed
        }
        root["hooks"] = hooks
        return try makePlan(existing: existing, newRoot: root)
    }

    /// Compares `existing` with what `planInstall` would write. Unreadable or malformed content counts as
    /// not installed (installing would refuse it anyway).
    public static func status(existing: Data?) -> HookInstallStatus {
        guard let root = try? parse(existing), let hooks = try? hooksObject(of: root) else { return .notInstalled }
        var commands: [String] = []
        for event in events {
            guard let groups = try? eventGroups(hooks[event.rawValue]) else { return .notInstalled }
            for case let group as [String: Any] in groups {
                for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                    if let command = hook["command"] as? String, isBuddyCommand(command) { commands.append(command) }
                }
            }
        }
        // Reinstall with Buddy's own recorded command, so only structure, timeouts and missing groups differ.
        guard let command = commands.first(where: { !isAskCommand($0) }) ?? commands.first.map(askBase) else {
            return .notInstalled
        }
        guard let plan = try? planInstall(existing: existing, hookCommand: command) else { return .notInstalled }
        return plan.changed ? .outdated : .current
    }

    public static func planUninstall(existing: Data?) throws -> InstallPlan {
        var root = try parse(existing)
        var hooks = try hooksObject(of: root)

        var removedAny = false
        for event in events {
            guard hooks[event.rawValue] != nil else { continue }
            let current = try eventGroups(hooks[event.rawValue])
            let stripped = strip(current, keeping: nil)
            guard stripped.removed else { continue }
            removedAny = true
            if stripped.groups.isEmpty {
                hooks[event.rawValue] = nil
            } else {
                hooks[event.rawValue] = stripped.groups
            }
        }
        if removedAny {
            if hooks.isEmpty {
                root["hooks"] = nil
            } else {
                root["hooks"] = hooks
            }
        }
        return try makePlan(existing: existing, newRoot: root)
    }

    // MARK: - Applying

    /// Writes the plan to `settingsURL`. A plan with `changed == false` writes nothing at all. Otherwise an
    /// existing file is first copied to `<name>.buddy-backup-<yyyyMMdd-HHmmss>` (never overwriting an
    /// earlier backup) and then replaced atomically. Backup or write failures are thrown; the original is
    /// never touched if the backup fails.
    public static func apply(_ plan: InstallPlan, to settingsURL: URL, now: Date) throws {
        guard plan.changed else { return }
        let fm = FileManager.default
        // Write through a symlinked settings.json rather than replacing the link.
        let target = settingsURL.resolvingSymlinksInPath()

        let originalAttributes: [FileAttributeKey: Any]?
        if fm.fileExists(atPath: target.path) {
            originalAttributes = try fm.attributesOfItem(atPath: target.path)
            try fm.copyItem(at: target, to: backupURL(for: target, now: now))
        } else {
            originalAttributes = nil
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        try plan.newData.write(to: target, options: .atomic)
        if let permissions = originalAttributes?[.posixPermissions] as? NSNumber {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    /// `<name>.buddy-backup-<yyyyMMdd-HHmmss>` next to `url`, in local time. When that name is taken (two writes in
    /// the same second), `-1`, `-2`, … is appended until a free name is found.
    private static func backupURL(for url: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        // A fixed-format stamp: the POSIX locale keeps the digits and calendar independent of the person's settings.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.lastPathComponent + ".buddy-backup-" + formatter.string(from: now)
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(base)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    // MARK: - Command handling

    /// Single-quotes `path` for a POSIX shell, escaping embedded single quotes.
    public static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True when the first shell word of `command` is a path whose last component is `buddy-hook`.
    public static func isBuddyCommand(_ command: String) -> Bool {
        guard let word = firstShellWord(command), !word.isEmpty else { return false }
        return URL(fileURLWithPath: word).lastPathComponent == hookExecutableName
    }

    /// The first word of a POSIX-style command line, with quoting and backslash escapes resolved.
    private static func firstShellWord(_ command: String) -> String? {
        var word = ""
        var started = false
        var quote: Character?
        var escaping = false
        for ch in command {
            if escaping {
                word.append(ch)
                escaping = false
            } else if quote == "'" {
                if ch == "'" { quote = nil } else { word.append(ch) }
            } else if quote == "\"" {
                if ch == "\"" {
                    quote = nil
                } else if ch == "\\" {
                    escaping = true
                } else {
                    word.append(ch)
                }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                started = true
            } else if ch == "\\" {
                escaping = true
                started = true
            } else if ch.isWhitespace {
                if started { break }
            } else {
                word.append(ch)
                started = true
            }
        }
        return started ? word : nil
    }

    // MARK: - Merge helpers

    private static func isBuddyHook(_ hook: Any) -> Bool {
        guard let dict = hook as? [String: Any], let command = dict["command"] as? String else { return false }
        return isBuddyCommand(command)
    }

    private static func isAskCommand(_ command: String) -> Bool {
        command.hasSuffix(askFlag) && isBuddyCommand(askBase(command))
    }

    /// `command` without its trailing ` --ask`.
    private static func askBase(_ command: String) -> String {
        command.hasSuffix(askFlag) ? String(command.dropLast(askFlag.count)) : command
    }

    /// Buddy's question hook: a Buddy command ending in ` --ask`.
    private static func isBuddyAskHook(_ hook: Any) -> Bool {
        guard let dict = hook as? [String: Any], let command = dict["command"] as? String else { return false }
        return isAskCommand(command)
    }

    /// Buddy's ordinary hook: any Buddy command that is not the question hook.
    private static func isPlainBuddyHook(_ hook: Any) -> Bool {
        isBuddyHook(hook) && !isBuddyAskHook(hook)
    }

    private static func install(into groups: [Any], event: HookEventName, hookCommand: String) -> [Any] {
        let timeout = event == .permissionRequest ? permissionTimeout : defaultTimeout
        let entry: [String: Any] = ["type": "command", "command": hookCommand, "timeout": timeout]
        let matcher: String? = matcherEvents.contains(event) ? "*" : nil
        return merge(entry, matcher: matcher, into: groups, isMine: isPlainBuddyHook)
    }

    /// Adds (or updates in place) Buddy's `AskUserQuestion` group next to the `*` group.
    private static func installAsk(into groups: [Any], hookCommand: String) -> [Any] {
        let entry: [String: Any] = ["type": "command", "command": hookCommand + askFlag, "timeout": askTimeout]
        return merge(entry, matcher: askMatcher, into: groups, isMine: isBuddyAskHook)
    }

    /// Updates the first existing hook matching `isMine` in place and drops further (duplicate) ones; with none
    /// present, appends a new group. Hooks `isMine` does not match are never touched.
    private static func merge(
        _ entry: [String: Any], matcher: String?, into groups: [Any], isMine: (Any) -> Bool
    ) -> [Any] {
        for (groupIndex, group) in groups.enumerated() {
            guard var groupDict = group as? [String: Any], var hooks = groupDict["hooks"] as? [Any],
                  let hookIndex = hooks.firstIndex(where: isMine),
                  var hook = hooks[hookIndex] as? [String: Any] else { continue }
            for (key, value) in entry { hook[key] = value }
            hooks[hookIndex] = hook
            groupDict["hooks"] = hooks
            if let matcher, groupDict["matcher"] == nil, hooks.allSatisfy(isBuddyHook) {
                groupDict["matcher"] = matcher
            }
            var updated = groups
            updated[groupIndex] = groupDict
            return strip(updated, keeping: (groupIndex, hookIndex), isMine: isMine).groups
        }

        var newGroup: [String: Any] = ["hooks": [entry]]
        if let matcher { newGroup["matcher"] = matcher }
        return groups + [newGroup]
    }

    /// Removes Buddy hooks (except the one at `keeping`) and prunes groups that this left empty. Groups
    /// that held no Buddy hook are returned untouched, even if they were already empty.
    private static func strip(
        _ groups: [Any], keeping: (group: Int, hook: Int)?, isMine: (Any) -> Bool = isBuddyHook
    ) -> (groups: [Any], removed: Bool) {
        var result: [Any] = []
        var removed = false
        for (groupIndex, group) in groups.enumerated() {
            guard var groupDict = group as? [String: Any], let hooks = groupDict["hooks"] as? [Any] else {
                result.append(group)
                continue
            }
            var kept: [Any] = []
            var removedHere = false
            for (hookIndex, hook) in hooks.enumerated() {
                if isMine(hook), keeping.map({ $0 != (groupIndex, hookIndex) }) ?? true {
                    removedHere = true
                } else {
                    kept.append(hook)
                }
            }
            guard removedHere else {
                result.append(group)
                continue
            }
            removed = true
            if !kept.isEmpty {
                groupDict["hooks"] = kept
                result.append(groupDict)
            }
        }
        return (result, removed)
    }

    // MARK: - Parsing and output

    /// The settings file as a JSON object. No file, an empty file or one holding only whitespace is an empty object;
    /// anything that is not a JSON object is refused.
    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, hasContent(data) else { return [:] }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw InstallerError.malformedSettings
        }
        guard let object = value as? [String: Any] else { throw InstallerError.malformedSettings }
        return object
    }

    /// `root["hooks"]`: empty when the key is missing, refused when it is not an object (never replaced).
    private static func hooksObject(of root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw InstallerError.malformedSettings }
        return hooks
    }

    /// One event's list of hook groups: empty when the event is missing, refused when it is not an array.
    private static func eventGroups(_ value: Any?) throws -> [Any] {
        guard let value else { return [] }
        guard let groups = value as? [Any] else { throw InstallerError.malformedSettings }
        return groups
    }

    private static func prettyText(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func makePlan(existing: Data?, newRoot: [String: Any]) throws -> InstallPlan {
        let oldRoot = try parse(existing)
        // Compare structurally so key order or whitespace differences alone never count as a change.
        guard !NSDictionary(dictionary: oldRoot).isEqual(to: newRoot) else {
            return InstallPlan(newData: existing ?? Data(), diff: "", changed: false)
        }
        let oldLines = hasContent(existing) ? try prettyText(oldRoot).components(separatedBy: "\n") : []
        let newText = try prettyText(newRoot)
        return InstallPlan(
            newData: Data((newText + "\n").utf8),
            diff: lineDiff(from: oldLines, to: newText.components(separatedBy: "\n")),
            changed: true)
    }

    private static func hasContent(_ data: Data?) -> Bool {
        guard let data else { return false }
        return !data.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    }

    /// Changed lines only, in file order: `- ` for removed, `+ ` for added.
    private static func lineDiff(from old: [String], to new: [String]) -> String {
        let difference = new.difference(from: old)
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var out: [String] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removals.contains(i) {
                out.append("- " + old[i])
                i += 1
            } else if j < new.count, insertions.contains(j) {
                out.append("+ " + new[j])
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return out.joined(separator: "\n")
    }
}

#endif
