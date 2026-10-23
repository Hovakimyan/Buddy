import BuddyKit
import Foundation
import Testing

private func session(
    _ id: String = "s1", _ state: SessionState = .working, activity: SessionActivity = .none, starts: Int = 0
) -> Session {
    Session(
        id: id, project: "proj", state: state, updatedAt: Date(timeIntervalSince1970: 0), activity: activity,
        starts: starts)
}

private func session(_ state: SessionState, activity: SessionActivity = .none) -> Session {
    session("s1", state, activity: activity)
}

private func approval(_ id: UUID = UUID(), kind: ApprovalKind = .tool) -> PendingApproval {
    PendingApproval(
        id: id, sessionId: "s1", toolName: "Bash", toolInput: nil,
        summary: ToolSummary(text: "ls", isTruncated: false),
        createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 110), kind: kind)
}

private func question(_ id: UUID = UUID()) -> PendingQuestion {
    PendingQuestion(
        id: id, sessionId: "s1", agentId: nil,
        questions: [
            AskQuestion(
                text: "Which?", header: "Pick",
                options: [AskOption(label: "A", description: nil), AskOption(label: "B", description: nil)],
                multiSelect: false)
        ],
        createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 120))
}

private func snapshot(
    _ sessions: [Session] = [], pending: [PendingApproval] = [], questions: [PendingQuestion] = []
) -> EngineSnapshot {
    EngineSnapshot(sessions: sessions, pending: pending, questions: questions)
}

private func cues(
    _ previous: EngineSnapshot?, _ current: EngineSnapshot, terminalFrontmost: Bool = false
) -> [SoundCue] {
    var trigger = SoundTrigger()
    return trigger.cues(previous: previous, current: current, terminalFrontmost: terminalFrontmost)
}

@Suite struct SoundTriggerTests {
    @Test func firstSnapshotMakesNoSound() {
        let busy = snapshot(
            [session("a", .finished), session("b", .error, activity: .thinking)],
            pending: [approval()], questions: [question()])
        #expect(cues(nil, busy) == [])
    }

    @Test func identicalSnapshotsMakeNoSound() {
        let a = approval(), q = question()
        let state = snapshot([session(activity: .searching)], pending: [a], questions: [q])
        #expect(cues(state, state) == [])
    }

