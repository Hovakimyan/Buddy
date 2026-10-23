import Foundation

/// Tracks live sessions by folding hook events into per-session state.
/// Time is always passed in so behaviour is deterministic and testable.
public struct SessionStore: Sendable {
    private var byId: [String: Session] = [:]

    public init() {}

    /// Sessions sorted by `updatedAt`, most recent first.
    public var sessions: [Session] {
        byId.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
        }
    }

    public mutating func apply(_ e: HookEvent, now: Date) {
        if e.name == .sessionEnd {
            byId[e.sessionId] = nil
            return
        }
        // An idle reminder is not a question and not activity: a known session stays as it is (it
        // must not show as waiting, nor come back from finished or idle).
        if e.isIdlePrompt, byId[e.sessionId] != nil { return }

        var session = byId[e.sessionId]
            ?? Session(id: e.sessionId, project: Session.unknownProject, state: .idle, updatedAt: now)
        if let cwd = e.cwd, let project = Self.project(fromCwd: cwd) {
            session.project = project
        }
        if let tool = e.toolName {
            session.lastTool = tool
        }
        switch e.name {
        case .sessionStart:
            session.state = .idle
            session.activity = .none
            session.starts += 1
        case .userPromptSubmit:
            session.state = .working
            session.activity = .thinking
            session.toolCount = 0
        case .preToolUse:
            session.state = .working
            session.activity = e.toolName.map(Self.searchingTools.contains) == true ? .searching : .none
            session.toolCount += 1
            if let tool = e.toolName {
                session.recentTools = Array((session.recentTools + [tool]).suffix(Self.recentToolsLimit))
            }
        case .postToolUse, .postToolUseFailure:
            session.state = .working
            // A tool finished, so Claude is running again: a question or rate limit it reported is over.
            // Searching stays until the next tool starts.
            if session.activity == .asking || session.activity == .rateLimited { session.activity = .none }
        case .permissionRequest:
            session.state = .waiting
        case .notification:
            // A permission prompt, or a kind this code does not know: assume Claude wants an answer.
            if !e.isIdlePrompt { session.state = .waiting }
            if let activity = Self.activity(fromNotification: e.message) { session.activity = activity }
        case .stop:
            session.state = .finished
            session.activity = .none
        case .stopFailure:
            session.state = .error
            session.activity = .none
        case .sessionEnd:
            break
        }
        session.updatedAt = now
        byId[e.sessionId] = session
    }

    /// Removes sessions with no event for `idleTimeout` and returns `finished` sessions to
    /// `idle` once they have been shown for `finishedHold`.
    public mutating func expire(
        now: Date,
        idleTimeout: TimeInterval = 1800,
        finishedHold: TimeInterval = 5
    ) {
        for (id, var session) in byId {
            let age = now.timeIntervalSince(session.updatedAt)
            if age >= idleTimeout {
                byId[id] = nil
            } else if session.state == .finished, age >= finishedHold {
                session.state = .idle
                byId[id] = session
            }
        }
    }

    private static let searchingTools: Set<String> = ["Grep", "Glob", "WebSearch", "WebFetch"]
    private static let recentToolsLimit = 3

    /// A rate-limit notice, or a message that ends in a question; nil for any other notification.
    private static func activity(fromNotification message: String?) -> SessionActivity? {
        guard let message else { return nil }
        if message.range(of: "rate limit", options: .caseInsensitive) != nil { return .rateLimited }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return .asking }
        return nil
    }

    private static func project(fromCwd cwd: String) -> String? {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
