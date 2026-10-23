import BuddyKit
import Foundation
import Observation

/// Plays `DemoScript` to the island in place of the engine's snapshots (spec 7). Nothing it holds leaves it: it knows
/// no engine, socket, relay or phone, writes nothing to disk, and answers, decisions, plan choices and "Answer in
/// terminal" only take the card off and move the script on. Started and ended by `AppModel` (`startDemo`).
@MainActor
@Observable
final class DemoFeed: IslandFeed {
    /// Waits that many seconds of the demo's time. The app sleeps; a test passes one that only its cancellation ends,
    /// and steps the demo with `advance()`.
    typealias Wait = @Sendable (TimeInterval) async -> Void

    static let sleep: Wait = { seconds in try? await Task.sleep(for: .seconds(seconds)) }

    private(set) var sessions: [Session] = []
    private(set) var pending: [PendingApproval] = []
    private(set) var questions: [PendingQuestion] = []
    private(set) var questionOutcomes: [QuestionOutcomeRecord] = []
    /// The index of the step on screen; nil before `start()` and once the demo is over.
    private(set) var step: Int?

    /// Called once the last step has had its time (not on `stop()`).
    @ObservationIgnored var onEnd: @MainActor () -> Void = {}

    @ObservationIgnored private let steps: [DemoScript.Step]
    @ObservationIgnored private let end: TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let wait: Wait
    /// Waits for the next step; replaced whenever a step is shown, so only the latest one moves the script on.
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(
        steps: [DemoScript.Step] = DemoScript.steps(), end: TimeInterval = DemoScript.end,
        now: @escaping @Sendable () -> Date = Date.init, wait: @escaping Wait = DemoFeed.sleep
    ) {
        self.steps = steps
        self.end = end
        self.now = now
        self.wait = wait
    }

    isolated deinit {
        timer?.cancel()
    }

    /// Shows the first step.
    func start() {
        guard step == nil, !steps.isEmpty else { return }
        show(0)
    }

    /// Shows the next step, or ends the demo after the last one.
    func advance() {
        guard let step else { return }
        guard step + 1 < steps.count else {
            stop()
            onEnd()
            return
        }
        show(step + 1)
    }

    /// Ends the demo where it is and clears what it showed.
    func stop() {
        timer?.cancel()
        timer = nil
        step = nil
        apply(EngineSnapshot(sessions: [], pending: []))
    }

    /// Shows step `index` with its dates moved so the step happens now, and waits for the next one.
    private func show(_ index: Int) {
        let current = steps[index]
        let shift = now().timeIntervalSince(DemoScript.epoch.addingTimeInterval(current.at))
        step = index
        apply(current.snapshot.shifted(by: shift))
        let next = index + 1 < steps.count ? steps[index + 1].at : end
        timer?.cancel()
        timer = Task { [weak self, wait] in
            await wait(max(0, next - current.at))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    private func apply(_ snapshot: EngineSnapshot) {
        sessions = snapshot.sessions
        pending = snapshot.pending
        questions = snapshot.questions
        questionOutcomes = snapshot.recentQuestionOutcomes
    }

    /// A card of the step on screen was answered: it goes, and the script moves on. False for any other id.
    private func take(_ id: UUID) -> Bool {
        guard pending.contains(where: { $0.id == id }) || questions.contains(where: { $0.id == id }) else { return false }
        advance()
        return true
    }

    func decide(_ id: UUID, _ decision: Decision) async -> Bool { take(id) }

    func decidePlan(_ id: UUID, _ choice: PlanChoice) async -> Bool { take(id) }

    func answer(_ id: UUID, _ responses: [QuestionResponse]) async -> Bool { take(id) }

    func releaseQuestion(_ id: UUID) async { _ = take(id) }
}

private extension EngineSnapshot {
    /// The same snapshot with every date `seconds` later.
    func shifted(by seconds: TimeInterval) -> EngineSnapshot {
        EngineSnapshot(
            sessions: sessions.map {
                var session = $0
                session.updatedAt += seconds
                return session
            },
            pending: pending.map {
                PendingApproval(
                    id: $0.id, sessionId: $0.sessionId, toolName: $0.toolName, toolInput: $0.toolInput,
                    summary: $0.summary, createdAt: $0.createdAt + seconds, expiresAt: $0.expiresAt + seconds,
                    agentId: $0.agentId, kind: $0.kind)
            },
            questions: questions.map {
                PendingQuestion(
                    id: $0.id, sessionId: $0.sessionId, agentId: $0.agentId, questions: $0.questions,
                    createdAt: $0.createdAt + seconds, expiresAt: $0.expiresAt + seconds)
            },
            recentQuestionOutcomes: recentQuestionOutcomes.map {
                QuestionOutcomeRecord(id: $0.id, sessionId: $0.sessionId, outcome: $0.outcome, at: $0.at + seconds)
            })
    }
}