    @Test func aSessionStartPlaysWork() {
        #expect(cues(snapshot(), snapshot([session("a", .idle, starts: 1)])) == [.work])
        #expect(
            cues(snapshot([session("a", starts: 1)]), snapshot([session("a", starts: 1), session("b", .idle, starts: 1)]))
                == [.work])
        #expect(cues(snapshot([session("a", starts: 1)]), snapshot([session("a", starts: 1)])) == [])
    }

    /// A session first seen through another event (running before Buddy started, or back after expiring) is not a
    /// start: its first PreToolUse, Notification or Stop plays no `work`.
    @Test func aSessionFirstSeenWithoutASessionStartPlaysNoWork() {
        #expect(cues(snapshot(), snapshot([session("a", .working)])) == [])
        #expect(cues(snapshot([session("a")]), snapshot([session("a"), session("b", .waiting)])) == [])
        #expect(!cues(snapshot(), snapshot([session("a", .finished)])).contains(.work))
    }

    /// Claude Code starting again in the same session (a resume or /clear) is a start.
    @Test func aSecondSessionStartOfTheSameSessionPlaysWork() {
        #expect(cues(snapshot([session("a", starts: 1)]), snapshot([session("a", .idle, starts: 2)])) == [.work])
    }

    @Test func enteringThinkingPlaysThinkOnce() {
        let before = snapshot([session(activity: .none)])
        let after = snapshot([session(activity: .thinking)])
        #expect(cues(before, after) == [.think])
        #expect(cues(after, after) == [])
        // Leaving thinking is silent.
        #expect(cues(after, before) == [])
    }

    @Test func enteringSearchingPlaysSearch() {
        let before = snapshot([session(activity: .thinking)])
        #expect(cues(before, snapshot([session(activity: .searching)])) == [.search])
    }

    @Test func enteringRateLimitPlaysRate() {
        let before = snapshot([session(activity: .none)])
        #expect(cues(before, snapshot([session(activity: .rateLimited)])) == [.rate])
    }

    @Test func askingActivityIsSilent() {
        let before = snapshot([session(activity: .none)])
        #expect(cues(before, snapshot([session(activity: .asking)])) == [])
    }

    @Test func newToolApprovalPlaysApprovalOnce() {
        let a = approval()
        let before = snapshot([session(.waiting)])
        let after = snapshot([session(.waiting)], pending: [a])
        #expect(cues(before, after) == [.approval])
        // The same request in later snapshots stays silent.
        #expect(cues(after, after) == [])
    }

    @Test func newPlanApprovalPlaysApproval() {
        let plan = approval(kind: .plan(text: "1. Do the thing"))
        #expect(cues(snapshot(), snapshot(pending: [plan])) == [.approval])
    }

    @Test func severalNewApprovalsMakeOneSound() {
        #expect(cues(snapshot(), snapshot(pending: [approval(), approval()])) == [.approval])
    }

    @Test func resolvedApprovalIsSilentAndNextOneSounds() {
        let a = approval()
        #expect(cues(snapshot(pending: [a]), snapshot()) == [])
        #expect(cues(snapshot(), snapshot(pending: [approval()])) == [.approval])
    }

    @Test func newQuestionPlaysQuestionOnce() {
        let q = question()
        let after = snapshot(questions: [q])
        #expect(cues(snapshot(), after) == [.question])
        #expect(cues(after, after) == [])
        #expect(cues(after, snapshot()) == [])
    }

    @Test func transitionToFinishedPlaysFinish() {
        let working = snapshot([session(.working)])
        let finished = snapshot([session(.finished)])
        #expect(cues(working, finished) == [.finish])
        #expect(cues(finished, finished) == [])
        // Back to idle, then finished again: a new transition.
        let idle = snapshot([session(.idle)])
        #expect(cues(finished, idle) == [])
        #expect(cues(idle, finished) == [.finish])
    }

    @Test func transitionToErrorPlaysError() {
        let working = snapshot([session(.working)])
        let failed = snapshot([session(.error)])
        #expect(cues(working, failed) == [.error])
        #expect(cues(failed, failed) == [])
    }

    @Test func finishAndErrorAreSkippedWhenTheTerminalIsFrontmost() {
        let working = snapshot([session("a", .working), session("b", .working)])
        let both = snapshot([session("a", .finished), session("b", .error)])
        #expect(cues(working, both, terminalFrontmost: true) == [])
        #expect(cues(working, both, terminalFrontmost: false) == [.finish, .error])
    }

    @Test func terminalFrontmostDoesNotSilenceTheOtherCues() {
        let before = snapshot([session(.working)])
        let after = snapshot(
            [session(.finished, activity: .thinking), session("b", starts: 1)], pending: [approval()],
            questions: [question()])
        #expect(
            cues(before, after, terminalFrontmost: true) == [.work, .think, .approval, .question])
    }

    @Test func sessionsAreTrackedIndependently() {
        let before = snapshot([session("a", .working), session("b", .working)])
        #expect(cues(before, snapshot([session("a", .finished), session("b", .working)])) == [.finish])
        #expect(
            cues(
                snapshot([session("a", .finished), session("b", .working)]),
                snapshot([session("a", .finished), session("b", .finished)])) == [.finish])
    }

    @Test func endedSessionIsForgottenAndReturnsAsANewOne() {
        let finished = snapshot([session(.finished)])
        #expect(cues(finished, snapshot()) == [])
        // Back through its Stop: it finished, but it did not start.
        #expect(cues(snapshot(), finished) == [.finish])
    }

    @Test func everyKindInOneSnapshotKeepsAStableOrder() {
        let before = snapshot([session("a", .working), session("b", .working), session("c", .working)])
        let after = snapshot(
            [
                session("a", .finished), session("b", .error), session("c", .working, activity: .rateLimited),
                session("d", .working, activity: .searching, starts: 1),
            ],
            pending: [approval()], questions: [question()])
        #expect(cues(before, after) == [.work, .search, .approval, .question, .finish, .error, .rate])
    }
}

@Suite struct TerminalAppsTests {
    @Test func knownTerminalsCount() {
        for id in [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm", "dev.warp.Warp-Stable", "org.alacritty",
        ] {
            #expect(TerminalApps.isTerminal(bundleID: id), "\(id)")
        }
    }

    @Test func otherAppsAndNoAppDoNot() {
        #expect(!TerminalApps.isTerminal(bundleID: "com.apple.finder"))
        #expect(!TerminalApps.isTerminal(bundleID: "com.apple.Terminal.extra"))
        #expect(!TerminalApps.isTerminal(bundleID: ""))
        #expect(!TerminalApps.isTerminal(bundleID: nil))
    }
}

@Suite struct SoundCueTests {
    @Test func theCueSetIsExactlyTheSpecifiedOnes() {
        let names = SoundCue.allCases.map(\.rawValue)
        #expect(names == [
            "peek", "open", "close", "hover", "boop", "annoyed", "dizzy", "greet", "work", "think", "search",
            "approval", "question", "approve", "send", "finish", "error", "rate", "love", "pop", "proud", "wink",
            "yawn", "sleep", "tick", "switch",
        ])
        #expect(names.count == 26)
        #expect(SoundCue.switchSession.rawValue == "switch")
    }
}
