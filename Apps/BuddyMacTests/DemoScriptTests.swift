import BuddyKit
import Foundation
import Testing

// SAFETY: the engine tests here listen on a temp socket and use an in-memory cloud. Nothing here may touch ~/.claude
// or ~/Library/Application Support/Buddy.

private func shortToken() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

/// Short on purpose: `sockaddr_un` paths are limited to 104 bytes.
private func tempSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/buddy-d\(shortToken()).sock")
}

private func eventJSON(_ name: String, tool: String? = nil, input: JSONValue? = nil) -> String {
    var members: [String: JSONValue] = ["session_id": .string("s1"), "hook_event_name": .string(name)]
    if let tool { members["tool_name"] = .string(tool) }
    if let input { members["tool_input"] = input }
    let data = try! JSONEncoder().encode(JSONValue.object(members))
    return String(decoding: data, as: UTF8.self)
}

/// Runs the blocking `HookClient` (the fake `buddy-hook`) off the cooperative pool.
private func runClient(_ json: String, socket: URL, ask: Bool = false) async -> String? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: HookClient.run(
                input: Data(json.utf8), socketPath: socket, ask: ask, connectTimeout: 5, waitTimeout: 25))
        }
    }
}

/// Polls until `condition` holds (an upper bound only); returns whether it did.
@MainActor
private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A model on `socket` whose settings and support directory are temp paths (never the real ones).
@MainActor
private func makeModel(socket: URL, transport: (any PhoneTransport)? = nil) -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-demo-\(UUID().uuidString)")
    let paths = AppModel.Paths(
        settingsURL: root.appendingPathComponent("claude/settings.json"),
        supportDirectory: root.appendingPathComponent("Buddy", isDirectory: true), hookBinarySource: nil)
    return AppModel(engine: BuddyEngine(socketPath: socket, transport: transport), paths: paths)
}

/// A demo whose clock never moves by itself: the test steps it with `advance()`. Its waits end only when the demo
/// cancels them, so no test sleeps for the script's timing.
@MainActor
private func manualDemo() -> DemoFeed {
    DemoFeed(wait: { _ in try? await Task.sleep(for: .seconds(3600)) })
}

@MainActor
@Suite struct DemoScriptTests {
    // MARK: The script

    /// Every state the island can show comes up in some step (resolved the way the island does, with the island
    /// visible), except dizzy, which only clicks on the character start. And the cards: one single-select and one
    /// multi-select question, the permission "Bash: npm test" and one plan.
    @Test func demoCoversEveryState() throws {
        var states: Set<CharacterState> = []
        for step in DemoScript.steps() {
            let snapshot = step.snapshot
            let now = DemoScript.epoch.addingTimeInterval(step.at)
            let lastEvent = snapshot.sessions.map(\.updatedAt).max() ?? now
            let focused = IslandLogic.focusedSession(
                sessions: snapshot.sessions, pending: snapshot.pending, questions: snapshot.questions, chosen: nil)
            states.insert(IslandLogic.characterState(
                focused: focused, pending: snapshot.pending, questions: snapshot.questions,
                quietFor: now.timeIntervalSince(lastEvent), visible: true, dizzy: false))
        }
        #expect(states == Set(CharacterState.allCases).subtracting([.dizzy]))

        let asked = DemoScript.steps().flatMap(\.snapshot.questions).flatMap(\.questions)
        #expect(asked.contains { !$0.multiSelect })
        #expect(asked.contains { $0.multiSelect })
        let reporter = try #require(asked.first { $0.text == "Which test reporter format?" })
        #expect(reporter.options.map(\.label) == ["Verbose", "Dot", "JSON"])
        #expect(!reporter.multiSelect)

        let approvals = DemoScript.steps().flatMap(\.snapshot.pending)
        #expect(approvals.contains { $0.toolName == "Bash" && $0.summary.text == "npm test" && $0.kind == .tool })
        #expect(approvals.contains { if case .plan = $0.kind { true } else { false } })
    }

    /// Valid questions only (the same rules the engine applies), so every card draws as a real one would.
    @Test func demoQuestionsAreValid() {
        for question in DemoScript.steps().flatMap(\.snapshot.questions) {
            #expect((1...4).contains(question.questions.count))
            for asked in question.questions {
                #expect(!asked.text.isEmpty)
                #expect(!asked.header.isEmpty && asked.header.count <= 12)
                #expect((2...4).contains(asked.options.count))
                #expect(asked.options.allSatisfy { !$0.label.isEmpty })
            }
        }
    }

