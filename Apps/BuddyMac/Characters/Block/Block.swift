import BuddyKit
import SwiftUI

/// Buddy's own first character: a glossy rounded square with two eyes. The look for each state and emote is in
/// `BlockView` (motion) and `BlockDrawing` (shapes).
struct Block: BuddyCharacter {
    let id = "block"
    let displayName = "Block"
    let soundFolder = "block"

    func accent(for state: CharacterState) -> Color { BlockRGB.accent(for: state).color }

    func view(_ input: CharacterInput) -> AnyView { AnyView(BlockView(input: input)) }
}

/// A plain sRGB colour, so the drawing can lighten and darken it exactly.
struct BlockRGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// `fraction` of the way to `other`.
    func mixed(with other: BlockRGB, _ fraction: Double) -> BlockRGB {
        BlockRGB(
            red + (other.red - red) * fraction, green + (other.green - green) * fraction,
            blue + (other.blue - blue) * fraction)
    }

    static let white = BlockRGB(1, 1, 1)
    static let black = BlockRGB(0, 0, 0)

    /// The accent per state: the body colour, and the island's glow, card washes and pills. All are bright enough
    /// to read on the black island. Hues come from the blue / amber / green / red families and differ in lightness
    /// too, so neighbours stay apart for colour-blind eyes; every state also has its own eyes or badge.
    ///
    /// | State       | Name   | sRGB             |
    /// |-------------|--------|------------------|
    /// | idle        | Sky    | 0.36, 0.66, 1.00 |
    /// | working     | Amber  | 1.00, 0.70, 0.18 |
    /// | thinking    | Violet | 0.67, 0.53, 1.00 |
    /// | searching   | Teal   | 0.18, 0.80, 0.78 |
    /// | approval    | Orange | 1.00, 0.48, 0.14 |
    /// | question    | Pink   | 1.00, 0.45, 0.74 |
    /// | error       | Red    | 0.94, 0.22, 0.24 |
    /// | finished    | Green  | 0.33, 0.82, 0.40 |
    /// | rateLimited | Lemon  | 0.96, 0.87, 0.32 |
    /// | sleeping    | Indigo | 0.42, 0.46, 0.86 |
    /// | dizzy       | Pearl  | 0.80, 0.82, 0.88 |
    static func accent(for state: CharacterState) -> BlockRGB {
        switch state {
        case .idle: BlockRGB(0.36, 0.66, 1.00)
        case .working: BlockRGB(1.00, 0.70, 0.18)
        case .thinking: BlockRGB(0.67, 0.53, 1.00)
        case .searching: BlockRGB(0.18, 0.80, 0.78)
        case .approval: BlockRGB(1.00, 0.48, 0.14)
        case .question: BlockRGB(1.00, 0.45, 0.74)
        case .error: BlockRGB(0.94, 0.22, 0.24)
        case .finished: BlockRGB(0.33, 0.82, 0.40)
        case .rateLimited: BlockRGB(0.96, 0.87, 0.32)
        case .sleeping: BlockRGB(0.42, 0.46, 0.86)
        case .dizzy: BlockRGB(0.80, 0.82, 0.88)
        }
    }
}
