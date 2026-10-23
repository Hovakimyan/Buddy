import BuddyKit
import SwiftUI

/// Everything a character needs to draw one frame. The island builds it; the character reports nothing back.
struct CharacterInput {
    var state: CharacterState
    /// The last one-shot expression and when it started; the character decides how long it shows.
    var emote: CharacterEmote?
    var emoteStartedAt: Date?
    var stateStartedAt: Date
    var hovering: Bool
    var boopedAt: Date?
    var greetingStartedAt: Date?
    /// Mouse position relative to the character, each axis in -1...1.
    var look: CGVector
    /// Drawn at island size and at pill size (about 12 pt).
    var size: CGFloat
    var reduceMotion: Bool
}

/// A swappable character. Drawing should switch over `CharacterState` and `CharacterEmote` without `default`,
/// so adding a case fails to compile until every character gives it a look. Nothing in the island may assume
/// a round body, a mouth or hands.
@MainActor
protocol BuddyCharacter {
    var id: String { get }
    var displayName: String { get }
    /// Folder under the bundled sounds that this character's sounds come from.
    var soundFolder: String { get }
    /// The island uses this for glow, card washes and pills.
    func accent(for state: CharacterState) -> Color
    func view(_ input: CharacterInput) -> AnyView
}
