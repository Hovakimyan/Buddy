import BuddyKit
import Observation
import SwiftUI

/// What the island reads and where its answers go. `AppModel` is the real one (it mirrors the engine's snapshots);
/// the demo plugs in its own. Observable, so the views and the window controller follow its changes.
@MainActor
protocol IslandFeed: AnyObject, Observable {
    var sessions: [Session] { get }
    var pending: [PendingApproval] { get }
    var questions: [PendingQuestion] { get }
    /// How recent questions ended (oldest first), so the island can say what became of one it showed.
    var questionOutcomes: [QuestionOutcomeRecord] { get }
    func decide(_ id: UUID, _ decision: Decision) async -> Bool
    func decidePlan(_ id: UUID, _ choice: PlanChoice) async -> Bool
    func answer(_ id: UUID, _ responses: [QuestionResponse]) async -> Bool
    func releaseQuestion(_ id: UUID) async
}

/// The character's input apart from where the pointer is and how big it is drawn: its state, and the reactions
/// `CharacterDirector` timed. Set by the window controller.
struct CharacterFace: Equatable {
    var state = CharacterState.idle
    var stateStartedAt = Date()
    var emote: CharacterEmote?
    var emoteStartedAt: Date?
    var boopedAt: Date?
    var greetingStartedAt: Date?
    var hovering = false

    func input(look: CGVector, size: CGFloat, reduceMotion: Bool) -> CharacterInput {
        CharacterInput(
            state: state, emote: emote, emoteStartedAt: emoteStartedAt, stateStartedAt: stateStartedAt,
            hovering: hovering, boopedAt: boopedAt, greetingStartedAt: greetingStartedAt, look: look, size: size,
            reduceMotion: reduceMotion)
    }
}

/// What the island view needs besides the feed: how much of the island is showing, its animated shape, the
/// character, and where clicks go. Owned by the window controller, which updates it.
@MainActor
@Observable
final class IslandUIState {
    /// What the content shows. Changed inside the open or close animation, so the content cross-fades.
    var mode = IslandMode.hidden
    var placement = IslandPlacement(hasNotch: false, notchWidth: IslandGeometry.noNotchBarWidth, barHeight: 24, centerX: 0, top: 0)
    /// The request whose card has been on screen long enough for Allow and Always to work. Observed, so the
    /// card re-renders (undimmed) the moment it is armed.
    var armedRequest: UUID?
    /// Since when the front request's card has been drawn without a break (empty while no card is drawn).
    /// Written by the window controller, read when a button is clicked (not while drawing), so it is not observed.
    @ObservationIgnored var shownAt: [UUID: Date] = [:]
    /// The question card's state while a question is the front card (nil otherwise).
    var questionCard: QuestionCardModel?

    // MARK: Shape

    /// The black shape, animated between the notch, the compact bar and the expanded island.
    var shapeSize = CGSize.zero
    var cornerRadius: CGFloat = 0
    /// The size each content is laid out at, so it never reflows while the shape animates around it.
    var compactSize = CGSize.zero
    var expandedSize = CGSize.zero
    var reduceMotion = false
    /// How much of the time before an automatic close is left, 1...0; nil while no close is near.
    var countdown: Double?

    // MARK: Overview

    var muted = false
    /// The session picked with a pill or ⌃⌥] / ⌃⌥[ (a waiting card's session still wins the focus).
    var chosenSession: String?
    var statusCard: StatusCard?

    // MARK: Character

    var character: any BuddyCharacter = CharacterRegistry.all[0]
    var face = CharacterFace()
    /// Where the pointer is relative to the character, each axis -1...1. Kept apart from `face` because it
    /// changes on every mouse move: only the character's own view reads it.
    var look = CGVector.zero
    /// Where the character is drawn, in the panel's coordinates (top left origin). Not observed.
    @ObservationIgnored var characterFrame = CGRect.zero

    // MARK: Actions (set by the window controller; not observed)

    /// A tap on the island.
    @ObservationIgnored var onClick: () -> Void = {}
    /// A tap on the character itself.
    @ObservationIgnored var onCharacterClick: () -> Void = {}
    /// A pill was clicked.
    @ObservationIgnored var onFocus: (String) -> Void = { _ in }
    @ObservationIgnored var onToggleMute: () -> Void = {}
    @ObservationIgnored var onOpenSettings: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    /// A button of the approval card.
    @ObservationIgnored var onChoice: (PendingApproval, ApprovalChoice) -> Void = { _, _ in }
    /// A button of the plan card.
    @ObservationIgnored var onPlanChoice: (PendingApproval, PlanChoice) -> Void = { _, _ in }
    /// A control of the question card.
    @ObservationIgnored var onQuestion: (QuestionCardEvent) -> Void = { _ in }
    /// OK on a status card, with the card's key.
    @ObservationIgnored var onDismissStatus: (String) -> Void = { _ in }

    var accent: Color { character.accent(for: face.state) }
}

/// The island: a black shape hanging from the top edge that grows out of the notch into the compact bar
/// (`CompactIsland`) and the expanded overview (`IslandOverview`). The shape animates its width, height and
/// corners while the content cross-fades; each content is laid out at its final size and clipped by the shape.
struct IslandView: View {
    let feed: any IslandFeed
    let ui: IslandUIState

    var body: some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: ui.cornerRadius, bottomTrailingRadius: ui.cornerRadius, style: .continuous)
        ZStack(alignment: .top) {
            switch ui.mode {
            case .hidden:
                EmptyView()
            case .compact:
                CompactIsland(feed: feed, ui: ui)
                    .frame(width: ui.compactSize.width, height: ui.compactSize.height)
                    .transition(.opacity)
            case .expanded:
                IslandOverview(feed: feed, ui: ui)
                    .frame(width: ui.expandedSize.width, height: ui.expandedSize.height, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(width: ui.shapeSize.width, height: ui.shapeSize.height, alignment: .top)
        .clipShape(shape)
        .background(shape.fill(Color.black))
        .overlay(alignment: .bottom) { CountdownLine(ui: ui) }
        .contentShape(shape)
        .onTapGesture { ui.onClick() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The thin line along the bottom edge that runs out before the island closes by itself.
private struct CountdownLine: View {
    let ui: IslandUIState

    var body: some View {
        if let left = ui.countdown {
            let full = max(0, ui.shapeSize.width - 2 * ui.cornerRadius - 16)
            Capsule()
                .fill(ui.accent.opacity(0.75))
                .frame(width: full * left, height: 2)
                .padding(.bottom, 2)
                .animation(.linear(duration: 0.1), value: left)
                .allowsHitTesting(false)
        }
    }
}

/// The character at `size`, with a soft glow in its state's accent. A tap boops it.
struct IslandCharacterView: View {
    let ui: IslandUIState
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(ui.accent)
                .frame(width: size, height: size)
                .blur(radius: size * 0.32)
                .opacity(0.45)
            ui.character.view(ui.face.input(look: ui.look, size: size, reduceMotion: ui.reduceMotion))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { ui.onCharacterClick() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ui.characterFrame = $0 }
        .accessibilityElement()
        .accessibilityLabel("\(ui.character.displayName), \(IslandLogic.statusWord(ui.face.state, pendingCount: 0))")
    }
}