    /// About 60-90 s in all, steps in order, and each card on screen long enough to read.
    @Test func demoTimingFitsAndCardsStayReadable() {
        let times = DemoScript.steps().map(\.at)
        #expect(times.first == 0)
        #expect(times == times.sorted() && Set(times).count == times.count)
        #expect((60...90).contains(DemoScript.end))
        #expect(DemoScript.end > times.last ?? 0)
        for (index, step) in DemoScript.steps().enumerated()
        where !step.snapshot.pending.isEmpty || !step.snapshot.questions.isEmpty {
            let next = index + 1 < times.count ? times[index + 1] : DemoScript.end
            #expect(next - step.at >= 10, "card step at \(step.at) s")
        }
    }

    /// One fictional session in one fictional project: no real path, no user name.
    @Test func demoUsesOnlyTheFictionalProject() {
        for step in DemoScript.steps() {
            #expect(step.snapshot.sessions.count == 1)
            for session in step.snapshot.sessions {
                #expect(session.project == "demo-app")
                #expect(session.id == DemoScript.sessionId)
            }
            #expect(step.snapshot.pending.allSatisfy { $0.sessionId == DemoScript.sessionId })
            #expect(step.snapshot.questions.allSatisfy { $0.sessionId == DemoScript.sessionId })
        }
    }

    /// Each run builds the script afresh with new request ids, so a replay's cards are new to the island (and their
    /// cues play again).
    @Test func eachRunHasNewRequestIds() {
        func cardIds(_ steps: [DemoScript.Step]) -> Set<UUID> {
            Set(steps.flatMap { $0.snapshot.pending.map(\.id) + $0.snapshot.questions.map(\.id) })
        }
        let first = cardIds(DemoScript.steps()), second = cardIds(DemoScript.steps())
        #expect(first.count == 4)
        #expect(first.isDisjoint(with: second))

        func firstCard(of demo: DemoFeed) -> UUID? {
            demo.start()
            defer { demo.stop() }
            for _ in DemoScript.steps().indices {
                if let id = demo.pending.first?.id { return id }
                demo.advance()
            }
            return nil
        }
        let once = firstCard(of: manualDemo()), again = firstCard(of: manualDemo())
        #expect(once != nil && again != nil)
        #expect(once != again)
    }

    // MARK: The feed

