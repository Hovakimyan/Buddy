import Foundation
import Testing
@testable import BuddyKit

/// Subagents share their session's `session_id` and carry `agent_id` / `agent_type`. The event order below follows
/// a real Claude Code 2.1.309 run with two background Explore agents (captured with a tap on every hook).
@Suite struct SubagentTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ name: HookEventName, tool: String? = nil, agent: String? = nil, type: String? = nil
    ) -> HookEvent {
        HookEvent(sessionId: "s1", name: name, cwd: "/Users/me/proj", toolName: tool, agentId: agent, agentType: type)
    }

    private func session(_ store: SessionStore) throws -> Session { try #require(store.sessions.first) }

    @Test func parsesSubagentEventsAndTheAgentType() {
        let start = HookEvent.parse(Data(#"""
        {"session_id":"abc","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"Explore"}
        """#.utf8))
        #expect(start?.name == .subagentStart)
        #expect(start?.agentId == "a1")
        #expect(start?.agentType == "Explore")
        let stop = HookEvent.parse(Data(#"{"session_id":"abc","hook_event_name":"SubagentStop","agent_id":"a1"}"#.utf8))
        #expect(stop?.name == .subagentStop)
        #expect(stop?.agentType == nil)
        // An agent_type of another type is ignored, never a reason to drop the event.
        let odd = HookEvent.parse(Data(#"{"session_id":"abc","hook_event_name":"Stop","agent_type":7}"#.utf8))
        #expect(odd != nil)
        #expect(odd?.agentType == nil)
    }

    @Test func subagentToolsNeverReplaceTheMainTool() throws {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.preToolUse, tool: "Agent"), now: t0 + 1)
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0 + 2)
        store.apply(event(.preToolUse, tool: "Read", agent: "a1", type: "Explore"), now: t0 + 3)
        store.apply(event(.preToolUse, tool: "Grep", agent: "a1", type: "Explore"), now: t0 + 4)
        let s = try session(store)
        #expect(s.lastTool == "Agent")
        #expect(s.recentTools == ["Agent"])
        #expect(s.toolCount == 1)
        #expect(s.activity == .none)  // a subagent's Grep is not the main conversation searching
        #expect(s.agents.map(\.id) == ["a1"])
        #expect(s.agents.first?.type == "Explore")
        #expect(s.agents.first?.lastTool == "Grep")
        #expect(s.agents.first?.state == .working)
    }

    @Test func parallelSubagentsAreListedInStartOrder() throws {
        var store = SessionStore()
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0)
        store.apply(event(.subagentStart, agent: "a2", type: "general-purpose"), now: t0 + 1)
        store.apply(event(.preToolUse, tool: "Bash", agent: "a1", type: "Explore"), now: t0 + 2)
        #expect(try session(store).agents.map(\.id) == ["a1", "a2"])
        // A subagent seen first through a tool event (Buddy started late) is listed too.
        store.apply(event(.preToolUse, tool: "Read", agent: "a3", type: "Explore"), now: t0 + 3)
        #expect(try session(store).agents.map(\.id) == ["a1", "a2", "a3"])
    }

    @Test func subagentPermissionRequestMarksItWaiting() throws {
        var store = SessionStore()
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0)
        store.apply(event(.permissionRequest, tool: "Bash", agent: "a1", type: "Explore"), now: t0 + 1)
        let s = try session(store)
        #expect(s.state == .waiting)
        #expect(s.agents.first?.state == .waiting)
        #expect(s.lastTool == nil)
        store.apply(event(.postToolUse, tool: "Bash", agent: "a1", type: "Explore"), now: t0 + 2)
        #expect(try session(store).agents.first?.state == .working)
    }

    @Test func subagentStopRemovesItAndUnknownStopsChangeNothing() throws {
        var store = SessionStore()
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0)
        store.apply(event(.subagentStart, agent: "a2", type: "Explore"), now: t0 + 1)
        store.apply(event(.subagentStop, agent: "a1", type: "Explore"), now: t0 + 2)
        #expect(try session(store).agents.map(\.id) == ["a2"])
        // Claude Code's own helpers report a SubagentStop without ever starting (and without a type): ignored.
        let before = try session(store)
        store.apply(event(.subagentStop, agent: "helper"), now: t0 + 3)
        #expect(try session(store) == before)
        // And never create a session on their own.
        var empty = SessionStore()
        empty.apply(HookEvent(sessionId: "s9", name: .subagentStop, agentId: "helper"), now: t0)
        #expect(empty.sessions.isEmpty)
    }

    /// The main turn can end (Stop) while background subagents still run: the session is not finished then, it waits
    /// on its agents, and finishes when the last one stops.
    @Test func mainStopWhileAgentsRunWaitsOnThem() throws {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.preToolUse, tool: "Agent"), now: t0 + 1)
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0 + 2)
        store.apply(event(.subagentStart, agent: "a2", type: "Explore"), now: t0 + 2)
        store.apply(event(.stop), now: t0 + 3)
        var s = try session(store)
        #expect(s.state == .working)
        #expect(s.awaitingAgents)
        store.apply(event(.preToolUse, tool: "Bash", agent: "a2", type: "Explore"), now: t0 + 4)
        #expect(try session(store).awaitingAgents)
        store.apply(event(.subagentStop, agent: "a1", type: "Explore"), now: t0 + 5)
        #expect(try session(store).state == .working)
        store.apply(event(.subagentStop, agent: "a2", type: "Explore"), now: t0 + 6)
        s = try session(store)
        #expect(s.state == .finished)
        #expect(!s.awaitingAgents)
        #expect(s.agents.isEmpty)
    }

    @Test func mainStopWithoutAgentsFinishesAsBefore() throws {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.stop), now: t0 + 1)
        #expect(try session(store).state == .finished)
        #expect(try !session(store).awaitingAgents)
    }

    @Test func mainActivityEndsTheWaitOnAgents() throws {
        var store = SessionStore()
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0)
        store.apply(event(.stop), now: t0 + 1)
        #expect(try session(store).awaitingAgents)
        store.apply(event(.userPromptSubmit), now: t0 + 2)
        #expect(try !session(store).awaitingAgents)
        #expect(try session(store).agents.map(\.id) == ["a1"])  // a background agent keeps running across prompts
    }

    @Test func sessionStartClearsAgents() throws {
        var store = SessionStore()
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0)
        store.apply(event(.sessionStart), now: t0 + 1)
        #expect(try session(store).agents.isEmpty)
    }

    @Test func silentAgentsExpire() throws {
        var store = SessionStore()
        store.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0)
        store.apply(event(.stop), now: t0 + 1)
        store.apply(event(.subagentStart, agent: "a2", type: "Explore"), now: t0 + 500)
        store.expire(now: t0 + 600)
        #expect(try session(store).agents.map(\.id) == ["a2"])
        store.expire(now: t0 + 1100)
        let s = try session(store)
        #expect(s.agents.isEmpty)
        #expect(!s.awaitingAgents)
        #expect(s.state == .idle)
    }
}
