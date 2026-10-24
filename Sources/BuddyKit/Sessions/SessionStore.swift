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
        // A stop of a subagent never seen start (Claude Code's own helpers report these) changes nothing.
        if e.name == .subagentStop, byId[e.sessionId]?.agents.contains(where: { $0.id == e.agentId }) != true { return }

        var session = byId[e.sessionId]
            ?? Session(id: e.sessionId, project: Session.unknownProject, state: .idle, updatedAt: now)
        if let cwd = e.cwd, let project = Self.project(fromCwd: cwd, transcriptPath: e.transcriptPath) {
            session.project = project
        }
        if let agentId = e.agentId {
            applySubagent(e, agentId: agentId, to: &session, now: now)
        } else {
            applyMain(e, to: &session)
        }
        session.updatedAt = now
        byId[e.sessionId] = session
    }

    /// An event of the main conversation (no `agent_id`).
    private func applyMain(_ e: HookEvent, to session: inout Session) {
        if let tool = e.toolName {
            session.lastTool = tool
        }
        if let terminal = e.terminal { session.terminal = terminal }
        switch e.name {
        case .sessionStart:
            session.state = .idle
            session.activity = .none
            session.starts += 1
            session.agents = []
            session.awaitingAgents = false
        case .userPromptSubmit:
            session.state = .working
            session.activity = .thinking
            session.toolCount = 0
            session.awaitingAgents = false
            if let prompt = e.prompt {
                session.lastPrompt = Session.keptPrompt(prompt)
                session.lastReply = nil  // the reply shown belongs to this prompt once it comes
            }
        case .preToolUse:
            session.state = .working
            session.activity = e.toolName.map(Self.searchingTools.contains) == true ? .searching : .none
            session.toolCount += 1
            session.awaitingAgents = false
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
            if let reply = e.lastAssistantMessage { session.lastReply = Session.keptReply(reply) }
            // Background subagents can outlive the main turn: then the session waits on them.
            session.awaitingAgents = !session.agents.isEmpty
            session.state = session.awaitingAgents ? .working : .finished
            session.activity = .none
        case .stopFailure:
            session.state = .error
            session.activity = .none
            session.awaitingAgents = false
        case .sessionEnd, .subagentStart, .subagentStop:
            break
        }
    }

    /// An event of one subagent: it updates that subagent's entry, never the main conversation's tool or activity.
    private func applySubagent(_ e: HookEvent, agentId: String, to session: inout Session, now: Date) {
        if e.name == .subagentStop {
            session.agents.removeAll { $0.id == agentId }
            if session.awaitingAgents, session.agents.isEmpty {
                session.awaitingAgents = false
                session.state = .finished
            }
            return
        }
        var agent = session.agents.first { $0.id == agentId } ?? Subagent(id: agentId, updatedAt: now)
        if let type = e.agentType { agent.type = type }
        if let tool = e.toolName, tool != Self.handbackTool { agent.lastTool = tool }
        agent.updatedAt = now
        switch e.name {
        case .permissionRequest:
            agent.state = .waiting
            session.state = .waiting
        case .notification:
            if !e.isIdlePrompt { session.state = .waiting }
        case .preToolUse, .postToolUse, .postToolUseFailure, .subagentStart:
            agent.state = .working
            session.state = .working
        default:
            break
        }
        if let index = session.agents.firstIndex(where: { $0.id == agentId }) {
            session.agents[index] = agent
        } else {
            session.agents.append(agent)
        }
    }

    /// A message from the phone was handed to Claude as its next prompt: it is what the next reply answers.
    public mutating func notePrompt(_ text: String, sessionId: String) {
        guard var session = byId[sessionId] else { return }
        session.lastPrompt = Session.keptPrompt(text)
        session.lastReply = nil
        byId[sessionId] = session
    }

    /// Removes sessions with no event for `idleTimeout`, subagents with no event for `agentIdleTimeout`, and
    /// returns `finished` sessions to `idle` once they have been shown for `finishedHold`.
    public mutating func expire(
        now: Date,
        idleTimeout: TimeInterval = 1800,
        finishedHold: TimeInterval = 5,
        agentIdleTimeout: TimeInterval = 600
    ) {
        for (id, var session) in byId {
            let age = now.timeIntervalSince(session.updatedAt)
            if age >= idleTimeout {
                byId[id] = nil
                continue
            }
            let agents = session.agents.filter { now.timeIntervalSince($0.updatedAt) < agentIdleTimeout }
            if agents != session.agents {
                session.agents = agents
                // The agents it waited on went silent: nothing is known to run any more.
                if session.awaitingAgents, agents.isEmpty {
                    session.awaitingAgents = false
                    session.state = .idle
                }
                byId[id] = session
            }
            if session.state == .finished, age >= finishedHold {
                session.state = .idle
                byId[id] = session
            }
        }
    }

    private static let searchingTools: Set<String> = ["Grep", "Glob", "WebSearch", "WebFetch"]
    private static let recentToolsLimit = 3
    /// The tool a subagent calls to hand its result back: bookkeeping, not work worth showing.
    private static let handbackTool = "SubagentHandback"

    /// A rate-limit notice, or a message that ends in a question; nil for any other notification.
    private static func activity(fromNotification message: String?) -> SessionActivity? {
        guard let message else { return nil }
        if message.range(of: "rate limit", options: .caseInsensitive) != nil { return .rateLimited }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return .asking }
        return nil
    }

    /// The folder Claude Code was started in, named. `cwd` moves: the main conversation's shell changes folder and a
    /// subagent can run in a worktree (`<project>/.claude/worktrees/agent-…`). So the folder is the one of `cwd` and
    /// its parents whose encoded path is the transcript's folder name; without a match, `cwd` outside any worktree.
    static func project(fromCwd cwd: String, transcriptPath: String?) -> String? {
        var launched: String?
        if let transcriptPath {
            let encoded = ((transcriptPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
            // Not `standardizingPath`: it drops `/private` from a path, and Claude Code keeps it.
            var candidate = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            while launched == nil, candidate.count > 1 {
                if encodedProjectFolder(candidate) == encoded { launched = candidate }
                candidate = (candidate as NSString).deletingLastPathComponent
            }
        }
        let path = launched ?? cwd.range(of: worktreesFolder).map { String(cwd[..<$0.lowerBound]) } ?? cwd
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    private static let worktreesFolder = "/.claude/worktrees/"

    /// How Claude Code names a folder under `~/.claude/projects`: every character but an ASCII letter or digit
    /// becomes "-".
    private static func encodedProjectFolder(_ path: String) -> String {
        String(path.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }
}
