import Foundation
import Testing
@testable import BuddyKit

@Suite struct ClaudeSettingsInstallerTests {
    private let command = "\"/Users/x/Library/Application Support/Buddy/bin/buddy-hook\""

    private func object(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        return try #require(obj as? [String: Any])
    }

    private func hooks(_ data: Data) throws -> [String: Any] {
        try #require(try object(data)["hooks"] as? [String: Any])
    }

    private func groups(_ data: Data, _ event: HookEventName) throws -> [[String: Any]] {
        try #require(try hooks(data)[event.rawValue] as? [[String: Any]])
    }

    private func isBuddy(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains("buddy-hook") == true
    }

    private func buddyHooks(_ data: Data, _ event: HookEventName) throws -> [[String: Any]] {
        try groups(data, event).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.filter(isBuddy)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func askGroup(_ data: Data) throws -> [String: Any]? {
        try groups(data, .preToolUse).first { $0["matcher"] as? String == "AskUserQuestion" }
    }

    /// PreToolUse carries the question hook and Stop the message hook, each next to the plain one.
    static func hasSecondHook(_ event: HookEventName) -> Bool { event == .preToolUse || event == .stop }

    @Test func stopGetsTheMessageHookThatOutlivesTenMinutesOfWaiting() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        let stops = try buddyHooks(plan.newData, .stop)
        #expect(stops.map { $0["command"] as? String } == [command, command + " --stop"])
        #expect(stops.map { $0["timeout"] as? Int } == [5, 620])
        #expect(Double(620) > HookClient.stopWaitTimeout && HookClient.stopWaitTimeout > BuddyEngine.stopHoldTimeout)
        #expect(ClaudeSettingsInstaller.status(existing: plan.newData) == .current)

        // An install from before messages existed is outdated, and installing again adds just the message hook.
        var root = try object(plan.newData)
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["Stop"] = (hooks["Stop"] as? [Any])?.filter { group in
            !(((group as? [String: Any])?["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.hasSuffix(" --stop") == true } ?? false)
        }
        root["hooks"] = hooks
        let old = try JSONSerialization.data(withJSONObject: root)
        #expect(ClaudeSettingsInstaller.status(existing: old) == .outdated)
        let again = try ClaudeSettingsInstaller.planInstall(existing: old, hookCommand: command)
        #expect(try buddyHooks(again.newData, .stop).count == 2)

        // Uninstalling removes both: nothing of Buddy's (here: nothing at all) is left.
        let removed = try ClaudeSettingsInstaller.planUninstall(existing: plan.newData)
        #expect(try object(removed.newData)["hooks"] == nil)
    }

    /// A fresh install with Buddy's AskUserQuestion group removed, as an earlier Buddy version wrote it.
    private func oldInstall() throws -> Data {
        let fresh = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        var root = try object(fresh.newData)
        var hooks = try #require(root["hooks"] as? [String: Any])
        let kept = try groups(fresh.newData, .preToolUse).filter { $0["matcher"] as? String != "AskUserQuestion" }
        hooks["PreToolUse"] = kept
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test func eventsAreAllTenHookEvents() {
        #expect(ClaudeSettingsInstaller.events.count == 12)
        #expect(Set(ClaudeSettingsInstaller.events.map(\.rawValue)).count == 12)
    }

    @Test func missingFileCreatesAllEventsOnce() throws {
        for existing in [nil, Data(), Data(" \n\t".utf8)] as [Data?] {
            let plan = try ClaudeSettingsInstaller.planInstall(existing: existing, hookCommand: command)
            #expect(plan.changed)
            for event in ClaudeSettingsInstaller.events {
                // PreToolUse carries the `*` hook and the AskUserQuestion hook.
                #expect(try buddyHooks(plan.newData, event).count == (Self.hasSecondHook(event) ? 2 : 1), "\(event)")
            }
        }
    }

    @Test func matcherOnlyOnToolEvents() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        let withMatcher: Set<HookEventName> = [.preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest]
        for event in ClaudeSettingsInstaller.events {
            let group = try #require(try groups(plan.newData, event).first)
            if withMatcher.contains(event) {
                #expect(group["matcher"] as? String == "*", "\(event)")
            } else {
                #expect(group["matcher"] == nil, "\(event)")
            }
        }
    }

    @Test func permissionRequestHasTimeout620OthersTimeout5() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        for event in ClaudeSettingsInstaller.events {
            let hook = try #require(try buddyHooks(plan.newData, event).first)
            #expect(hook["type"] as? String == "command")
            #expect(hook["command"] as? String == command)
            #expect(hook["timeout"] as? Int == (event == .permissionRequest ? 620 : 5), "\(event)")
        }
    }

    @Test func installIsIdempotent() throws {
        let first = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        let second = try ClaudeSettingsInstaller.planInstall(existing: first.newData, hookCommand: command)
        #expect(!second.changed)
        #expect(second.newData == first.newData)
        #expect(second.diff.isEmpty)
    }

    @Test func installUpdatesChangedCommandInPlaceWithoutDuplicating() throws {
        let first = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: "'/old/bin/buddy-hook'")
        let second = try ClaudeSettingsInstaller.planInstall(existing: first.newData, hookCommand: command)
        #expect(second.changed)
        for event in ClaudeSettingsInstaller.events {
            let buddy = try buddyHooks(second.newData, event)
            let expectedCount = Self.hasSecondHook(event) ? 2 : 1
            #expect(buddy.count == expectedCount)
            #expect(buddy.first?["command"] as? String == command)
            #expect(try groups(second.newData, event).count == expectedCount)
        }
        let ask = try #require(try askGroup(second.newData))
        #expect((ask["hooks"] as? [[String: Any]])?.first?["command"] as? String == command + " --ask")
    }

    @Test func preservesUnrelatedKeysAndForeignHooks() throws {
        let existing = json("""
        {
          "permissions": {"allow": ["Bash(ls)"]},
          "env": {"FOO": "bar"},
          "hooks": {
            "PermissionRequest": [
              {"matcher": "*", "hooks": [{"type": "command", "command": "/usr/local/bin/other-tool", "timeout": 30}]}
            ],
            "Stop": [
              {"hooks": [{"type": "command", "command": "/opt/notify.sh"}]}
            ]
          }
        }
        """)
        let plan = try ClaudeSettingsInstaller.planInstall(existing: existing, hookCommand: command)
        let root = try object(plan.newData)
        #expect((root["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
        #expect((root["env"] as? [String: String]) == ["FOO": "bar"])

        // Foreign entries stay first and untouched; Buddy's is appended in the same array.
        for (event, foreignCommand) in [(HookEventName.permissionRequest, "/usr/local/bin/other-tool"),
                                        (HookEventName.stop, "/opt/notify.sh")] {
            let gs = try groups(plan.newData, event)
            #expect(gs.count == (Self.hasSecondHook(event) ? 3 : 2), "\(event)")
            let foreign = try #require((gs[0]["hooks"] as? [[String: Any]])?.first)
            #expect(foreign["command"] as? String == foreignCommand)
            #expect(try buddyHooks(plan.newData, event).count == (Self.hasSecondHook(event) ? 2 : 1))
            let last = try #require((gs[1]["hooks"] as? [[String: Any]])?.first)
            #expect(isBuddy(last))
        }
        #expect(try groups(plan.newData, .permissionRequest)[0]["matcher"] as? String == "*")
        #expect(try groups(plan.newData, .permissionRequest)[0].count == 2)
    }

    @Test func hooksPresentButEmptyObjectIsFilled() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: json(#"{"hooks": {}, "env": {"A": "1"}}"#),
                                                           hookCommand: command)
        #expect(plan.changed)
        for event in ClaudeSettingsInstaller.events {
            #expect(try buddyHooks(plan.newData, event).count == (Self.hasSecondHook(event) ? 2 : 1), "\(event)")
        }
        #expect((try object(plan.newData)["env"] as? [String: String]) == ["A": "1"])
    }

