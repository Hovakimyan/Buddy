import Foundation

public enum HookEventName: String, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionEnd = "SessionEnd"
    case permissionRequest = "PermissionRequest"
}

/// One Claude Code hook invocation, decoded from the JSON the hook receives on stdin.
public struct HookEvent: Sendable, Equatable {
    /// Hook payloads larger than this are rejected (4 MiB).
    public static let maxPayloadSize = 4 * 1024 * 1024

    public let sessionId: String
    public let name: HookEventName
    public let cwd: String?
    public let toolName: String?
    public let toolInput: JSONValue?
    public let message: String?
    /// What a `Notification` is about (`permission_prompt`, `idle_prompt`, ...); nil when absent.
    public let notificationType: String?
    /// Which subagent made a tool call (`agent_id`); nil for the main conversation. Subagents of one session
    /// run in parallel and share its `session_id`, so this tells their requests apart.
    public let agentId: String?
    /// Set by the `buddy-hook --ask` relay (top-level `"buddy_ask": true`) on the `AskUserQuestion`
    /// call it waits on. Anything else, including a non-boolean value, is false.
    public let isAsk: Bool

    public init(
        sessionId: String,
        name: HookEventName,
        cwd: String? = nil,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        agentId: String? = nil,
        isAsk: Bool = false
    ) {
        self.sessionId = sessionId
        self.name = name
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.notificationType = notificationType
        self.agentId = agentId
        self.isAsk = isAsk
    }

    /// Whether the relay stays connected for a reply: a permission request, or an ask.
    public var waitsForReply: Bool { name == .permissionRequest || isAsk }

    /// A `Notification` that only says Claude has been idle for a while ("Claude is waiting for your
    /// input"), not that it needs an answer. Known by its type, or by its text when the payload has no
    /// type (older Claude Code versions).
    public var isIdlePrompt: Bool {
        guard name == .notification else { return false }
        if let notificationType { return notificationType == "idle_prompt" }
        return message?.range(of: "waiting for your input", options: .caseInsensitive) != nil
    }

    private struct Payload: Decodable {
        let sessionId: String
        let hookEventName: String
        let cwd: String?
        let toolName: String?
        let toolInput: JSONValue?
        let message: String?
        let notificationType: String?
        /// Decoded loosely: an `agent_id` of an unexpected type is ignored rather than failing the event.
        let agentId: JSONValue?
        /// Decoded loosely like `agentId`: only the boolean `true` counts.
        let buddyAsk: JSONValue?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case hookEventName = "hook_event_name"
            case cwd
            case toolName = "tool_name"
            case toolInput = "tool_input"
            case message
            case notificationType = "notification_type"
            case agentId = "agent_id"
            case buddyAsk = "buddy_ask"
        }
    }

    /// The longest `session_id` accepted (Claude Code's are 36-character UUIDs).
    public static let maxSessionIdLength = 200

    /// Returns nil for malformed JSON, a missing or unusable `session_id` (see `isUsableSessionId`),
    /// an unknown `hook_event_name`, or input larger than 4 MiB.
    public static func parse(_ data: Data) -> HookEvent? {
        guard data.count <= maxPayloadSize,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              isUsableSessionId(payload.sessionId),
              let name = HookEventName(rawValue: payload.hookEventName)
        else { return nil }
        return HookEvent(
            sessionId: payload.sessionId,
            name: name,
            cwd: payload.cwd,
            toolName: payload.toolName,
            toolInput: payload.toolInput,
            message: payload.message,
            notificationType: payload.notificationType,
            agentId: { if case .string(let id)? = payload.agentId { id } else { nil } }(),
            isAsk: payload.buddyAsk == .bool(true)
        )
    }

    /// The session id is used as a CloudKit record name, which raises an exception (a crash, not an
    /// error) when it is empty, not ASCII, longer than 255 characters or starts with "_". So only
    /// printable ASCII, 1 to `maxSessionIdLength` characters, not starting with "_", is accepted.
    static func isUsableSessionId(_ id: String) -> Bool {
        let bytes = id.utf8
        return !bytes.isEmpty
            && bytes.count <= maxSessionIdLength
            && bytes.first != UInt8(ascii: "_")
            && bytes.allSatisfy { (0x20...0x7E).contains($0) }
    }
}
