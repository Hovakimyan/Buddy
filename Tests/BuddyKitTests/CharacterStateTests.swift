import Foundation
import Testing
@testable import BuddyKit

@Suite struct CharacterStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        _ state: SessionState,
        activity: SessionActivity = .none,
        id: String = "s1",
        updatedAt: Date? = nil
    ) -> Session {
        Session(id: id, project: "proj", state: state, updatedAt: updatedAt ?? t0, activity: activity)
    }

    private func resolve(
        _ session: Session?,
        approval: Bool = false,
        question: Bool = false,
        quietFor: TimeInterval = 0,
        visible: Bool = true
    ) -> CharacterState {
        CharacterState.resolve(
            session: session, approvalPending: approval, questionPending: question,
            quietFor: quietFor, islandVisible: visible)
    }

    // MARK: Pending cards and precedence

    @Test func questionPendingWinsOverEverything() {
        #expect(resolve(session(.error), approval: true, question: true) == .question)
        #expect(resolve(nil, question: true) == .question)
    }

    @Test func approvalPendingWinsOverStatusAndActivity() {
        #expect(resolve(session(.working, activity: .asking), approval: true) == .approval)
        #expect(resolve(session(.finished), approval: true) == .approval)
        #expect(resolve(nil, approval: true) == .approval)
    }

    @Test func askingActivityIsAQuestion() {
        #expect(resolve(session(.waiting, activity: .asking)) == .question)
        #expect(resolve(session(.working, activity: .asking)) == .question)
    }

    // MARK: Status mapping

    @Test func errorHoldsWhateverTheQuietTime() {
        #expect(resolve(session(.error), quietFor: 0) == .error)
        #expect(resolve(session(.error), quietFor: 600) == .error)
    }

    @Test func finishedShowsForFiveSecondsThenIdle() {
        #expect(resolve(session(.finished), quietFor: 4) == .finished)
        #expect(resolve(session(.finished), quietFor: 5) == .idle)
    }

    @Test func finishedThenSleepsAfterTwoMinutes() {
        #expect(resolve(session(.finished), quietFor: 120) == .sleeping)
    }

    @Test func workingMapsActivity() {
        #expect(resolve(session(.working)) == .working)
        #expect(resolve(session(.working, activity: .thinking)) == .thinking)
        #expect(resolve(session(.working, activity: .searching)) == .searching)
        #expect(resolve(session(.working, activity: .rateLimited)) == .rateLimited)
    }

    @Test func waitingWithoutACardCountsAsWorking() {
        #expect(resolve(session(.waiting)) == .working)
        #expect(resolve(session(.waiting, activity: .searching)) == .searching)
    }

    @Test func workingNeverSleeps() {
        #expect(resolve(session(.working), quietFor: 600) == .working)
        #expect(resolve(session(.working, activity: .thinking), quietFor: 600) == .thinking)
    }

    // MARK: Idle and sleeping

    @Test func idleSleepsAtTwoMinutesWhenIslandVisible() {
        #expect(resolve(session(.idle), quietFor: 119) == .idle)
        #expect(resolve(session(.idle), quietFor: 120) == .sleeping)
    }

    @Test func idleDoesNotSleepWhenIslandHidden() {
        #expect(resolve(session(.idle), quietFor: 600, visible: false) == .idle)
    }

    @Test func noSessionIsIdleThenSleeping() {
        #expect(resolve(nil) == .idle)
        #expect(resolve(nil, quietFor: 119) == .idle)
        #expect(resolve(nil, quietFor: 120) == .sleeping)
        #expect(resolve(nil, quietFor: 120, visible: false) == .idle)
    }

    @Test func resolveNeverReturnsDizzy() {
        let states: [SessionState] = [.idle, .working, .waiting, .finished, .error]
        let activities: [SessionActivity] = [.none, .thinking, .searching, .rateLimited, .asking]
        for state in states {
            for activity in activities {
                for quiet in [0.0, 4, 5, 119, 120, 1000] {
                    for (approval, question) in [(false, false), (true, false), (false, true), (true, true)] {
                        let result = resolve(
                            session(state, activity: activity), approval: approval, question: question,
                            quietFor: quiet)
                        #expect(result != .dizzy)
                    }
                }
            }
        }
        #expect(resolve(nil, quietFor: 1000) != .dizzy)
    }

    // MARK: SessionFocus

    @Test func focusIsNilWithoutSessions() {
        #expect(SessionFocus.focused(sessions: [], approvalSessionIds: ["x"], questionSessionIds: [], chosen: "y") == nil)
    }

    @Test func focusPrefersApprovalsThenQuestionsInOrder() {
        let sessions = [session(.idle, id: "a", updatedAt: t0 + 9), session(.idle, id: "b", updatedAt: t0 + 5),
                        session(.idle, id: "c", updatedAt: t0 + 1)]
        #expect(SessionFocus.focused(
            sessions: sessions, approvalSessionIds: ["c", "b"], questionSessionIds: ["a"], chosen: "a") == "c")
        #expect(SessionFocus.focused(
            sessions: sessions, approvalSessionIds: [], questionSessionIds: ["b", "c"], chosen: "a") == "b")
    }

    @Test func focusSkipsPendingIdsThatAreNotLiveSessions() {
        let sessions = [session(.idle, id: "a", updatedAt: t0 + 9), session(.idle, id: "b", updatedAt: t0 + 5)]
        #expect(SessionFocus.focused(
            sessions: sessions, approvalSessionIds: ["gone"], questionSessionIds: ["b"], chosen: "a") == "b")
    }

    @Test func focusFallsBackToChosenWhenLive() {
        let sessions = [session(.idle, id: "a", updatedAt: t0 + 9), session(.idle, id: "b", updatedAt: t0 + 5)]
        #expect(SessionFocus.focused(
            sessions: sessions, approvalSessionIds: [], questionSessionIds: [], chosen: "b") == "b")
    }

    @Test func focusFallsBackToMostRecentWhenChosenIsMissingOrGone() {
        let sessions = [session(.idle, id: "b", updatedAt: t0 + 5), session(.idle, id: "a", updatedAt: t0 + 9)]
        #expect(SessionFocus.focused(
            sessions: sessions, approvalSessionIds: [], questionSessionIds: [], chosen: nil) == "a")
        #expect(SessionFocus.focused(
            sessions: sessions, approvalSessionIds: [], questionSessionIds: [], chosen: "gone") == "a")
    }
}
