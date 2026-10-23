import BuddyKit
import SwiftUI

/// What a pill's badge says about its session.
enum PillBadge: Equatable, Sendable {
    /// "!": a permission waits (here or in the terminal).
    case approval
    /// "?": a question waits.
    case question
    /// A check: the session finished.
    case done
    /// An x: the session stopped with an error.
    case failed
}

/// One of the other sessions under the focused one: the character at pill size in the session's state, the
/// project name and a badge. A click focuses the session.
struct SessionPill: View {
    let session: Session
    let state: CharacterState
    let badge: PillBadge?
    let character: any BuddyCharacter
    let reduceMotion: Bool
    let onTap: () -> Void

    var body: some View {
        let accent = character.accent(for: state)
        Button(action: onTap) {
            HStack(spacing: 5) {
                character.view(CharacterInput(
                    state: state, emote: nil, emoteStartedAt: nil, stateStartedAt: session.updatedAt,
                    hovering: false, boopedAt: nil, greetingStartedAt: nil, look: .zero,
                    size: IslandLayout.pillCharacterSize, reduceMotion: reduceMotion))
                    .frame(width: IslandLayout.pillCharacterSize, height: IslandLayout.pillCharacterSize)
                Text(session.project)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge { PillBadgeView(badge: badge, accent: accent) }
            }
            .padding(.horizontal, 8)
            .frame(height: IslandLayout.pillHeight)
            .background(Capsule().fill(accent.opacity(0.16)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("\(session.project), \(IslandLogic.statusWord(state, pendingCount: 0))")
    }
}

struct PillBadgeView: View {
    let badge: PillBadge
    let accent: Color

    var body: some View {
        ZStack {
            Circle().fill(fill)
            switch badge {
            case .approval: Text("!").font(.system(size: 10, weight: .heavy))
            case .question: Text("?").font(.system(size: 10, weight: .heavy))
            case .done: Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy))
            case .failed: Image(systemName: "xmark").font(.system(size: 7, weight: .heavy))
            }
        }
        .foregroundStyle(.black)
        .frame(width: 14, height: 14)
    }

    private var fill: Color {
        switch badge {
        case .approval, .question: accent
        case .done: .green
        case .failed: .red
        }
    }
}
