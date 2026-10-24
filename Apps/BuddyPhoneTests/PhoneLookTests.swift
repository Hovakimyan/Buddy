import BuddyKit
import Foundation
import Testing

@Suite struct PhoneLookTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ state: SessionState, tool: String? = nil, agents: Int = 0) -> SessionRecord {
        SessionRecord(sessionId: id, state: state, project: "p", lastTool: tool, updatedAt: now, agentCount: agents)
    }

    @Test func eachSessionStateHasItsOwnCharacterState() {
        #expect(PhoneLook.characterState(for: .idle) == .idle)
        #expect(PhoneLook.characterState(for: .working) == .working)
        #expect(PhoneLook.characterState(for: .waiting) == .approval)
        #expect(PhoneLook.characterState(for: .finished) == .finished)
        #expect(PhoneLook.characterState(for: .error) == .error)
    }

    @Test func whatNeedsThePersonComesFirst() {
        let busy = [session("a", .working)]
        #expect(PhoneLook.overall(sessions: busy, approvals: 1, questions: 1, connected: true) == .question)
        #expect(PhoneLook.overall(sessions: busy, approvals: 1, questions: 0, connected: true) == .approval)
        #expect(PhoneLook.overall(sessions: busy, approvals: 0, questions: 0, connected: true) == .working)
        #expect(PhoneLook.overall(sessions: [session("a", .finished)], approvals: 0, questions: 0, connected: true) == .finished)
        #expect(PhoneLook.overall(sessions: [session("a", .idle)], approvals: 0, questions: 0, connected: true) == .idle)
        #expect(PhoneLook.overall(sessions: [], approvals: 0, questions: 0, connected: true) == .sleeping)
        #expect(PhoneLook.overall(sessions: busy + [session("b", .error)], approvals: 0, questions: 0, connected: true) == .error)
    }

    @Test func withoutICloudBuddySleepsWhateverIsKnown() {
        #expect(PhoneLook.overall(sessions: [session("a", .working)], approvals: 2, questions: 1, connected: false) == .sleeping)
        #expect(PhoneLook.headline(sessions: [], approvals: 2, questions: 1, connected: false).title == "Not connected")
    }

    @Test func headlinesCountWhatWaits() {
        #expect(PhoneLook.headline(sessions: [], approvals: 0, questions: 2, connected: true)
            == ("Claude is asking", "2 questions are waiting for you."))
        #expect(PhoneLook.headline(sessions: [], approvals: 1, questions: 0, connected: true)
            == ("Claude needs your OK", "1 request is waiting for you."))
        #expect(PhoneLook.headline(sessions: [session("a", .working), session("b", .waiting)], approvals: 0, questions: 0,
                                   connected: true) == ("Working", "2 sessions are busy on your Mac."))
        #expect(PhoneLook.headline(sessions: [], approvals: 0, questions: 0, connected: true).title == "Nothing running")
    }

    @Test func sessionLineJoinsStateToolAndAgents() {
        #expect(PhoneLook.sessionLine(session("a", .working, tool: "Edit", agents: 2)) == "Working · Edit · 2 agents")
        #expect(PhoneLook.sessionLine(session("a", .waiting, tool: "Bash", agents: 1)) == "Waiting · Bash · 1 agent")
        #expect(PhoneLook.sessionLine(session("a", .finished)) == "Finished")
        // A tool name is display text from the hook payload: it is sanitized like everywhere else.
        #expect(PhoneLook.sessionLine(session("a", .working, tool: "Ba\u{202E}sh")) != "Working · Ba\u{202E}sh")
    }

    @Test func countdownIsMinutesAndSeconds() {
        #expect(PhoneLook.countdown(until: now + 581, now: now) == "9:41")
        #expect(PhoneLook.countdown(until: now + 0.2, now: now) == "0:01")
        #expect(PhoneLook.countdown(until: now, now: now) == "Expired")
    }
}
