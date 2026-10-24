#if DEBUG
import BuddyKit
import Foundation

/// Debug builds only: launched with `-BuddyDemo YES`, the app skips iCloud and shows sample sessions, an approval
/// and a question from an in-memory cloud, so every screen can be looked at (and screenshotted) in the simulator.
enum DemoCloud {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "BuddyDemo") }

    static let approvalId = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let questionId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!

    /// `-BuddyDemoScreen approval`, `question` or `session` opens that screen at launch.
    static var requestedScreen: PhoneScreen? {
        guard isRequested else { return nil }
        switch UserDefaults.standard.string(forKey: "BuddyDemoScreen") {
        case "approval": return .approval(approvalId)
        case "question": return .question(questionId)
        case "session": return .session("demo-3")
        default: return nil
        }
    }

    static let selector = PhoneCloudSelector(
        hasEntitlement: { true },
        // `-BuddyDemoLoading YES` keeps the iCloud check running for a minute, to look at the loading state.
        account: {
            if UserDefaults.standard.bool(forKey: "BuddyDemoLoading") { try? await Task.sleep(for: .seconds(60)) }
            return .available
        },
        makeConnection: {
            let cloud = InMemoryCloud()
            Task { await seed(cloud.macSide) }
            return PhoneConnection(transport: cloud.phoneSide, refresh: {})
        },
        accountTimeout: .seconds(90))

    private static func seed(_ mac: any PhoneTransport) async {
        let now = Date()
        let sessions = [
            SessionRecord(
                sessionId: "demo-1", state: .waiting, project: "deskmate", lastTool: "Bash", updatedAt: now, agentCount: 2),
            SessionRecord(sessionId: "demo-2", state: .working, project: "Buddy", lastTool: "Edit", updatedAt: now - 40),
            SessionRecord(
                sessionId: "demo-3", state: .finished, project: "website", lastTool: nil, updatedAt: now - 600,
                awaitingMessage: true, lastPrompt: "Make the pricing page work on phones.",
                lastReply: "Done: the pricing cards now stack on narrow screens and the table scrolls sideways. I ran the visual tests; all pass. Next I could tighten the hero spacing, or leave it as is."),
        ]
        for session in sessions { try? await mac.publish(session: session) }
        try? await mac.publish(approval: ApprovalRecord(
            requestId: approvalId, sessionId: "demo-1", status: .pending, tool: "Bash",
            summary: "npm run build && npm test -- --coverage", isTruncated: false, createdAt: now, expiresAt: now + 600))
        try? await mac.publish(question: QuestionRecord(
            requestId: questionId, sessionId: "demo-2", status: .pending,
            questions: [AskQuestion(
                text: "Which database should the sync service use?", header: "Database",
                options: [
                    AskOption(label: "SQLite", description: "One file, nothing to run"),
                    AskOption(label: "Postgres", description: "Shared with the web app"),
                ],
                multiSelect: false)],
            createdAt: now - 20, expiresAt: now + 580))
    }
}
#endif
