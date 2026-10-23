import Foundation

/// Lists the characters. Settings shows a picker only when `all.count >= 2`.
@MainActor
enum CharacterRegistry {
    /// UserDefaults key holding the chosen character's id.
    static let defaultsKey = "character.id"

    /// Every character, first is the default.
    static let all: [any BuddyCharacter] = [Block()]

    /// The stored character; an unset or unknown id gives the first of `characters`. `characters` must not be
    /// empty (it is `all` in the app; tests pass their own).
    static func current(defaults: UserDefaults, from characters: [any BuddyCharacter] = all) -> any BuddyCharacter {
        precondition(!characters.isEmpty, "CharacterRegistry.all must list at least one character")
        let stored = defaults.string(forKey: defaultsKey)
        return characters.first { $0.id == stored } ?? characters[0]
    }
}