    /// The feed shows each step in turn on its own clock, with the step's times moved to now, and ends after the last
    /// one. With a clock that returns at once the whole script plays through and ends.
    @Test func theFeedReplaysTheScriptOnItsClock() async throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let demo = DemoFeed(now: { start }, wait: { _ in try? await Task.sleep(for: .seconds(3600)) })
        #expect(demo.step == nil && demo.sessions.isEmpty)
        demo.start()
        #expect(demo.step == 0)
        #expect(demo.sessions == DemoScript.steps()[0].snapshot.sessions.map {
            var session = $0
            session.updatedAt = start
            return session
        })
        demo.advance()
        #expect(demo.step == 1)

        // The sleeping step keeps its quiet: its session's last event stays as far before now as in the script.
        let sleepingIndex = try #require(DemoScript.steps().lastIndex { step in
            step.snapshot.sessions.contains { $0.updatedAt < DemoScript.epoch.addingTimeInterval(step.at) }
        })
        while demo.step != sleepingIndex { demo.advance() }
        let script = DemoScript.steps()[sleepingIndex]
        let quiet = DemoScript.epoch.addingTimeInterval(script.at).timeIntervalSince(script.snapshot.sessions[0].updatedAt)
        #expect(quiet >= 120)
        #expect(start.timeIntervalSince(demo.sessions[0].updatedAt) == quiet)

        var ended = 0
        let quick = DemoFeed(wait: { _ in })
        quick.onEnd = { ended += 1 }
        quick.start()
        #expect(await waitUntil { ended == 1 })
        #expect(quick.step == nil)
        #expect(quick.sessions.isEmpty && quick.pending.isEmpty && quick.questions.isEmpty)
    }

    /// Answers, decisions, plan choices and "Answer in terminal" on demo cards never leave the demo: the engine, the
    /// socket and the phone see nothing, the model's state stays as it was. The demo takes the card off and moves on.
    @Test func demoDecisionsDoNothing() async throws {
        let socket = tempSocketURL()
        defer { try? FileManager.default.removeItem(at: socket) }
        let cloud = InMemoryCloud()
        let model = makeModel(socket: socket, transport: cloud.macSide)
        await model.start()
        defer { Task { await model.stop() } }

        let demo = manualDemo()
        model.startDemo(demo)
        #expect(model.isDemoRunning)
        #expect(model.islandFeed === demo)

        var taken = 0
        // At most one turn per step, so a demo that stopped moving on fails instead of hanging.
        for _ in DemoScript.steps().indices {
            guard let step = demo.step else { break }
            if let approval = demo.pending.first {
                // The engine does not know the demo's requests.
                #expect(await model.decide(approval.id, .deny) == false)
                switch approval.kind {
                case .tool: #expect(await demo.decide(approval.id, .allow))
                case .plan: #expect(await demo.decidePlan(approval.id, .acceptEdits))
                }
                taken += 1
                #expect(demo.step == step + 1 || demo.step == nil)
                #expect(!demo.pending.contains { $0.id == approval.id })
            } else if let question = demo.questions.first {
                #expect(await model.answer(question.id, [.options(["Dot"])]) == false)
                if question.questions[0].multiSelect {
                    await demo.releaseQuestion(question.id)
                } else {
                    #expect(await demo.answer(question.id, [.options(["Dot"])]))
                }
                taken += 1
                #expect(demo.step == step + 1 || demo.step == nil)
                #expect(!demo.questions.contains { $0.id == question.id })
            } else {
                // Not a card: unknown ids do nothing and the step stays.
                #expect(await demo.decide(UUID(), .allow) == false)
                #expect(demo.step == step)
                demo.advance()
            }
            #expect(model.sessions.isEmpty && model.pending.isEmpty && model.questions.isEmpty)
            #expect(model.questionOutcomes.isEmpty)
        }
        #expect(demo.step == nil)
        #expect(taken == 4)

        // Nothing reached the phone either.
        var sessions = cloud.phoneSide.sessions().makeAsyncIterator()
        #expect(await sessions.next() == [])
        var approvals = cloud.phoneSide.approvals().makeAsyncIterator()
        #expect(await approvals.next() == [])
        var questions = cloud.phoneSide.questions().makeAsyncIterator()
        #expect(await questions.next() == [])
    }

    // MARK: The model's switch

    /// The island reads the demo while it runs and the model again once it ends: by "Stop demo", or by itself after
    /// the last step.
    @Test func theIslandReturnsToTheEngineWhenTheDemoEnds() async {
        let socket = tempSocketURL()
        defer { try? FileManager.default.removeItem(at: socket) }
        let model = makeModel(socket: socket)
        #expect(!model.isDemoRunning)
        #expect(model.islandFeed === model)

        let demo = manualDemo()
        model.startDemo(demo)
        #expect(model.isDemoRunning && model.islandFeed === demo)
        #expect(demo.step == 0)
        // Starting again while one runs keeps the one running.
        model.startDemo(manualDemo())
        #expect(model.islandFeed === demo)
        model.stopDemo()
        #expect(!model.isDemoRunning && model.islandFeed === model)
        #expect(demo.step == nil)

        let quick = DemoFeed(wait: { _ in })
        model.startDemo(quick)
        #expect(await waitUntil { !model.isDemoRunning })
        #expect(model.islandFeed === model)
    }

    /// A real permission request arriving while the demo runs ends the demo at once, so the island shows it; and no
    /// demo starts while a real one waits.
    @Test func aRealPermissionRequestEndsTheDemo() async throws {
        let socket = tempSocketURL()
        defer { try? FileManager.default.removeItem(at: socket) }
        let model = makeModel(socket: socket)
        await model.start()
        let demo = manualDemo()
        model.startDemo(demo)
        #expect(model.isDemoRunning)

        let client = Task { await runClient(
            eventJSON("PermissionRequest", tool: "Bash", input: .object(["command": .string("ls")])), socket: socket) }
        #expect(await waitUntil { model.pending.count == 1 })
        #expect(!model.isDemoRunning)
        #expect(model.islandFeed === model)
        #expect(demo.step == nil)

        #expect(!model.canStartDemo)
        model.startDemo(manualDemo())
        #expect(!model.isDemoRunning)

        let id = try #require(model.pending.first?.id)
        #expect(await model.decide(id, .deny))
        _ = await client.value
        #expect(await waitUntil { model.pending.isEmpty })
        #expect(model.canStartDemo)
        await model.stop()
    }

    /// The same for a real question.
    @Test func aRealQuestionEndsTheDemo() async throws {
        let socket = tempSocketURL()
        defer { try? FileManager.default.removeItem(at: socket) }
        let model = makeModel(socket: socket)
        await model.start()
        model.startDemo(manualDemo())
        #expect(model.isDemoRunning)

        let input: JSONValue = .object(["questions": .array([.object([
            "question": .string("Which color?"), "header": .string("Color"),
            "options": .array([.object(["label": .string("Red")]), .object(["label": .string("Blue")])]),
            "multiSelect": .bool(false),
        ])])])
        let client = Task { await runClient(
            eventJSON("PreToolUse", tool: "AskUserQuestion", input: input), socket: socket, ask: true) }
        #expect(await waitUntil { model.questions.count == 1 })
        #expect(!model.isDemoRunning)
        #expect(model.islandFeed === model)

        // No demo starts while the real question waits.
        #expect(!model.canStartDemo)
        model.startDemo(manualDemo())
        #expect(!model.isDemoRunning)

        let id = try #require(model.questions.first?.id)
        await model.releaseQuestion(id)
        _ = await client.value
        await model.stop()
    }

    // MARK: The island's switch rules

    /// Back on the model after the demo, the cue baseline is the model's sessions with no card (none waited when the
    /// demo began), so the real request that ended the demo plays its cue, and the sessions themselves play none.
    @Test func theRealCardThatEndsTheDemoIsHeard() {
        let session = Session(id: "s1", project: "buddy", state: .working, updatedAt: Date(), activity: .thinking, starts: 1)
        let approval = PendingApproval(
            id: UUID(), sessionId: "s1", toolName: "Bash", toolInput: nil,
            summary: ToolSummary(text: "ls", isTruncated: false), createdAt: Date(), expiresAt: Date() + 120)
        let question = PendingQuestion(
            id: UUID(), sessionId: "s1", agentId: nil,
            questions: [AskQuestion(text: "Which?", header: "Pick", options: [
                AskOption(label: "A", description: nil), AskOption(label: "B", description: nil),
            ], multiSelect: false)],
            createdAt: Date(), expiresAt: Date() + 120)

        var cues = IslandLogic.afterFeedSwitch(toModel: true, modelSessions: [session], cues: IslandCues()).cues
        #expect(cues.snapshot(EngineSnapshot(sessions: [session], pending: [approval]), terminalFrontmost: false)
            == [.approval])
        cues = IslandLogic.afterFeedSwitch(toModel: true, modelSessions: [session], cues: IslandCues()).cues
        #expect(cues.snapshot(
            EngineSnapshot(sessions: [session], pending: [], questions: [question]), terminalFrontmost: false)
            == [.question])
        // Only the sessions: no sound for what the engine already had.
        cues = IslandLogic.afterFeedSwitch(toModel: true, modelSessions: [session], cues: IslandCues()).cues
        #expect(cues.snapshot(EngineSnapshot(sessions: [session], pending: []), terminalFrontmost: false).isEmpty)
    }

    /// Into the demo, the cues keep their baseline (the real snapshot), so the demo's SessionStart plays `work`. Either
    /// way the chosen session and the questions shown go.
    @Test func switchingToTheDemoKeepsTheCueBaselineAndDropsTheFocus() {
        var real = IslandCues()
        _ = real.snapshot(EngineSnapshot(sessions: [], pending: []), terminalFrontmost: false)
        let toDemo = IslandLogic.afterFeedSwitch(toModel: false, modelSessions: [], cues: real)
        #expect(toDemo.chosenSession == nil && toDemo.shownQuestions.isEmpty)
        var cues = toDemo.cues
        #expect(cues.snapshot(DemoScript.steps()[0].snapshot, terminalFrontmost: false) == [.work])

        let back = IslandLogic.afterFeedSwitch(toModel: true, modelSessions: [], cues: cues)
        #expect(back.chosenSession == nil && back.shownQuestions.isEmpty)
    }

    /// The demo measures quiet from its own session alone and always plays finish and error (its session has no
    /// terminal); the model's feed keeps launch as the earliest start of quiet and skips them under a frontmost terminal.
    @Test func theDemoIsQuietOnItsOwnClockAndAlwaysHeard() {
        let launched = Date(timeIntervalSince1970: 1_000)
        #expect(IslandLogic.quietSince(demo: false, launchedAt: launched) == launched)
        #expect(IslandLogic.quietSince(demo: true, launchedAt: launched) == .distantPast)
        #expect(IslandLogic.cuesSeeTerminalFrontmost(demo: false, terminalFrontmost: true))
        #expect(!IslandLogic.cuesSeeTerminalFrontmost(demo: true, terminalFrontmost: true))
        #expect(!IslandLogic.cuesSeeTerminalFrontmost(demo: false, terminalFrontmost: false))
    }

    /// The menu item reads "Demo" while none runs and "Stop demo" while one does.
    @Test func theMenuItemNamesWhatItDoes() {
        #expect(MenuContentView.demoTitle(running: false) == "Demo")
        #expect(MenuContentView.demoTitle(running: true) == "Stop demo")
    }
}
