import Foundation
import Testing
@testable import BuddyKit

@Suite struct HookEventTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func parsesPermissionRequest() {
        let payload = """
        {"session_id":"abc","cwd":"/Users/me/proj","hook_event_name":"PermissionRequest",
         "tool_name":"Bash","tool_input":{"command":"ls"}}
        """
        let event = HookEvent.parse(data(payload))
        #expect(event?.sessionId == "abc")
        #expect(event?.name == .permissionRequest)
        #expect(event?.cwd == "/Users/me/proj")
        #expect(event?.toolName == "Bash")
        #expect(event?.toolInput == .object(["command": .string("ls")]))
        #expect(event?.message == nil)
    }

    @Test func parsesTheSubagentId() {
        let payload = """
        {"session_id":"abc","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{},
         "agent_id":"agent-7","agent_type":"Explore"}
        """
        #expect(HookEvent.parse(data(payload))?.agentId == "agent-7")
        #expect(HookEvent.parse(data(#"{"session_id":"abc","hook_event_name":"Stop"}"#))?.agentId == nil)
        // An agent_id of another type is ignored, never a reason to drop the event.
        let odd = HookEvent.parse(data(#"{"session_id":"abc","hook_event_name":"Stop","agent_id":7}"#))
        #expect(odd?.name == .stop)
        #expect(odd?.agentId == nil)
    }

    @Test func buddyAskParsed() {
        func parse(_ extra: String) -> HookEvent? {
            HookEvent.parse(data(#"{"session_id":"abc","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"\#(extra)}"#))
        }
        #expect(parse(#","buddy_ask":true"#)?.isAsk == true)
        #expect(parse(#","buddy_ask":true"#)?.waitsForReply == true)
        #expect(parse(#","buddy_ask":"yes""#)?.isAsk == false)
        #expect(parse(#","buddy_ask":1"#)?.isAsk == false)
        #expect(parse(#","buddy_ask":false"#)?.isAsk == false)
        #expect(parse("")?.isAsk == false)
        #expect(parse("")?.waitsForReply == false)
        #expect(HookEvent(sessionId: "s", name: .permissionRequest).waitsForReply)
        #expect(!HookEvent(sessionId: "s", name: .stop).waitsForReply)
    }

    @Test func parsesNotificationMessage() {
        let payload = """
        {"session_id":"abc","hook_event_name":"Notification","message":"Claude needs your permission"}
        """
        let event = HookEvent.parse(data(payload))
        #expect(event?.name == .notification)
        #expect(event?.message == "Claude needs your permission")
        #expect(event?.cwd == nil)
        #expect(event?.toolName == nil)
        #expect(event?.toolInput == nil)
    }

    @Test func parsesNotificationType() {
        let payload = """
        {"session_id":"abc","hook_event_name":"Notification","message":"Claude is waiting for your input",
         "notification_type":"idle_prompt"}
        """
        let event = HookEvent.parse(data(payload))
        #expect(event?.notificationType == "idle_prompt")
        #expect(event?.isIdlePrompt == true)
        #expect(HookEvent.parse(data(#"{"session_id":"abc","hook_event_name":"Notification"}"#))?.notificationType == nil)
    }

    @Test func idlePromptIsTheTypeOrTheIdleMessageWhenThereIsNoType() {
        func notification(_ type: String?, _ message: String?) -> HookEvent {
            HookEvent(sessionId: "s", name: .notification, message: message, notificationType: type)
        }
        #expect(notification("idle_prompt", nil).isIdlePrompt)
        #expect(notification(nil, "Claude is waiting for your input").isIdlePrompt)
        #expect(notification(nil, "Claude is Waiting for your input!").isIdlePrompt)
        #expect(!notification("permission_prompt", "Claude is waiting for your input").isIdlePrompt)
        #expect(!notification(nil, "Claude needs your permission to use Bash").isIdlePrompt)
        #expect(!notification(nil, nil).isIdlePrompt)
        #expect(!notification("auth_success", nil).isIdlePrompt)
        #expect(!HookEvent(sessionId: "s", name: .stop, notificationType: "idle_prompt").isIdlePrompt)
    }

    // The session id becomes a CloudKit record name, which raises an exception (a crash) when it is
    // empty, not ASCII, longer than 255 characters or starts with "_".
    @Test func rejectsSessionIdsThatCannotBeARecordName() {
        func parse(_ id: String) -> HookEvent? {
            let payload: JSONValue = .object(["session_id": .string(id), "hook_event_name": .string("Stop")])
            return HookEvent.parse(try! JSONEncoder().encode(payload))
        }
        for id in [
            "", "_private", "_", "é", "s\u{0}1", "a\nb", "tab\there", "del\u{7F}", "session-\u{202E}", "😀",
            String(repeating: "a", count: 201), String(repeating: "a", count: 300),
        ] {
            #expect(parse(id) == nil, "\(id.debugDescription)")
        }
        for id in [
            "123e4567-e89b-12d3-a456-426614174000", UUID().uuidString.lowercased(), "s1", "a_b", "a b",
            String(repeating: "a", count: 200),
        ] {
            #expect(parse(id)?.sessionId == id, "\(id.debugDescription)")
        }
    }

    @Test func rejectsMalformedJSON() {
        #expect(HookEvent.parse(data("{not json")) == nil)
        #expect(HookEvent.parse(Data()) == nil)
    }

    @Test func rejectsMissingSessionId() {
        #expect(HookEvent.parse(data(#"{"hook_event_name":"Stop"}"#)) == nil)
    }

    @Test func rejectsUnknownEventName() {
        #expect(HookEvent.parse(data(#"{"session_id":"abc","hook_event_name":"Bogus"}"#)) == nil)
    }

    @Test func rejectsPayloadOver4MiB() {
        let limit = 4 * 1024 * 1024
        let prefix = #"{"session_id":"abc","hook_event_name":"Stop","pad":""#
        let suffix = #""}"#
        func payload(totalSize: Int) -> Data {
            let padding = String(repeating: "x", count: totalSize - prefix.utf8.count - suffix.utf8.count)
            return Data((prefix + padding + suffix).utf8)
        }
        #expect(HookEvent.parse(payload(totalSize: limit)) != nil)
        #expect(HookEvent.parse(payload(totalSize: limit + 1)) == nil)
    }

    // MARK: nesting depth

    private func nestedArrays(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }

    private func payload(toolInput: String) -> Data {
        Data(#"{"session_id":"abc","hook_event_name":"PreToolUse","tool_input":\#(toolInput)}"#.utf8)
    }

    @Test func rejectsDeeplyNestedToolInput() {
        let input = payload(toolInput: nestedArrays(300))
        let clock = ContinuousClock()
        var event: HookEvent?
        let elapsed = clock.measure { event = HookEvent.parse(input) }
        #expect(event == nil)
        #expect(elapsed < .seconds(1))
    }

    @Test func rejectsManyDeeplyNestedArraysPayload() {
        let arrays = Array(repeating: nestedArrays(500), count: 40).joined(separator: ",")
        let input = payload(toolInput: "[\(arrays)]")
        #expect(input.count > 40_000)
        let clock = ContinuousClock()
        var event: HookEvent?
        let elapsed = clock.measure { event = HookEvent.parse(input) }
        #expect(event == nil)
        #expect(elapsed < .seconds(1))
    }

    @Test func acceptsModerateNesting() {
        let depth = 10
        var json = #""leaf""#
        var expected = JSONValue.string("leaf")
        for _ in 0..<depth {
            json = "{\"edits\":[\(json)]}"
            expected = .object(["edits": .array([expected])])
        }
        let event = HookEvent.parse(payload(toolInput: json))
        #expect(event?.toolInput == expected)
    }
}
