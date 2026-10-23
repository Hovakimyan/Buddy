import Foundation
import Testing
@testable import BuddyKit

/// Runs the real `buddy-hook` executable the way Claude Code does: JSON on stdin, `BUDDY_SOCKET`
/// pointing at the server under test.
@Suite struct BuddyHookProcessTests {
    private func runHook(stdin: Data, socket: URL) async throws -> HookProcess.Result {
        await HookProcess.run(stdin: stdin, socket: socket)
    }

    private func tempSocketURL() -> URL { HookProcess.tempSocketURL() }

    private let permissionRequest = Data(
        #"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)

    @Test func printsAllowJSONWhenServerAllows() async throws {
        let path = tempSocketURL()
        let server = HookSocketServer(path: path, handler: { _ in .decision(.allow) })
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: path)
        }
        let result = try await runHook(stdin: permissionRequest, socket: path)
        #expect(result.status == 0)
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
    }

    @Test func printsNothingAndExitsZeroWhenNoServer() async throws {
        let result = try await runHook(stdin: permissionRequest, socket: tempSocketURL())
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        // Wall clock here includes spawning the process (dyld, runtime start-up), which can take
        // several seconds on a cold build or while the machine runs the rest of the suite, so
        // this is only a "does not hang" bound (the real hang would be the 110 s reply wait).
        // The strict "well inside 300 ms" property is pinned in-process by
        // `HookSocketTests.noServerReturnsNilWithin300ms`, which times `HookClient.run` alone.
        #expect(result.elapsed < 10)
    }

    @Test func printsNothingOnEmptyStdin() async throws {
        let path = tempSocketURL()
        let server = HookSocketServer(path: path, handler: { _ in .decision(.allow) })
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: path)
        }
        let result = try await runHook(stdin: Data(), socket: path)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func askProcessPrintsNothingWithoutApp() async throws {
        let ask = Data(
            #"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#.utf8)
        let result = await HookProcess.run(stdin: ask, socket: tempSocketURL(), arguments: ["--ask"])
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.elapsed < 1)
    }
}
