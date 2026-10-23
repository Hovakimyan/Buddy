import BuddyKit
import Foundation
import Testing

/// The main conversation and its subagents on the island: the agent strip, who is asking on a card, and the
/// status while the main turn waits on its agents.
@Suite struct IslandAgentsTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func session(agents: [Subagent], awaiting: Bool = false) -> Session {
        Session(id: "s1", project: "proj", state: .working, updatedAt: t0, agents: agents, awaitingAgents: awaiting)
    }

    private func agent(_ id: String, _ type: String?, tool: String? = nil, state: SessionState = .working) -> Subagent {
        Subagent(id: id, type: type, lastTool: tool, state: state, updatedAt: t0)
    }

    @Test func chipsNameTheAgentAndItsToolInStartOrder() {
        let chips = IslandLogic.agentChips(of: session(agents: [
            agent("a1", "Explore", tool: "Read"), agent("a2", "general-purpose"), agent("a3", nil, tool: "Bash"),
        ]))
        #expect(chips.chips.map(\.label) == ["Explore · Read", "general-purpose", "Agent · Bash"])
        #expect(chips.chips.map(\.id) == ["a1", "a2", "a3"])
        #expect(chips.overflow == 0)
    }

    @Test func chipsStopAtThreeAndCountTheRest() {
        let agents = (1...5).map { agent("a\($0)", "Explore") }
        let chips = IslandLogic.agentChips(of: session(agents: agents))
        #expect(chips.chips.count == IslandLogic.maxAgentChips)
        #expect(chips.overflow == 2)
        #expect(IslandLogic.agentChips(of: nil).chips.isEmpty)
    }

    @Test func aWaitingAgentIsMarked() {
        let chips = IslandLogic.agentChips(of: session(agents: [agent("a1", "Explore", state: .waiting)]))
        #expect(chips.chips.first?.waiting == true)
    }

    @Test func agentTextIsSanitized() {
        let chips = IslandLogic.agentChips(of: session(agents: [agent("a1", "Ex\u{202E}plore", tool: "Re\nad")]))
        let label = chips.chips.first?.label ?? ""
        #expect(!label.unicodeScalars.contains("\u{202E}"))
        #expect(!label.contains("\n"))
    }

    @Test func askerIsNilForTheMainConversationAndNamesTheSubagentOtherwise() {
        let sessions = [session(agents: [agent("a1", "Explore")])]
        #expect(IslandLogic.asker(agentId: nil, sessionId: "s1", sessions: sessions) == nil)
        #expect(IslandLogic.asker(agentId: "a1", sessionId: "s1", sessions: sessions) == "Explore agent")
        // An agent Buddy has not seen start (or whose type is unknown) is still a subagent.
        #expect(IslandLogic.asker(agentId: "zz", sessionId: "s1", sessions: sessions) == "Subagent")
        #expect(IslandLogic.asker(agentId: "a1", sessionId: "other", sessions: sessions) == "Subagent")
    }

    @Test func statusSaysTheMainTurnWaitsOnItsAgents() {
        #expect(IslandLogic.statusWord(.working, pendingCount: 0, awaitingAgents: 2) == "Waiting on 2 agents")
        #expect(IslandLogic.statusWord(.working, pendingCount: 0, awaitingAgents: 1) == "Waiting on 1 agent")
        // A card waiting comes first; without agents nothing changes.
        #expect(IslandLogic.statusWord(.approval, pendingCount: 1, awaitingAgents: 2) == "1 waiting")
        #expect(IslandLogic.statusWord(.working, pendingCount: 0, awaitingAgents: 0) == "Working")
    }

    @Test func awaitedAgentsCountOnlyWhileTheMainTurnWaits() {
        #expect(IslandLogic.awaitedAgents(session(agents: [agent("a1", "Explore")], awaiting: true)) == 1)
        #expect(IslandLogic.awaitedAgents(session(agents: [agent("a1", "Explore")], awaiting: false)) == 0)
        #expect(IslandLogic.awaitedAgents(nil) == 0)
    }
}
