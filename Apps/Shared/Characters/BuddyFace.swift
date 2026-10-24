import BuddyKit
import SwiftUI

/// Buddy, drawn by the same code as on the Mac. The state's start is kept here, so a redraw of the screen (the list
/// ticks every second) does not restart the character's motion.
struct BuddyFace: View {
    let state: CharacterState
    let size: CGFloat
    /// Small faces in a list stay still; the big one moves unless Reduce Motion is on.
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var since = Date()

    var body: some View {
        Block()
            .view(CharacterInput(
                state: state, emote: nil, emoteStartedAt: nil, stateStartedAt: since, hovering: false, boopedAt: nil,
                greetingStartedAt: nil, look: .zero, size: size, reduceMotion: reduceMotion || !animated))
            .frame(width: size, height: size)
            .onChange(of: state) { _, _ in since = Date() }
            .accessibilityHidden(true)
    }
}
