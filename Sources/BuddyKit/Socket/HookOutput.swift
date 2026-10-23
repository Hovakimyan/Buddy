import Foundation

/// Builds the stdout JSON Claude Code expects from a hook.
public enum HookOutput: Sendable {
    /// Returns nil when there is no human choice to relay: the hook must then print nothing so
    /// Claude Code falls back to its normal prompt. `event` is the hook call being answered; an
    /// answer needs its `questions` to hand them back.
    public static func stdout(for reply: HookReply?, event: HookEvent) -> String? {
        switch reply {
        case nil:
            return nil
        case .decision(.allow):
            return permission(#"{"behavior":"allow"}"#)
        case .decision(.deny):
            return permission(#"{"behavior":"deny","message":"Denied from Buddy"}"#)
        case .plan(.acceptEdits):
            return permission(allowAndSetMode("acceptEdits"))
        case .plan(.askEachTime):
            return permission(allowAndSetMode("default"))
        case .plan(.change):
            return permission(
                #"{"behavior":"deny","message":"The user wants to change the plan and will type the changes in the terminal.","interrupt":true}"#)
        case .answers(let answers):
            return answered(answers, event: event)
        }
    }

    private static func permission(_ decisionJSON: String) -> String {
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"# + decisionJSON + "}}"
    }

    private static func allowAndSetMode(_ mode: String) -> String {
        #"{"behavior":"allow","updatedPermissions":[{"type":"setMode","mode":"# + "\"\(mode)\""
            + #","destination":"session"}]}"#
    }

    /// Allows the `AskUserQuestion` call with its own questions plus the person's answers filled in.
    /// Nil when the call carries no `questions` to echo.
    private static func answered(_ answers: [String: String], event: HookEvent) -> String? {
        guard case .object(let input)? = event.toolInput, let questions = input["questions"] else {
            return nil
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": ["questions": foundationObject(questions), "answers": answers],
            ] as [String: Any]
        ]
        guard JSONSerialization.isValidJSONObject(output),
              let data = try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func foundationObject(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let bool): return bool
        case .number(let number): return number
        case .string(let string): return string
        case .array(let items): return items.map(foundationObject)
        case .object(let members): return members.mapValues(foundationObject)
        }
    }
}
