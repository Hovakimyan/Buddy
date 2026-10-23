import Foundation
import Testing
@testable import BuddyKit

@Suite struct HookOutputTests {
    private func parse(_ s: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8))
        return try #require(obj as? [String: Any])
    }

    @Test func allowIsExactJSON() throws {
        let out = try #require(HookOutput.stdout(for: .decision(.allow), event: permissionEvent))
        let json = try parse(out)
        #expect(json.count == 1)
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(specific.count == 2)
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision.count == 1)
        #expect(decision["behavior"] as? String == "allow")
    }

    @Test func denyHasBehaviorDenyAndMessage() throws {
        let out = try #require(HookOutput.stdout(for: .decision(.deny), event: permissionEvent))
        let json = try parse(out)
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        let message = try #require(decision["message"] as? String)
        #expect(!message.isEmpty)
        #expect(message == "Denied from Buddy")
    }

    @Test func allowAndDenyUnchanged() {
        #expect(
            HookOutput.stdout(for: .decision(.allow), event: permissionEvent)
                == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        #expect(
            HookOutput.stdout(for: .decision(.deny), event: permissionEvent)
                == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Buddy"}}}"#)
    }

    @Test func planAcceptEdits() {
        #expect(
            HookOutput.stdout(for: .plan(.acceptEdits), event: permissionEvent)
                == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}}"#)
    }

    @Test func planAskEachTime() {
        #expect(
            HookOutput.stdout(for: .plan(.askEachTime), event: permissionEvent)
                == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"setMode","mode":"default","destination":"session"}]}}}"#)
    }

    @Test func planChange() {
        #expect(
            HookOutput.stdout(for: .plan(.change), event: permissionEvent)
                == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user wants to change the plan and will type the changes in the terminal.","interrupt":true}}}"#)
    }

    @Test func answersEchoQuestions() throws {
        let question: JSONValue = .object([
            "question": .string("Which?"),
            "header": .string("Pick"),
            "multiSelect": .bool(true),
            "options": .array([
                .object(["label": .string("A"), "description": .string("first")]),
                .object(["label": .string("B"), "description": .string("second")]),
            ]),
        ])
        let event = HookEvent(
            sessionId: "s", name: .preToolUse, toolName: "AskUserQuestion",
            toolInput: .object(["questions": .array([question])]))
        let out = try #require(HookOutput.stdout(for: .answers(["Which?": "A, B"]), event: event))
        let json = try parse(out)
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["permissionDecision"] as? String == "allow")
        let updated = try #require(specific["updatedInput"] as? [String: Any])
        let questions = try #require(updated["questions"] as? [Any])
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode([question]))
        #expect(NSArray(array: questions).isEqual(to: try #require(expected as? [Any])))
        #expect(updated["answers"] as? [String: String] == ["Which?": "A, B"])
    }

    @Test func answersWithoutQuestionsPrintNothing() {
        let plain = HookEvent(
            sessionId: "s", name: .preToolUse, toolName: "AskUserQuestion",
            toolInput: .object(["command": .string("ls")]))
        let none = HookEvent(sessionId: "s", name: .preToolUse, toolName: "AskUserQuestion")
        #expect(HookOutput.stdout(for: .answers(["a": "b"]), event: plain) == nil)
        #expect(HookOutput.stdout(for: .answers(["a": "b"]), event: none) == nil)
    }

    @Test func nilPrintsNothing() {
        #expect(HookOutput.stdout(for: nil, event: permissionEvent) == nil)
    }
}

private let permissionEvent = HookEvent(
    sessionId: "s", name: .permissionRequest, toolName: "Bash", toolInput: .object(["command": .string("ls")]))
