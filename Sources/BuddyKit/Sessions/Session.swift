import Foundation

public enum SessionState: String, Codable, Sendable {
    case idle, working, waiting, finished, error
}

/// What a session is doing beyond its coarse `SessionState`; drives the character, never the phone.
public enum SessionActivity: String, Sendable {
    case none, thinking, searching, rateLimited, asking
}

/// A subagent of a session (`agent_id`), running next to the main conversation.
public struct Subagent: Sendable, Equatable, Identifiable {
    public let id: String
    /// `agent_type` (such as `Explore`), once an event reported it.
    public var type: String?
    /// The last tool it started.
    public var lastTool: String?
    /// `.waiting` while it has a permission request open, `.working` otherwise.
    public var state: SessionState
    public var updatedAt: Date

    public init(id: String, type: String? = nil, lastTool: String? = nil, state: SessionState = .working, updatedAt: Date) {
        self.id = id
        self.type = type
        self.lastTool = lastTool
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// A tracked Claude Code terminal session.
public struct Session: Sendable, Equatable, Identifiable {
    /// The project of a session whose events have not said where it runs (no `cwd` yet).
    public static let unknownProject = "unknown"

    public let id: String
    /// Name of the folder Claude Code was started in (see `SessionStore.project(fromCwd:transcriptPath:)`), or
    /// "unknown" when no event reported a `cwd`.
    public var project: String
    public var state: SessionState
    public var lastTool: String?
    public var updatedAt: Date
    public var activity: SessionActivity
    /// The last (at most 3) tools the session started, newest last.
    public var recentTools: [String]
    /// PreToolUse events since the last UserPromptSubmit.
    public var toolCount: Int
    /// SessionStart events seen for this id. Zero for a session first seen through another event (one that was
    /// running before Buddy started, or came back after expiring), so only a real start is announced as new.
    public var starts: Int
    /// Subagents running now, in the order they were first seen. `lastTool`, `recentTools`, `toolCount` and
    /// `activity` are the main conversation's alone; subagents keep their own tool here.
    public var agents: [Subagent]
    /// The main conversation's turn ended (Stop) while subagents still ran: the session stays `.working` until the
    /// last one stops.
    public var awaitingAgents: Bool
    /// Claude finished its turn and its `Stop` hook waits for a message from the phone. Set by the engine, not by
    /// `SessionStore`.
    public var awaitingMessage: Bool
    /// Messages from the phone waiting for this session's turn to end. Set by the engine.
    public var queuedMessages: Int
    /// The main conversation's latest prompt (typed in the terminal, or a message from the phone), at most
    /// `Session.promptLimit` characters; nil before the first one.
    public var lastPrompt: String?
    /// Claude's reply that ended the latest turn, its last `Session.replyLimit` characters; nil while none has.
    public var lastReply: String?

    /// Where the session runs (from its hook relay), so a message from the phone can be typed there.
    public var terminal: TerminalInfo?

    /// How much of a prompt is kept (its start).
    public static let promptLimit = 1000
    /// How much of a reply is kept (its end, where a recap usually is).
    public static let replyLimit = 4000

    public init(
        id: String,
        project: String,
        state: SessionState,
        lastTool: String? = nil,
        updatedAt: Date,
        activity: SessionActivity = .none,
        recentTools: [String] = [],
        toolCount: Int = 0,
        starts: Int = 0,
        agents: [Subagent] = [],
        awaitingAgents: Bool = false,
        awaitingMessage: Bool = false,
        queuedMessages: Int = 0,
        lastPrompt: String? = nil,
        lastReply: String? = nil
    ) {
        self.id = id
        self.project = project
        self.state = state
        self.lastTool = lastTool
        self.updatedAt = updatedAt
        self.activity = activity
        self.recentTools = recentTools
        self.toolCount = toolCount
        self.starts = starts
        self.agents = agents
        self.awaitingAgents = awaitingAgents
        self.awaitingMessage = awaitingMessage
        self.queuedMessages = queuedMessages
        self.lastPrompt = lastPrompt
        self.lastReply = lastReply
    }

    /// `text` cut to `promptLimit` characters from its start, marked with "…" when cut.
    public static func keptPrompt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= promptLimit ? trimmed : String(trimmed.prefix(promptLimit - 1)) + "…"
    }

    /// `text` cut to its last `replyLimit` characters, marked with "…" when cut.
    public static func keptReply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= replyLimit ? trimmed : "…" + String(trimmed.suffix(replyLimit - 1))
    }
}