    @Test func emptyObjectFileIsFilled() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: json("{}"), hookCommand: command)
        #expect(plan.changed)
        #expect(try buddyHooks(plan.newData, .stop).count == 2)
    }

    @Test func malformedJSONThrows() {
        let bad: [String] = [
            "{not json", "[]", "\"str\"", "42", "null",
            #"{"hooks": []}"#, #"{"hooks": "x"}"#, #"{"hooks": null}"#, #"{"hooks": {"Stop": {}}}"#,
            #"{"hooks": {"Stop": null}}"#,
        ]
        for text in bad {
            #expect(throws: InstallerError.malformedSettings, "\(text)") {
                _ = try ClaudeSettingsInstaller.planInstall(existing: Data(text.utf8), hookCommand: command)
            }
            #expect(throws: InstallerError.malformedSettings, "\(text)") {
                _ = try ClaudeSettingsInstaller.planUninstall(existing: Data(text.utf8))
            }
        }
    }

    @Test func malformedJSONThrowsAndNeverWrites() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let original = json("{ this is not json")
        try original.write(to: url)

        do {
            let plan = try ClaudeSettingsInstaller.planInstall(existing: original, hookCommand: command)
            try ClaudeSettingsInstaller.apply(plan, to: url, now: Date())
            Issue.record("expected malformedSettings")
        } catch let error as InstallerError {
            #expect(error == .malformedSettings)
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
    }

    @Test func commandWithSpacesIsQuoted() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        let hook = try #require(try buddyHooks(plan.newData, .sessionStart).first)
        #expect(hook["command"] as? String == "\"/Users/x/Library/Application Support/Buddy/bin/buddy-hook\"")
        // Reinstalling with the same quoted command recognises the entry (no duplicate).
        let again = try ClaudeSettingsInstaller.planInstall(existing: plan.newData, hookCommand: command)
        #expect(!again.changed)
    }

    @Test func shellQuoteEscapesEmbeddedQuotes() {
        #expect(ClaudeSettingsInstaller.shellQuote("/a b/buddy-hook") == "'/a b/buddy-hook'")
        #expect(ClaudeSettingsInstaller.shellQuote("/it's/buddy-hook") == #"'/it'\''s/buddy-hook'"#)
        // A quoted path with an embedded quote is still recognised as Buddy's.
        let quoted = ClaudeSettingsInstaller.shellQuote("/it's here/bin/buddy-hook")
        #expect(ClaudeSettingsInstaller.isBuddyCommand(quoted))
    }

    @Test func buddyCommandRecognition() {
        #expect(ClaudeSettingsInstaller.isBuddyCommand("/usr/local/bin/buddy-hook"))
        #expect(ClaudeSettingsInstaller.isBuddyCommand("\"/Users/x/Application Support/Buddy/bin/buddy-hook\""))
        #expect(ClaudeSettingsInstaller.isBuddyCommand("'/Users/x/App Support/buddy-hook' --flag"))
        #expect(ClaudeSettingsInstaller.isBuddyCommand("/Users/x/App\\ Support/buddy-hook"))
        #expect(!ClaudeSettingsInstaller.isBuddyCommand("/usr/local/bin/other-tool"))
        #expect(!ClaudeSettingsInstaller.isBuddyCommand("/usr/local/bin/not-buddy-hook"))
        #expect(!ClaudeSettingsInstaller.isBuddyCommand("/opt/tool --via /x/buddy-hook"))
        #expect(!ClaudeSettingsInstaller.isBuddyCommand(""))
    }

    @Test func uninstallRemovesOnlyBuddyEntriesAndPrunesEmptyArrays() throws {
        let existing = json("""
        {
          "env": {"FOO": "bar"},
          "hooks": {
            "PermissionRequest": [
              {"matcher": "*", "hooks": [{"type": "command", "command": "/usr/local/bin/other-tool", "timeout": 30}]}
            ]
          }
        }
        """)
        let installed = try ClaudeSettingsInstaller.planInstall(existing: existing, hookCommand: command)
        let plan = try ClaudeSettingsInstaller.planUninstall(existing: installed.newData)
        #expect(plan.changed)
        let hs = try hooks(plan.newData)
        #expect(hs.keys.sorted() == ["PermissionRequest"])
        let gs = try groups(plan.newData, .permissionRequest)
        #expect(gs.count == 1)
        #expect((gs[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/other-tool")
        #expect((try object(plan.newData)["env"] as? [String: String]) == ["FOO": "bar"])
    }

    @Test func uninstallDropsHooksKeyWhenNothingLeft() throws {
        let installed = try ClaudeSettingsInstaller.planInstall(existing: json(#"{"env": {"A": "1"}}"#),
                                                                hookCommand: command)
        let plan = try ClaudeSettingsInstaller.planUninstall(existing: installed.newData)
        #expect(plan.changed)
        let root = try object(plan.newData)
        #expect(root["hooks"] == nil)
        #expect((root["env"] as? [String: String]) == ["A": "1"])
    }

    @Test func uninstallLeavesUntouchedGroupsAndIsNoOpWithoutBuddy() throws {
        let existing = json(#"{"hooks": {"Stop": [], "Notification": [{"hooks": [{"type": "command", "command": "x"}]}]}}"#)
        let plan = try ClaudeSettingsInstaller.planUninstall(existing: existing)
        #expect(!plan.changed)
        #expect(plan.diff.isEmpty)
        #expect(plan.newData == existing)

        let missing = try ClaudeSettingsInstaller.planUninstall(existing: nil)
        #expect(!missing.changed)
    }

    @Test func uninstallKeepsForeignHookSharingGroupWithBuddy() throws {
        let existing = json("""
        {"hooks": {"Stop": [{"hooks": [
          {"type": "command", "command": "/opt/a.sh"},
          {"type": "command", "command": "/x/buddy-hook", "timeout": 5}
        ]}]}}
        """)
        let plan = try ClaudeSettingsInstaller.planUninstall(existing: existing)
        #expect(plan.changed)
        let gs = try groups(plan.newData, .stop)
        #expect(gs.count == 1)
        let hs = try #require(gs[0]["hooks"] as? [[String: Any]])
        #expect(hs.count == 1)
        #expect(hs[0]["command"] as? String == "/opt/a.sh")
    }

    @Test func diffListsAddedLines() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: json(#"{"env": {"A": "1"}}"#),
                                                           hookCommand: command)
        let lines = plan.diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains { $0.hasPrefix("+ ") && $0.contains("\"PermissionRequest\"") })
        #expect(lines.contains { $0.hasPrefix("+ ") && $0.contains("buddy-hook") })
        #expect(!lines.contains { $0.hasPrefix("- ") })
    }

    @Test func diffListsRemovedLinesOnUninstall() throws {
        let installed = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        let plan = try ClaudeSettingsInstaller.planUninstall(existing: installed.newData)
        let lines = plan.diff.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("- ") && $0.contains("buddy-hook") })
        #expect(!lines.contains { $0.hasPrefix("+ ") && $0.contains("buddy-hook") })
    }

    @Test func applyWritesTimestampedBackupWithOriginalContent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let original = json(#"{"env": {"A": "1"}}"#)
        try original.write(to: url)

        let plan = try ClaudeSettingsInstaller.planInstall(existing: original, hookCommand: command)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try ClaudeSettingsInstaller.apply(plan, to: url, now: now)

        #expect(try Data(contentsOf: url) == plan.newData)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let backups = names.filter { $0.hasPrefix("settings.json.buddy-backup-") }
        #expect(backups.count == 1)
        #expect(names.count == 2)
        let stamp = String(try #require(backups.first).dropFirst("settings.json.buddy-backup-".count))
        #expect(stamp.count == 15)  // yyyyMMdd-HHmmss
        #expect(stamp.contains("-"))
        #expect(try Data(contentsOf: dir.appendingPathComponent(try #require(backups.first))) == original)

        // Same timestamp again must never overwrite the earlier backup.
        let second = try ClaudeSettingsInstaller.planUninstall(existing: plan.newData)
        try ClaudeSettingsInstaller.apply(second, to: url, now: now)
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.json.buddy-backup-") }
        #expect(after.count == 2)
        #expect(try Data(contentsOf: dir.appendingPathComponent(try #require(backups.first))) == original)
    }

    @Test func backupNameFormat() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try json(#"{"env": {"A": "1"}}"#).write(to: url)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "settings.json.buddy-backup-" + formatter.string(from: now)

        func backups() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".buddy-backup-") })
        }
        let install = try ClaudeSettingsInstaller.planInstall(existing: try Data(contentsOf: url), hookCommand: command)
        try ClaudeSettingsInstaller.apply(install, to: url, now: now)
        #expect(try backups() == [base])

        // The same second again: a numeric suffix, never a second write to the first backup.
        let uninstall = try ClaudeSettingsInstaller.planUninstall(existing: try Data(contentsOf: url))
        try ClaudeSettingsInstaller.apply(uninstall, to: url, now: now)
        #expect(try backups() == [base, base + "-1"])
        let reinstall = try ClaudeSettingsInstaller.planInstall(existing: try Data(contentsOf: url), hookCommand: command)
        try ClaudeSettingsInstaller.apply(reinstall, to: url, now: now)
        #expect(try backups() == [base, base + "-1", base + "-2"])
    }

    @Test func applyCreatesMissingFileAndParentDirectoryWithoutBackup() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/.claude/settings.json")
        let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        try ClaudeSettingsInstaller.apply(plan, to: url, now: Date())
        #expect(try Data(contentsOf: url) == plan.newData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            == ["settings.json"])
    }

    @Test func applyWithNoChangeWritesNothing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let installed = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        try installed.newData.write(to: url)

        let plan = try ClaudeSettingsInstaller.planInstall(existing: installed.newData, hookCommand: command)
        #expect(!plan.changed)
        try ClaudeSettingsInstaller.apply(plan, to: url, now: Date())
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
        #expect(try Data(contentsOf: url) == installed.newData)

        // And with no file at all: nothing is created.
        let missing = dir.appendingPathComponent("absent/settings.json")
        let noop = try ClaudeSettingsInstaller.planUninstall(existing: nil)
        try ClaudeSettingsInstaller.apply(noop, to: missing, now: Date())
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    @Test func applyFailureIsSurfacedAndLeavesOriginalIntact() throws {
        let dir = try tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("settings.json")
        let original = json(#"{"env": {"A": "1"}}"#)
        try original.write(to: url)
        let plan = try ClaudeSettingsInstaller.planInstall(existing: original, hookCommand: command)

        // Read-only directory: the backup cannot be created, so apply must throw and not touch the file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) {
            try ClaudeSettingsInstaller.apply(plan, to: url, now: Date())
        }
        #expect(try Data(contentsOf: url) == original)
    }

    // MARK: - AskUserQuestion group and install status

    @Test func installAddsAskGroup() throws {
        let plan = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        let ask = try #require(try askGroup(plan.newData))
        let expected: [String: Any] = [
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": command + " --ask", "timeout": 620] as [String: Any]],
        ]
        #expect(NSDictionary(dictionary: ask).isEqual(to: expected))
        // The `*` group is separate and keeps the plain command.
        let star = try #require(try groups(plan.newData, .preToolUse).first { $0["matcher"] as? String == "*" })
        let starHook = try #require((star["hooks"] as? [[String: Any]])?.first)
        #expect(starHook["command"] as? String == command)
        #expect(starHook["timeout"] as? Int == 5)
        #expect(try groups(plan.newData, .preToolUse).count == 2)
    }

    @Test func installOnOldInstallUpgrades() throws {
        let old = try oldInstall()
        #expect(try askGroup(old) == nil)
        let upgrade = try ClaudeSettingsInstaller.planInstall(existing: old, hookCommand: command)
        #expect(upgrade.changed)
        #expect(try askGroup(upgrade.newData) != nil)
        #expect(try groups(upgrade.newData, .preToolUse).count == 2)
        let again = try ClaudeSettingsInstaller.planInstall(existing: upgrade.newData, hookCommand: command)
        #expect(!again.changed)
        #expect(again.diff.isEmpty)
    }

    @Test func installRewritesPermissionRequestTimeout60() throws {
        var root = try object(try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command).newData)
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["PermissionRequest"] = [["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 60]]]]
        root["hooks"] = hooks
        let stale = try JSONSerialization.data(withJSONObject: root)

        let plan = try ClaudeSettingsInstaller.planInstall(existing: stale, hookCommand: command)
        #expect(plan.changed)
        #expect(try buddyHooks(plan.newData, .permissionRequest).first?["timeout"] as? Int == 620)
    }

    @Test func installRewritesTwoMinuteTimeoutsOfThePreviousVersion() throws {
        var root = try object(try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command).newData)
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["PermissionRequest"] = [["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 120]]]]
        hooks["PreToolUse"] = [
            ["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 5]]],
            ["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": command + " --ask", "timeout": 130]]],
        ]
        root["hooks"] = hooks
        let stale = try JSONSerialization.data(withJSONObject: root)

        let plan = try ClaudeSettingsInstaller.planInstall(existing: stale, hookCommand: command)
        #expect(plan.changed)
        #expect(try buddyHooks(plan.newData, .permissionRequest).first?["timeout"] as? Int == 620)
        let ask = try #require(try askGroup(plan.newData))
        #expect((ask["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 620)
    }

    @Test func installRepairsDuplicateAskHooks() throws {
        let installed = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        var root = try object(installed.newData)
        var hooks = try #require(root["hooks"] as? [String: Any])
        var pre = try groups(installed.newData, .preToolUse)
        pre.append(try #require(try askGroup(installed.newData)))
        hooks["PreToolUse"] = pre
        root["hooks"] = hooks
        let doubled = try JSONSerialization.data(withJSONObject: root)

        let plan = try ClaudeSettingsInstaller.planInstall(existing: doubled, hookCommand: command)
        #expect(plan.changed)
        #expect(try groups(plan.newData, .preToolUse).count == 2)
        #expect(try ClaudeSettingsInstaller.planInstall(existing: plan.newData, hookCommand: command).changed == false)
    }

    private let foreignAsk = """
    {"hooks": {"PreToolUse": [
      {"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": "other-tool", "timeout": 9}]}
    ]}}
    """

    @Test func othersAskGroupUntouched() throws {
        let foreignGroup: [String: Any] = [
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "other-tool", "timeout": 9] as [String: Any]],
        ]
        let installed = try ClaudeSettingsInstaller.planInstall(existing: json(foreignAsk), hookCommand: command)
        let afterInstall = try groups(installed.newData, .preToolUse)
        #expect(afterInstall.count == 3)
        #expect(NSDictionary(dictionary: afterInstall[0]).isEqual(to: foreignGroup))
        let buddyAsk = afterInstall.filter {
            ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == command + " --ask"
        }
        #expect(buddyAsk.count == 1)

        let removed = try ClaudeSettingsInstaller.planUninstall(existing: installed.newData)
        let afterUninstall = try groups(removed.newData, .preToolUse)
        #expect(afterUninstall.count == 1)
        #expect(NSDictionary(dictionary: afterUninstall[0]).isEqual(to: foreignGroup))
    }

    @Test func uninstallRemovesAskGroup() throws {
        let installed = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command)
        let plan = try ClaudeSettingsInstaller.planUninstall(existing: installed.newData)
        #expect(plan.changed)
        #expect(try object(plan.newData)["hooks"] == nil)
        #expect(plan.diff.contains("- ") && plan.diff.contains("AskUserQuestion"))  // the diff shows the removed group
    }

    @Test func statusValues() throws {
        let status = ClaudeSettingsInstaller.status(existing:)
        #expect(status(nil) == .notInstalled)
        #expect(status(Data()) == .notInstalled)
        #expect(status(json("{}")) == .notInstalled)
        #expect(status(json("{not json")) == .notInstalled)
        #expect(status(json(#"{"hooks": {"Stop": "x"}}"#)) == .notInstalled)
        #expect(status(json(foreignAsk)) == .notInstalled)

        #expect(status(try oldInstall()) == .outdated)

        let fresh = try ClaudeSettingsInstaller.planInstall(existing: nil, hookCommand: command).newData
        #expect(status(fresh) == .current)

        var root = try object(fresh)
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["PermissionRequest"] = [["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 60]]]]
        root["hooks"] = hooks
        #expect(status(try JSONSerialization.data(withJSONObject: root)) == .outdated)
    }

    @Test func statusIsCurrentWithForeignHooksAlongside() throws {
        let installed = try ClaudeSettingsInstaller.planInstall(existing: json(foreignAsk), hookCommand: command)
        #expect(ClaudeSettingsInstaller.status(existing: installed.newData) == .current)
    }
}
