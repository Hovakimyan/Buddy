import Foundation

public enum SessionState: String, Codable, Sendable {
    case idle, working, waiting, finished, error
}

/// What a session is doing beyond its coarse `SessionState`; drives the character, never the phone.
public enum SessionActivity: String, Sendable {
    case none, thinking, searching, rateLimited, asking
}

/// A tracked Claude Code terminal session.
public struct Session: Sendable, Equatable, Identifiable {
    /// The project of a session whose events have not said where it runs (no `cwd` yet).
    public static let unknownProject = "unknown"

    public let id: String
    /// Last path component of the session's `cwd`, or "unknown" when none was reported.
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

    public init(
        id: String,
        project: String,
        state: SessionState,
        lastTool: String? = nil,
        updatedAt: Date,
        activity: SessionActivity = .none,
        recentTools: [String] = [],
        toolCount: Int = 0,
        starts: Int = 0
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
    }
}
