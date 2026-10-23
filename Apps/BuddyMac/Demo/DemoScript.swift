import BuddyKit
import Foundation

/// The scripted session the demo plays on the island (spec 7): tools, thinking, searching, a permission card, a
/// single-select and a multi-select question, a plan card, a rate-limit notice, finished, an error and sleeping. Pure
/// data: each step is the snapshot the engine would have sent at `at` seconds into the demo, its dates taken from
/// `epoch` (`DemoFeed` moves them to the moment it shows the step). One fictional session in a fictional project.
///
/// About 87 s in all; each card stays 11 s (answering it moves on at once). Dizzy is not scripted: clicking the
/// character during the demo shows it and the other reactions.
struct DemoScript {
    typealias Step = (at: TimeInterval, snapshot: EngineSnapshot)

    /// The script's time zero.
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    /// When the demo ends, after the last step.
    static let end: TimeInterval = 87
    static let sessionId = "demo-session"
    static let project = "demo-app"

    /// The steps, built afresh on every call with new request ids, so each run's cards are new to the island (a replay
    /// plays the card cues again).
    static func steps() -> [Step] {
        [
            // SessionStart.
            (0, snapshot(at: 0, state: .idle)),
            // UserPromptSubmit.
            (3, snapshot(at: 3, state: .working, activity: .thinking)),
            // PreToolUse Read, then Edit, then Grep.
            (7, snapshot(at: 7, state: .working, tools: ["Read"])),
            (10, snapshot(at: 10, state: .working, tools: ["Read", "Edit"])),
            (13, snapshot(at: 13, state: .working, activity: .searching, tools: ["Read", "Edit", "Grep"])),
            // PermissionRequest.
            (17, snapshot(at: 17, state: .waiting, tools: ["Read", "Edit", "Grep", "Bash"], pending: [permission(at: 17)])),
            // PostToolUse Bash: running again.
            (28, snapshot(at: 28, state: .working, tools: ["Read", "Edit", "Grep", "Bash"])),
            // AskUserQuestion, single select, then multi select.
            (31, snapshot(at: 31, state: .working, tools: questionTools(1), questions: [reporterQuestion(at: 31)])),
            (42, snapshot(at: 42, state: .working, tools: questionTools(2), questions: [checksQuestion(at: 42)])),
            // ExitPlanMode's PermissionRequest.
            (53, snapshot(at: 53, state: .waiting, tools: questionTools(2) + ["ExitPlanMode"], pending: [plan(at: 53)])),
            // A Notification about a rate limit.
            (64, snapshot(at: 64, state: .waiting, activity: .rateLimited, tools: questionTools(2) + ["ExitPlanMode"])),
            // Stop, then (the next prompt failed) StopFailure.
            (69, snapshot(at: 69, state: .finished, tools: questionTools(2) + ["ExitPlanMode"])),
            (75, snapshot(at: 75, state: .error, tools: questionTools(2) + ["ExitPlanMode"])),
            // Nothing for a while: the last event is long ago, so the character falls asleep.
            (81, snapshot(at: 81, lastEventAt: 81 - 150, state: .idle, tools: questionTools(2) + ["ExitPlanMode"])),
        ]
    }

    // MARK: Building the steps

    private static func date(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    /// The tools started before the `count`th question (each ask is a PreToolUse of `AskUserQuestion`).
    private static func questionTools(_ count: Int) -> [String] {
        ["Read", "Edit", "Grep", "Bash"] + Array(repeating: "AskUserQuestion", count: count)
    }

    /// The demo session at `at` (its last event at `lastEventAt`, by default the step itself), having started
    /// `tools` since the prompt (the last three are shown), with the cards waiting then.
    private static func snapshot(
        at: TimeInterval, lastEventAt: TimeInterval? = nil, state: SessionState, activity: SessionActivity = .none,
        tools: [String] = [], pending: [PendingApproval] = [], questions: [PendingQuestion] = []
    ) -> EngineSnapshot {
        let session = Session(
            id: sessionId, project: project, state: state, lastTool: tools.last,
            updatedAt: date(lastEventAt ?? at), activity: activity, recentTools: Array(tools.suffix(3)),
            toolCount: tools.count, starts: 1)
        return EngineSnapshot(sessions: [session], pending: pending, questions: questions)
    }

    private static func permission(at: TimeInterval) -> PendingApproval {
        let input = JSONValue.object(["command": .string("npm test")])
        return PendingApproval(
            id: UUID(), sessionId: sessionId, toolName: "Bash", toolInput: input,
            summary: ToolSummary.make(toolName: "Bash", toolInput: input),
            createdAt: date(at), expiresAt: date(at + BuddyEngine.defaultApprovalTimeout))
    }

    private static let planText = """
        1. Add a JSON reporter option to the test runner.
        2. Run lint, type check and unit tests before each commit.
        3. Document both in the README.
        """

    private static func plan(at: TimeInterval) -> PendingApproval {
        let input = JSONValue.object(["plan": .string(planText)])
        return PendingApproval(
            id: UUID(), sessionId: sessionId, toolName: "ExitPlanMode", toolInput: input,
            summary: ToolSummary.make(toolName: "ExitPlanMode", toolInput: input),
            createdAt: date(at), expiresAt: date(at + BuddyEngine.defaultApprovalTimeout), kind: .plan(text: planText))
    }

    /// Options without descriptions: the card shows them as buttons in a row.
    private static func reporterQuestion(at: TimeInterval) -> PendingQuestion {
        question(at: at, AskQuestion(
            text: "Which test reporter format?", header: "Reporter",
            options: ["Verbose", "Dot", "JSON"].map { AskOption(label: $0, description: nil) }, multiSelect: false))
    }

    /// Options with descriptions: the card shows them as a list.
    private static func checksQuestion(at: TimeInterval) -> PendingQuestion {
        question(at: at, AskQuestion(
            text: "Which checks should run before each commit?", header: "Checks",
            options: [
                AskOption(label: "Lint", description: "Style and common mistakes"),
                AskOption(label: "Type check", description: "The compiler, without a build"),
                AskOption(label: "Unit tests", description: "The fast suite only"),
            ],
            multiSelect: true))
    }

    private static func question(at: TimeInterval, _ asked: AskQuestion) -> PendingQuestion {
        PendingQuestion(
            id: UUID(), sessionId: sessionId, agentId: nil, questions: [asked], createdAt: date(at),
            expiresAt: date(at + BuddyEngine.defaultQuestionTimeout))
    }
}
