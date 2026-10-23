import CoreGraphics

/// What the geometry needs to know about a screen, as plain values (copied from `NSScreen` by the window
/// controller) so the placement maths is unit-tested without a display. `frame` is in global screen
/// coordinates (y up), like `NSScreen.frame`; of the auxiliary areas only their horizontal edges are used.
struct ScreenMetrics: Equatable, Sendable {
    var frame: CGRect
    /// `NSScreen.safeAreaInsets.top`: above zero only on a screen with a notch.
    var safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: the menu-bar areas left and right of the notch.
    var auxiliaryLeft: CGRect?
    var auxiliaryRight: CGRect?
    /// Height of the menu bar on this screen right now (0 when it is auto-hidden).
    var menuBarHeight: CGFloat
}

/// Where the island sits on one screen.
struct IslandPlacement: Equatable, Sendable {
    var hasNotch: Bool
    /// The notch's width, or the width of the resting bar on a screen without one.
    var notchWidth: CGFloat
    /// Height of the top bar: the notch's height, or the menu bar's on a screen without a notch.
    var barHeight: CGFloat
    /// Horizontal centre of the notch (screen centre without one), in global coordinates.
    var centerX: CGFloat
    /// The screen's top edge (`frame.maxY`); the island hangs from it.
    var top: CGFloat
}

/// A screen as the chooser sees it.
struct ScreenCandidate: Equatable, Sendable {
    var id: Int
    var hasNotch: Bool
    /// The screen of the active (key) window, `NSScreen.main`.
    var isMain: Bool
}

/// Sizes shared by the geometry and the SwiftUI views (the panel is sized to the content, so both must agree).
enum IslandLayout {
    /// The compact island is the notch plus this much (the character and a status word either side).
    static let compactExtraWidth: CGFloat = 160
    static let expandedWidth: CGFloat = 640
    /// The expanded island never grows taller than this, however much it holds.
    static let questionMaxHeight: CGFloat = 560
    /// Other sessions shown as pills under the focused one.
    static let maxPills = 4
    /// The focused session: the character beside the project, its steps and its last three tools.
    static let focusHeight: CGFloat = 68
    static let focusCharacterSize: CGFloat = 44
    static let pillHeight: CGFloat = 24
    static let pillSpacing: CGFloat = 6
    /// The pill's character, the size the character contract names for pills.
    static let pillCharacterSize: CGFloat = 12
    static let bottomPadding: CGFloat = 10
    /// Height of one line of the card's command text (11 pt monospaced, a little generous).
    static let summaryLineHeight: CGFloat = 14
    /// Everything in the card except the command text: padding, header, buttons, spacing.
    static let cardBaseHeight: CGFloat = 92
    static let cardSpacing: CGFloat = 8
    /// An error, finished or dizzy card: title, one line of detail and OK.
    static let statusCardHeight: CGFloat = 58
    static let sidePadding: CGFloat = 12
    /// Padding inside the card, and either side of the command text inside it.
    static let cardPadding: CGFloat = 10
    static let textHorizontalPadding: CGFloat = 8
    /// Width of the card's command text in the expanded island: what `CardText.columns` must fit.
    static let minimumCardTextWidth: CGFloat =
        expandedWidth - 2 * sidePadding - 2 * cardPadding - 2 * textHorizontalPadding

    /// The card's height for a command shown on `lines` lines (at least one, at most `CardText.maxLines`).
    static func cardHeight(lines: Int) -> CGFloat {
        cardBaseHeight + CGFloat(min(max(lines, 1), CardText.maxLines)) * summaryLineHeight
    }

    /// The compact island's character: as tall as fits in the bar with a little room above and below (the bar is
    /// the notch's height, or the menu bar's), at most the focused session's size.
    static func compactCharacterSize(barHeight: CGFloat) -> CGFloat {
        min(focusCharacterSize, max(pillCharacterSize, (barHeight * 0.8).rounded()))
    }
}

/// What the expanded island holds below its header, as far as its height is concerned.
struct IslandContent: Equatable, Sendable {
    /// What sits under the session pills.
    enum Card: Equatable, Sendable {
        case none
        /// The approval card, tall enough for `lines` lines of command.
        case approval(lines: Int)
        /// An error, finished, dizzy or outcome card.
        case status
        /// A question or plan card wanting `height` (it scrolls in less).
        case question(height: CGFloat)
        case plan(height: CGFloat)
    }

    /// Sessions besides the focused one (the pill row shows when there is at least one).
    var otherSessions: Int
    var card: Card
}

enum IslandGeometry {

    /// The notch width assumed when a screen reports a notch (`safeAreaTop > 0`) but its menu-bar areas are
    /// missing or make no sense. Roughly what a MacBook's notch measures in points.
    static let defaultNotchWidth: CGFloat = 185
    /// The empty middle of the resting bar on a screen without a notch (there is nothing to keep clear, only
    /// a little room between the character and the status word).
    static let noNotchBarWidth: CGFloat = 100
    /// The bar's height on a screen without a notch when its menu bar is auto-hidden (reported as 0).
    static let minimumBarHeight: CGFloat = 22
    /// The bar never grows taller than this on a screen without a notch, whatever the menu bar reports.
    static let maximumBarHeight: CGFloat = 40

