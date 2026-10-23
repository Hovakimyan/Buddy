import AppKit
import BuddyKit
import Foundation
import Observation
import SwiftUI
import Testing

/// Smoke tests that the island's views actually draw something (a headless run cannot look at them).
/// Set `BUDDY_SNAPSHOT_DIR` to also write the images as PNGs for a visual check.
@MainActor
@Suite struct IslandRenderTests {
    private func render<V: View>(_ view: V, name: String) throws -> CGImage {
        // Outside an app AppKit's scroll view and text field cannot be made (they need the shared application), so the
        // cards draw without them.
        let renderer = ImageRenderer(content: view.environment(\.cardsMakeAppKitViews, false))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["BUDDY_SNAPSHOT_DIR"],
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return image
    }

    /// Pixels that are visibly different from a fully transparent background. The views under test are rendered
    /// without any opaque backdrop, so an empty view counts zero.
    private func drawnPixels(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { count += 1 }
        }
        return count
    }

    /// Control: proves the counting is not vacuous. A transparent, empty view draws nothing.
    @Test func anEmptyViewDrawsNothing() throws {
        let blank = Canvas { _, _ in }.frame(width: 96, height: 96)
        #expect(drawnPixels(try render(blank, name: "empty-canvas")) == 0)
        let text = Text("").frame(width: 96, height: 96)
        #expect(drawnPixels(try render(text, name: "empty-text")) == 0)
    }

    private func approval(_ text: String, truncated: Bool = false, tool: String = "Bash") -> PendingApproval {
        PendingApproval(
            id: UUID(), sessionId: "s1", toolName: tool, toolInput: nil,
            summary: ToolSummary(text: text, isTruncated: truncated),
            createdAt: Date(), expiresAt: Date().addingTimeInterval(110))
    }

    private func card(_ item: PendingApproval) -> some View {
        ApprovalCardView(approval: item, project: "buddy", armed: true, onChoice: { _ in })
            .frame(width: 316)
            .padding(12)
    }

    @Test func approvalCardDraws() throws {
        let short = try render(card(approval("ls")), name: "card")
        #expect(drawnPixels(short) > 1000)
        let truncated = try render(
            card(approval(String(repeating: "echo hello; ", count: 30), truncated: true)), name: "card-truncated")
        #expect(drawnPixels(truncated) > 1000)
    }

    @Test func approvalCardShowsEveryLineOfAMultiLineCommand() throws {
        // More text must draw more pixels at the same width: nothing is cut to a fixed number of lines.
        let one = try render(card(approval("ls")), name: "card-1")
        let four = try render(card(approval("cd /tmp\nls\necho ok\nrm -rf ~/x")), name: "card-4")
        #expect(four.height > one.height)
        #expect(drawnPixels(four) > drawnPixels(one))
    }

    /// Strongly coloured pixels (the buttons are ~85 % opaque, the card background 8 %) in the band where the
    /// buttons sit, found from the bottom of the image.
    private func buttonBandPixels(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        let scale = 2
        let bandBottom = rep.pixelsHigh - (12 + 10) * scale
        let bandTop = bandBottom - 26 * scale
        var strong = 0
        for y in bandTop..<bandBottom {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { strong += 1 }
        }
        return strong
    }

    @Test func theButtonRowSurvivesAnAllEmojiCommand() throws {
        // Even if the text were taller than estimated the buttons must stay on the card.
        let image = try render(card(approval(String(repeating: "✅", count: 200))), name: "card-emoji")
        #expect(buttonBandPixels(image) > 3000)
    }

    @Test func aVeryLongToolNameStaysOnOneLineAndTheButtonsStay() throws {
        let long = approval("ls", tool: String(repeating: "mcp__server__tool_", count: 30))
        let image = try render(card(long), name: "card-long-tool")
        #expect(buttonBandPixels(image) > 3000)
        let normal = try render(card(approval("ls")), name: "card-normal-tool")
        #expect(image.height == normal.height)
    }
    // MARK: Overview, pills and status cards

    private func session(_ index: Int, _ state: SessionState = .working) -> Session {
        Session(
            id: "s\(index)", project: "project-\(index)", state: state,
            updatedAt: Date(timeIntervalSince1970: Double(1000 - index)), recentTools: ["Read", "Edit", "Bash"],
            toolCount: 7)
    }

    private func overview(_ feed: FakeIslandFeed) -> some View {
        let ui = IslandUIState()
        ui.mode = .expanded
        return IslandOverview(feed: feed, ui: ui)
            .frame(width: IslandLayout.expandedWidth)
            .fixedSize(horizontal: false, vertical: true)
    }

    @Test func theOverviewShowsTheFocusedSessionAndUpToFourPills() throws {
        let six = FakeIslandFeed(sessions: (0..<6).map { session($0) })
        let full = try render(overview(six), name: "overview-pills")
        let alone = try render(overview(FakeIslandFeed(sessions: [session(0)])), name: "overview-alone")
        #expect(drawnPixels(alone) > 1000)
        // The pills add a row; six sessions still give one row (the focused one and four pills).
        #expect(full.height > alone.height)
        #expect(drawnPixels(full) > drawnPixels(alone) + 1000)
        let five = try render(overview(FakeIslandFeed(sessions: (0..<5).map { session($0) })), name: "overview-five")
        #expect(five.height == full.height)
    }

    @Test func theOverviewWithoutSessionsStillDraws() throws {
        let image = try render(overview(FakeIslandFeed(sessions: [])), name: "overview-empty")
        #expect(drawnPixels(image) > 500)
    }

    @Test func theOverviewShowsTheApprovalCardWhenOneIsWaiting() throws {
        let feed = FakeIslandFeed(sessions: [session(0)])
        let plain = try render(overview(feed), name: "overview-no-card")
        feed.pending = [approval("ls -la")]
        let withCard = try render(overview(feed), name: "overview-card")
        #expect(withCard.height > plain.height)
    }

    // MARK: Question and plan cards

    private func pendingQuestion(_ questions: [AskQuestion]) -> PendingQuestion {
        PendingQuestion(
            id: UUID(), sessionId: "s0", agentId: nil, questions: questions, createdAt: Date(),
            expiresAt: Date().addingTimeInterval(120))
    }

    private func colours(descriptions: [String?] = [nil, nil, nil], multi: Bool = false) -> AskQuestion {
        AskQuestion(
            text: "Which colour should the button be?", header: "Colour",
            options: zip(["Red", "Green", "Blue"], descriptions).map { AskOption(label: $0, description: $1) },
            multiSelect: multi)
    }

    private func questionCard(_ model: QuestionCardModel) -> some View {
        QuestionCardView(model: model, height: model.naturalHeight, armed: true, onEvent: { _ in }, otherText: .constant(""))
            .frame(width: 616)
            .padding(12)
    }

    @Test func aQuestionWithoutDescriptionsDrawsItsOptionsAsChips() throws {
        let model = QuestionCardModel(question: pendingQuestion([colours(), colours(multi: true)]))
        let image = try render(questionCard(model), name: "question-chips")
        #expect(drawnPixels(image) > 3000)
    }

    @Test func aQuestionWithDescriptionsDrawsAList() throws {
        let chips = QuestionCardModel(question: pendingQuestion([colours()]))
        let list = QuestionCardModel(question: pendingQuestion([colours(descriptions: ["warm", "calm", "cool"])]))
        let chipsImage = try render(questionCard(chips), name: "question-chips-single")
        let listImage = try render(questionCard(list), name: "question-list")
        #expect(drawnPixels(listImage) > 3000)
        // The list stacks the options, so it is taller than the row of chips.
        #expect(listImage.height > chipsImage.height)
    }

    @Test func theOtherFieldDraws() throws {
        var model = QuestionCardModel(question: pendingQuestion([colours()]))
        let closed = try render(questionCard(model), name: "question-other-closed")
        model.openOther()
        let open = try render(questionCard(model), name: "question-other-open")
        #expect(drawnPixels(open) > 3000)
        // A single-select question has no Send until the field opens.
        #expect(open.height > closed.height)
    }

    private func plan(_ text: String) -> PendingApproval {
        PendingApproval(
            id: UUID(), sessionId: "s0", toolName: "ExitPlanMode", toolInput: nil,
            summary: ToolSummary(text: "ExitPlanMode", isTruncated: false), createdAt: Date(),
            expiresAt: Date().addingTimeInterval(105), kind: .plan(text: text))
    }

    @Test func thePlanCardDraws() throws {
        let short = plan("1. Read the file\n2. Fix the bug\n3. Run the tests")
        let view = PlanCardView(
            approval: short, height: PlanCardView.naturalHeight(for: short), armed: true, onChoice: { _ in },
            accent: .orange)
            .frame(width: 616).padding(12)
        let image = try render(view, name: "plan")
        #expect(drawnPixels(image) > 3000)
        #expect(buttonBandPixels(image) > 3000)
    }

    @Test func aLongPlanScrollsInsideItsCard() throws {
        let long = plan((1...200).map { "Step \($0): change something" }.joined(separator: "\n"))
        #expect(PlanCardView.naturalHeight(for: long) == PlanCardView.maxHeight)
        let view = PlanCardView(approval: long, height: 300, armed: true, onChoice: { _ in }, accent: .orange)
            .frame(width: 616).padding(12)
        let image = try render(view, name: "plan-long")
        #expect(image.height == (300 + 24) * 2)
        #expect(buttonBandPixels(image) > 3000)
    }

    @Test func theOverviewShowsTheQuestionOrPlanInFront() throws {
        let feed = FakeIslandFeed(sessions: [session(0)])
        let plain = try render(overview(feed), name: "overview-no-question")
        feed.questions = [pendingQuestion([colours()])]
        let asking = try render(overview(feed), name: "overview-question")
        #expect(asking.height > plain.height)
        feed.questions = []
        feed.pending = [plan("Do the thing")]
        let planning = try render(overview(feed), name: "overview-plan")
        #expect(planning.height > plain.height)
    }

    @Test func theCompactIslandDraws() throws {
        let ui = IslandUIState()
        ui.mode = .compact
        ui.placement = IslandPlacement(hasNotch: true, notchWidth: 185, barHeight: 32, centerX: 0, top: 0)
        let view = CompactIsland(feed: FakeIslandFeed(sessions: [session(0)]), ui: ui)
            .frame(width: 185 + IslandLayout.compactExtraWidth, height: 32)
        #expect(drawnPixels(try render(view, name: "compact")) > 400)
    }

    private func statusCard(_ kind: StatusCardKind) -> some View {
        StatusCardView(kind: kind, accent: .orange, onOK: {}).frame(width: 616).padding(12)
    }

    @Test(arguments: [
        StatusCardKind.error(details: "buddy, after Bash"), .finished(lastLine: "buddy, 12 steps"), .dizzy,
        .answered(where: "the terminal"), .stillWaiting,
    ])
    func everyStatusCardDraws(kind: StatusCardKind) throws {
        let image = try render(statusCard(kind), name: "status-\(kind.title.prefix(12))")
        #expect(drawnPixels(image) > 1000)
    }

    @Test func statusCardsLookDifferent() throws {
        let error = try render(statusCard(.error(details: "buddy")), name: "status-error")
        let finished = try render(statusCard(.finished(lastLine: "buddy")), name: "status-finished")
        let dizzy = try render(statusCard(.dizzy), name: "status-dizzy")
        #expect(pixelsDiffer(error, finished))
        #expect(pixelsDiffer(error, dizzy))
        #expect(pixelsDiffer(finished, dizzy))
    }

    private func pill(_ state: CharacterState, _ badge: PillBadge?) -> some View {
        SessionPill(
            session: session(1), state: state, badge: badge, character: Block(), reduceMotion: true, onTap: {}
        )
        .frame(width: 140)
    }

    @Test func aPillTellsAnApprovalFromAQuestion() throws {
        let approval = try render(pill(.approval, .approval), name: "pill-approval")
        let question = try render(pill(.question, .question), name: "pill-question")
        let none = try render(pill(.working, nil), name: "pill-working")
        #expect(drawnPixels(approval) > 300)
        #expect(pixelsDiffer(approval, question))
        #expect(solidPixels(approval) > solidPixels(none))
    }

    @Test(arguments: [PillBadge.approval, .question, .done, .failed])
    func everyPillBadgeDraws(badge: PillBadge) throws {
        let with = try render(pill(.working, badge), name: "pill-badge-\(badge)")
        let without = try render(pill(.working, nil), name: "pill-badge-none")
        #expect(solidPixels(with) > solidPixels(without))
    }

    /// Pixels drawn at least half opaque: the pill's tinted background counts as drawn everywhere, its text, character
    /// and badge are solid.
    private func solidPixels(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 }
        }
        return count
    }

    /// Pixels whose alpha differs by more than a little between two images of the same size.
    private func pixelsDiffer(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return true }
        let ra = NSBitmapImageRep(cgImage: a), rb = NSBitmapImageRep(cgImage: b)
        var changed = 0
        for y in 0..<ra.pixelsHigh {
            for x in 0..<ra.pixelsWide {
                let ca = ra.colorAt(x: x, y: y), cb = rb.colorAt(x: x, y: y)
                if abs((ca?.alphaComponent ?? 0) - (cb?.alphaComponent ?? 0)) > 0.1
                    || abs((ca?.redComponent ?? 0) - (cb?.redComponent ?? 0)) > 0.1 { changed += 1 }
            }
        }
        return changed > 10
    }
}

/// The island's data without an engine: the views only read it.
@MainActor
@Observable
final class FakeIslandFeed: IslandFeed {
    var sessions: [Session]
    var pending: [PendingApproval] = []
    var questions: [PendingQuestion] = []
    var questionOutcomes: [QuestionOutcomeRecord] = []
    private(set) var decisions: [(UUID, Decision)] = []

    init(sessions: [Session]) { self.sessions = sessions }

    func decide(_ id: UUID, _ decision: Decision) async -> Bool {
        decisions.append((id, decision))
        return true
    }
    func decidePlan(_ id: UUID, _ choice: PlanChoice) async -> Bool { false }
    func answer(_ id: UUID, _ responses: [QuestionResponse]) async -> Bool { false }
    func releaseQuestion(_ id: UUID) async {}
}
