import BuddyKit
import Foundation

/// Sample sessions, an approval and a question in an in-memory cloud. "Try a sample" on the session list shows them,
/// so the app can be tried (and reviewed for the App Store) without a Mac: everything stays in this process, and
/// nothing reaches iCloud or a Mac. Debug builds launched with `-BuddyDemo YES` start in it, skipping iCloud, so every
/// screen can be looked at (and screenshotted) in the simulator.
enum SampleCloud {
    static let approvalId = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let questionId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!

    /// A fresh in-memory cloud holding the sample, seeded before it is returned (so the list never shows it empty).
    static func connection(now: Date = Date()) async -> PhoneConnection {
        let cloud = InMemoryCloud()
        await seed(cloud.macSide, now: now)
        return PhoneConnection(transport: cloud.phoneSide, refresh: {})
    }

    private static func seed(_ mac: any PhoneTransport, now: Date) async {
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

    #if DEBUG
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "BuddyDemo") }
    /// `-BuddyDemoTrySample YES`: the real iCloud check, then "Try a sample" as if tapped (banner and all).
    static var triesSampleAtLaunch: Bool { UserDefaults.standard.bool(forKey: "BuddyDemoTrySample") }

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
            Task { await seed(cloud.macSide, now: Date()) }
            return PhoneConnection(transport: cloud.phoneSide, refresh: {})
        },
        accountTimeout: .seconds(90))
    #endif
}
