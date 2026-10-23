import CoreGraphics
import Testing

@Suite struct IslandGeometryTests {
    // A built-in display shaped like a 14-inch laptop's: 1512 x 982 points at the origin, a notch 184 wide and
    // 32 tall in the middle (the menu-bar areas either side are 664 wide).
    private let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
        auxiliaryLeft: CGRect(x: 0, y: 950, width: 664, height: 32),
        auxiliaryRight: CGRect(x: 848, y: 950, width: 664, height: 32),
        menuBarHeight: 32)
    // An external display without a notch, with a 24-point menu bar.
    private let plain = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0,
        auxiliaryLeft: nil, auxiliaryRight: nil, menuBarHeight: 24)

    private func notchedScreen(
        frame: CGRect, top: CGFloat = 32, left: CGRect?, right: CGRect?
    ) -> ScreenMetrics {
        ScreenMetrics(frame: frame, safeAreaTop: top, auxiliaryLeft: left, auxiliaryRight: right, menuBarHeight: top)
    }

    // MARK: Placement on a screen with a notch

    @Test func theNotchIsTheGapBetweenTheTwoMenuBarAreas() {
        #expect(IslandGeometry.placement(for: notched)
            == IslandPlacement(hasNotch: true, notchWidth: 184, barHeight: 32, centerX: 756, top: 982))
    }

    @Test func aNotchOffTheMiddleIsCentredWhereItReallyIs() {
        let screen = notchedScreen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            left: CGRect(x: 0, y: 950, width: 600, height: 32),
            right: CGRect(x: 790, y: 950, width: 722, height: 32))
        let p = IslandGeometry.placement(for: screen)
        #expect(p.notchWidth == 190)
        #expect(p.centerX == 695)
    }

    @Test func aSecondScreenAwayFromTheOriginKeepsItsOffset() {
        // 1728 x 1117 to the right of and above the main screen, areas in global coordinates.
        let screen = notchedScreen(
            frame: CGRect(x: 1512, y: 200, width: 1728, height: 1117), top: 38,
            left: CGRect(x: 1512, y: 1279, width: 760, height: 38),
            right: CGRect(x: 2480, y: 1279, width: 760, height: 38))
        #expect(IslandGeometry.placement(for: screen)
            == IslandPlacement(hasNotch: true, notchWidth: 208, barHeight: 38, centerX: 2376, top: 1317))
    }

    @Test func areasRelativeToTheScreenGiveTheSamePlacementAsGlobalOnes() {
        for frame in [
            CGRect(x: 1512, y: 200, width: 1728, height: 1117),
            CGRect(x: -1728, y: -300, width: 1728, height: 1117),
            CGRect(x: 0, y: 0, width: 1728, height: 1117),
        ] {
            let local = notchedScreen(
                frame: frame, top: 38,
                left: CGRect(x: 0, y: 1079, width: 760, height: 38),
                right: CGRect(x: 968, y: 1079, width: 760, height: 38))
            let global = notchedScreen(
                frame: frame, top: 38,
                left: CGRect(x: frame.minX, y: frame.maxY - 38, width: 760, height: 38),
                right: CGRect(x: frame.minX + 968, y: frame.maxY - 38, width: 760, height: 38))
            let p = IslandGeometry.placement(for: local)
            #expect(p == IslandGeometry.placement(for: global))
            #expect(p.centerX == frame.midX)
            #expect(p.notchWidth == 208)
        }
    }

    @Test func missingOrOneSidedAreasFallBackToACentredNotchOfTheDefaultWidth() {
        let frame = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 1512, y: 950, width: 600, height: 32)
        let right = CGRect(x: 2424, y: 950, width: 600, height: 32)
        for (l, r) in [(nil, nil), (left, nil), (nil, right)] as [(CGRect?, CGRect?)] {
            let p = IslandGeometry.placement(for: notchedScreen(frame: frame, left: l, right: r))
            #expect(p == IslandPlacement(
                hasNotch: true, notchWidth: IslandGeometry.defaultNotchWidth, barHeight: 32,
                centerX: frame.midX, top: frame.maxY))
        }
    }

    @Test func areasThatLeaveNoSensibleGapFallBack() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let cases: [(CGRect, CGRect)] = [
            // Overlapping.
            (CGRect(x: 0, y: 950, width: 800, height: 32), CGRect(x: 700, y: 950, width: 812, height: 32)),
            // Touching: no gap at all.
            (CGRect(x: 0, y: 950, width: 756, height: 32), CGRect(x: 756, y: 950, width: 756, height: 32)),
            // The wrong way round.
            (CGRect(x: 900, y: 950, width: 612, height: 32), CGRect(x: 0, y: 950, width: 600, height: 32)),
            // Empty areas at the very edges: the "notch" would be the whole screen.
            (CGRect(x: 0, y: 950, width: 0, height: 32), CGRect(x: 1512, y: 950, width: 0, height: 32)),
        ]
        for (left, right) in cases {
            let p = IslandGeometry.placement(for: notchedScreen(frame: frame, left: left, right: right))
            #expect(p.hasNotch)
            #expect(p.notchWidth == IslandGeometry.defaultNotchWidth)
            #expect(p.centerX == 756)
            #expect(p.barHeight == 32)
        }
    }

    // MARK: Placement on a screen without a notch

    @Test func aScreenWithoutANotchGetsACentredBarAsTallAsTheMenuBar() {
        #expect(IslandGeometry.placement(for: plain)
            == IslandPlacement(
                hasNotch: false, notchWidth: IslandGeometry.noNotchBarWidth, barHeight: 24, centerX: 720, top: 900))
        var moved = plain
        moved.frame = CGRect(x: -1440, y: 120, width: 1440, height: 900)
        let p = IslandGeometry.placement(for: moved)
        #expect(p.centerX == -720)
        #expect(p.top == 1020)
    }

    @Test func anAutoHiddenMenuBarStillGetsTheMinimumBar() {
        var hidden = plain
        hidden.menuBarHeight = 0
        #expect(IslandGeometry.placement(for: hidden).barHeight == IslandGeometry.minimumBarHeight)
        #expect(IslandGeometry.minimumBarHeight > 0)
    }

    @Test func aVeryTallMenuBarIsCapped() {
        var tall = plain
        tall.menuBarHeight = 300
        #expect(IslandGeometry.placement(for: tall).barHeight == IslandGeometry.maximumBarHeight)
    }

    // MARK: Size and frame

    private func size(
        _ mode: IslandMode, others: Int = 0, card: IslandContent.Card = .none, _ p: IslandPlacement
    ) -> CGSize {
        IslandGeometry.panelSize(mode: mode, content: IslandContent(otherSessions: others, card: card), placement: p)
    }

    @Test func layoutValues() {
        #expect(IslandLayout.compactExtraWidth == 160)
        #expect(IslandLayout.expandedWidth == 640)
        #expect(IslandLayout.questionMaxHeight == 560)
        #expect(IslandLayout.maxPills == 4)
        #expect(IslandLayout.pillCharacterSize == 12)
    }

    /// The card's command text is as wide as the expanded island leaves it: the panel, less the side padding, the
    /// card's padding and the text box's padding.
    @Test func theCardTextWidthComesFromTheExpandedWidth() {
        let expected: CGFloat = 640 - 24 - 20 - 16
        #expect(IslandLayout.minimumCardTextWidth == expected)
    }

    @Test func panelHangsFromTheTopEdgeCentredOnThePlacement() {
        let p = IslandGeometry.placement(for: notched)
        for mode in [IslandMode.compact, .expanded] {
            let s = size(mode, p)
            let frame = IslandGeometry.panelFrame(size: s, placement: p)
            #expect(frame.midX == p.centerX)
            #expect(frame.maxY == p.top)
            #expect(frame.size == s)
        }
    }

    @Test func compactIsTheNotchPlusTheExtraWidthAndAsTallAsTheBar() {
        let p = IslandGeometry.placement(for: notched)
        #expect(size(.compact, p) == CGSize(width: p.notchWidth + IslandLayout.compactExtraWidth, height: p.barHeight))
        // What the expanded island would hold does not change the compact one.
        #expect(size(.compact, others: 3, card: .approval(lines: 4), p) == size(.compact, p))
        let bar = IslandGeometry.placement(for: plain)
        #expect(size(.compact, bar).width == bar.notchWidth + IslandLayout.compactExtraWidth)
    }

    @Test func expandedHasTheFixedWidth() {
        let p = IslandGeometry.placement(for: notched)
        #expect(size(.expanded, p).width == IslandLayout.expandedWidth)
        #expect(size(.expanded, others: 4, card: .approval(lines: 3), p).width == IslandLayout.expandedWidth)
    }

    @Test func expandedIsTheHeaderTheFocusedSessionThePillsAndTheCard() {
        let p = IslandGeometry.placement(for: notched)
        let alone = size(.expanded, p)
        #expect(alone.height == p.barHeight + IslandLayout.focusHeight + IslandLayout.bottomPadding)
        let pills = size(.expanded, others: 1, p)
        #expect(pills.height == alone.height + IslandLayout.pillHeight + IslandLayout.pillSpacing)
        #expect(size(.expanded, others: 4, p) == pills)
        let card = size(.expanded, others: 1, card: .approval(lines: 1), p)
        #expect(card.height == pills.height + IslandLayout.cardSpacing + IslandLayout.cardHeight(lines: 1))
        let status = size(.expanded, card: .status, p)
        #expect(status.height == alone.height + IslandLayout.cardSpacing + IslandLayout.statusCardHeight)
    }

    @Test func cardHeightGrowsWithItsLinesAndIsBounded() {
        #expect(IslandLayout.cardHeight(lines: 2) == IslandLayout.cardHeight(lines: 1) + IslandLayout.summaryLineHeight)
        #expect(IslandLayout.cardHeight(lines: 0) == IslandLayout.cardHeight(lines: 1))
        #expect(IslandLayout.cardHeight(lines: 99) == IslandLayout.cardHeight(lines: CardText.maxLines))
        let p = IslandGeometry.placement(for: notched)
        let small = size(.expanded, card: .approval(lines: 1), p)
        let tall = size(.expanded, card: .approval(lines: 5), p)
        #expect(tall.height == small.height + 4 * IslandLayout.summaryLineHeight)
    }

    @Test func expandedHeightIsClampedToTheQuestionMaximum() {
        // The real header and card never reach the maximum; a very tall bar does.
        let tall = IslandPlacement(hasNotch: true, notchWidth: 200, barHeight: 500, centerX: 0, top: 0)
        #expect(size(.expanded, others: 4, card: .approval(lines: 8), tall).height == IslandLayout.questionMaxHeight)
        #expect(size(.expanded, others: 4, card: .approval(lines: 8), IslandGeometry.placement(for: notched)).height
            < IslandLayout.questionMaxHeight)
    }

    /// A question or plan card takes what it needs, but the island never passes the maximum: the card gets the room
    /// that is left (`cardRoom`) and scrolls inside it.
    @Test func questionAndPlanCardsTakeTheirHeightUpToTheRoomLeft() {
        let p = IslandGeometry.placement(for: notched)
        let alone = size(.expanded, others: 2, p)
        for card in [IslandContent.Card.question(height: 120), .plan(height: 120)] {
            #expect(size(.expanded, others: 2, card: card, p).height == alone.height + IslandLayout.cardSpacing + 120)
        }
        let room = IslandGeometry.cardRoom(placement: p, otherSessions: 2)
        #expect(room == IslandLayout.questionMaxHeight - alone.height - IslandLayout.cardSpacing)
        #expect(size(.expanded, others: 2, card: .question(height: room), p).height == IslandLayout.questionMaxHeight)
        #expect(size(.expanded, others: 2, card: .question(height: 2000), p).height == IslandLayout.questionMaxHeight)
        #expect(IslandGeometry.cardRoom(placement: p, otherSessions: 0) > room)
    }

    /// The focused session's subagents add one strip under it, whatever their number; it shrinks the card's room.
    @Test func agentStripAddsOneRow() {
        let p = IslandGeometry.placement(for: notched)
        let plain = IslandGeometry.panelSize(
            mode: .expanded, content: IslandContent(otherSessions: 1, card: .none), placement: p)
        for agents in [1, 3, 7] {
            let withAgents = IslandGeometry.panelSize(
                mode: .expanded, content: IslandContent(otherSessions: 1, card: .none, agents: agents), placement: p)
            #expect(withAgents.height == plain.height + IslandLayout.agentStripHeight + IslandLayout.pillSpacing)
        }
        #expect(IslandGeometry.cardRoom(placement: p, otherSessions: 1, agents: 2)
            == IslandGeometry.cardRoom(placement: p, otherSessions: 1) - IslandLayout.agentStripHeight - IslandLayout.pillSpacing)
    }

    @Test func hiddenHasNoPanelAndRestsAsTheNotch() {
        let p = IslandGeometry.placement(for: notched)
        #expect(size(.hidden, others: 3, p) == .zero)
        #expect(IslandGeometry.restingSize(placement: p) == CGSize(width: p.notchWidth, height: p.barHeight))
    }

    /// The compact character fits the bar with room above and below, never smaller than a pill's.
    @Test func theCompactCharacterFitsTheBar() {
        for bar: CGFloat in [22, 24, 32, 37, 40] {
            let side = IslandLayout.compactCharacterSize(barHeight: bar)
            #expect(side < bar)
            #expect(side >= bar * 0.7)
            #expect(side >= IslandLayout.pillCharacterSize)
        }
        // On a notch (about 32 pt or more) it is big enough for Block's badges.
        #expect(IslandLayout.compactCharacterSize(barHeight: 32) >= 24)
        #expect(IslandLayout.compactCharacterSize(barHeight: 500) == IslandLayout.focusCharacterSize)
    }

    // MARK: Hover

    @Test func hiddenHoverZoneIsTheNotchAtTheTopEdge() {
        let p = IslandGeometry.placement(for: notched)
        let zone = IslandGeometry.hoverRect(mode: .hidden, panelFrame: .zero, placement: p)
        #expect(zone.width == p.notchWidth)
        #expect(zone.maxY == p.top)
        #expect(zone.midX == p.centerX)
        #expect(IslandGeometry.isInside(CGPoint(x: 756, y: 982), zone))  // the very top edge counts
        #expect(IslandGeometry.isInside(CGPoint(x: 300, y: 982), zone) == false)
    }

    @Test func shownHoverZoneIsThePanel() {
        let p = IslandGeometry.placement(for: notched)
        for mode in [IslandMode.compact, .expanded] {
            let frame = IslandGeometry.panelFrame(size: size(mode, p), placement: p)
            #expect(IslandGeometry.hoverRect(mode: mode, panelFrame: frame, placement: p) == frame)
        }
    }

    // MARK: Screen choice

    private func candidate(_ id: Int, notch: Bool = false, main: Bool = false) -> ScreenCandidate {
        ScreenCandidate(id: id, hasNotch: notch, isMain: main)
    }

    @Test func theMainScreenWinsWhenItHasANotch() {
        let screens = [candidate(4, notch: true), candidate(9, notch: true, main: true), candidate(2, main: false)]
        #expect(IslandGeometry.chooseScreen(screens) == 9)
    }

    @Test func aNotchedScreenBeatsAMainScreenWithoutOne() {
        let screens = [candidate(3, main: true), candidate(8, notch: true), candidate(5, notch: true)]
        #expect(IslandGeometry.chooseScreen(screens) == 8)
    }

    @Test func withoutANotchTheMainScreenWins() {
        #expect(IslandGeometry.chooseScreen([candidate(4), candidate(6, main: true)]) == 6)
    }

    @Test func otherwiseTheFirstScreenAndNilWithoutScreens() {
        #expect(IslandGeometry.chooseScreen([candidate(11), candidate(12)]) == 11)
        #expect(IslandGeometry.chooseScreen([]) == nil)
    }

    @Test func theResultIsTheCandidatesIdNotItsPosition() {
        #expect(IslandGeometry.chooseScreen([candidate(40), candidate(30, notch: true)]) == 30)
    }
}