    /// Where the island goes on `screen`.
    ///
    /// With a notch, the bar is the notch's height and the notch is the gap between the right edge of the
    /// left menu-bar area and the left edge of the right one; the island is centred on that gap, which need
    /// not be the screen's middle. AppKit gives the areas in screen coordinates; areas that do not lie within
    /// the screen horizontally are taken as relative to the screen's origin and moved by `frame.minX`. When
    /// an area is missing, or the gap is empty or as wide as the screen, a centred notch of
    /// `defaultNotchWidth` is assumed.
    ///
    /// Without a notch, a resting bar of `noNotchBarWidth` sits in the middle of the top edge, as tall as the
    /// menu bar (between `minimumBarHeight` and `maximumBarHeight`).
    static func placement(for screen: ScreenMetrics) -> IslandPlacement {
        let frame = screen.frame
        guard screen.safeAreaTop > 0 else {
            let height = min(max(screen.menuBarHeight, minimumBarHeight), maximumBarHeight)
            return IslandPlacement(
                hasNotch: false, notchWidth: noNotchBarWidth, barHeight: height, centerX: frame.midX, top: frame.maxY)
        }
        var width = defaultNotchWidth
        var centerX = frame.midX
        if let left = screen.auxiliaryLeft, let right = screen.auxiliaryRight {
            let global = left.minX >= frame.minX && right.maxX <= frame.maxX
            let shift = global ? 0 : frame.minX
            let gapStart = left.maxX + shift
            let gapEnd = right.minX + shift
            let gap = gapEnd - gapStart
            if gap > 0 && gap < frame.width {
                width = gap
                centerX = (gapStart + gapEnd) / 2
            }
        }
        return IslandPlacement(
            hasNotch: true, notchWidth: width, barHeight: screen.safeAreaTop, centerX: centerX, top: frame.maxY)
    }

    /// The panel's size for what it shows. Compact is the bar: the notch plus `compactExtraWidth`, as tall as the
    /// notch. Expanded is `expandedWidth` wide: the bar (the header), the focused session, a row of pills when there
    /// are other sessions, then the card, at most `questionMaxHeight` tall. Zero when hidden.
    static func panelSize(mode: IslandMode, content: IslandContent, placement: IslandPlacement) -> CGSize {
        switch mode {
        case .hidden:
            return .zero
        case .compact:
            return CGSize(width: placement.notchWidth + IslandLayout.compactExtraWidth, height: placement.barHeight)
        case .expanded:
            var height = placement.barHeight + IslandLayout.focusHeight + IslandLayout.bottomPadding
            if content.otherSessions > 0 { height += IslandLayout.pillHeight + IslandLayout.pillSpacing }
            switch content.card {
            case .none: break
            case .approval(let lines): height += IslandLayout.cardSpacing + IslandLayout.cardHeight(lines: lines)
            case .status: height += IslandLayout.cardSpacing + IslandLayout.statusCardHeight
            case .question(let card), .plan(let card): height += IslandLayout.cardSpacing + card
            }
            return CGSize(width: IslandLayout.expandedWidth, height: min(height, IslandLayout.questionMaxHeight))
        }
    }

    /// The most a question or plan card can be tall in the expanded island: what `questionMaxHeight` leaves under the
    /// header, the focused session and the pills. The card is drawn at its wanted height up to this, and scrolls inside.
    static func cardRoom(placement: IslandPlacement, otherSessions: Int) -> CGFloat {
        let above = panelSize(
            mode: .expanded, content: IslandContent(otherSessions: otherSessions, card: .none), placement: placement)
        return max(0, IslandLayout.questionMaxHeight - above.height - IslandLayout.cardSpacing)
    }

    /// The black shape's size when the island is hidden: the notch itself (so a closing island shrinks into it),
    /// or the resting bar on a screen without one.
    static func restingSize(placement: IslandPlacement) -> CGSize {
        CGSize(width: placement.notchWidth, height: placement.barHeight)
    }

    /// The panel's frame: centred on the notch, hanging from the top edge of the screen.
    static func panelFrame(size: CGSize, placement: IslandPlacement) -> CGRect {
        CGRect(
            x: placement.centerX - size.width / 2, y: placement.top - size.height,
            width: size.width, height: size.height)
    }

    /// Where the pointer counts as "on the island": the notch itself while hidden (there is no panel to hover),
    /// the panel while it is shown (so it stays until the pointer leaves it).
    static func hoverRect(mode: IslandMode, panelFrame: CGRect, placement: IslandPlacement) -> CGRect {
        guard mode == .hidden else { return panelFrame }
        return CGRect(
            x: placement.centerX - placement.notchWidth / 2, y: placement.top - placement.barHeight,
            width: placement.notchWidth, height: placement.barHeight)
    }

    /// `CGRect.contains` is exclusive on the far edges, but the pointer at the very top of the screen sits
    /// exactly on `maxY`.
    static func isInside(_ point: CGPoint, _ rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// The `id` of the screen to show the island on: the main screen if it has a notch, else the first screen
    /// with a notch, else the main screen, else the first one. Nil when there are no screens.
    static func chooseScreen(_ screens: [ScreenCandidate]) -> Int? {
        let pick = screens.first { $0.hasNotch && $0.isMain }
            ?? screens.first { $0.hasNotch }
            ?? screens.first { $0.isMain }
            ?? screens.first
        return pick?.id
    }
}
