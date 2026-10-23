import Carbon.HIToolbox
import Testing

@Suite struct HotkeyTests {
    private func key(_ code: Int, _ modifiers: UInt32 = Hotkeys.controlOption) -> Hotkey {
        Hotkey(keyCode: UInt32(code), modifiers: modifiers)
    }

    @Test func combosMapToActions() {
        #expect(Hotkeys.action(for: key(kVK_ANSI_M)) == .toggleMute)
        #expect(Hotkeys.action(for: key(kVK_ANSI_RightBracket)) == .nextSession)
        #expect(Hotkeys.action(for: key(kVK_ANSI_LeftBracket)) == .previousSession)
        #expect(Hotkeys.action(for: key(kVK_ANSI_A)) == .showPending)
        #expect(Hotkeys.action(for: key(kVK_Escape, 0)) == .escape)
    }

    @Test func otherModifiersOrKeysMapToNothing() {
        #expect(Hotkeys.action(for: key(kVK_ANSI_M, UInt32(controlKey))) == nil)
        #expect(Hotkeys.action(for: key(kVK_ANSI_M, 0)) == nil)
        #expect(Hotkeys.action(for: key(kVK_ANSI_A, UInt32(controlKey | optionKey | shiftKey))) == nil)
        #expect(Hotkeys.action(for: key(kVK_Escape)) == nil)
        #expect(Hotkeys.action(for: key(kVK_ANSI_B)) == nil)
    }

    @Test func theAlwaysOnSetIsTheFourControlOptionKeysWithoutEscape() {
        #expect(Hotkeys.global.count == 4)
        #expect(Hotkeys.global.allSatisfy { $0.modifiers == Hotkeys.controlOption })
        #expect(!Hotkeys.global.contains(Hotkeys.escape))
        #expect(Set(Hotkeys.global.compactMap(Hotkeys.action(for:))) == [.toggleMute, .nextSession, .previousSession, .showPending])
    }

    /// Escape is everyone's key (vim, the terminal): it is only taken while the island is open and the pointer is
    /// on it. A waiting card can hold the island open for minutes; the pointer elsewhere leaves Escape alone.
    @Test func escapeIsWantedOnlyWhileExpandedAndThePointerIsOnTheIsland() {
        #expect(Hotkeys.wantsEscape(mode: .expanded, pointerInside: true))
        #expect(!Hotkeys.wantsEscape(mode: .expanded, pointerInside: false))
        for mode in [IslandMode.compact, .hidden] {
            #expect(!Hotkeys.wantsEscape(mode: mode, pointerInside: true))
            #expect(!Hotkeys.wantsEscape(mode: mode, pointerInside: false))
        }
    }

    /// While the "Other..." field is open the panel is key and Escape belongs to the field (it closes it).
    @Test func escapeIsLeftToTheFieldWhileTyping() {
        #expect(!Hotkeys.wantsEscape(mode: .expanded, pointerInside: true, typing: true))
    }

    @Test func digitsOneToFourPickOptions() {
        #expect(Hotkeys.digits.count == 4)
        #expect(Hotkeys.digits.allSatisfy { $0.modifiers == 0 })
        #expect(Hotkeys.digits.compactMap(Hotkeys.action(for:)) == [.pick(1), .pick(2), .pick(3), .pick(4)])
        #expect(Hotkeys.action(for: key(kVK_ANSI_1)) == nil)  // with ⌃⌥ it is not a pick
        #expect(Hotkeys.action(for: key(kVK_ANSI_5, 0)) == nil)
        #expect(!Hotkeys.global.contains { Hotkeys.digits.contains($0) })
    }

    /// Digits are everyone's keys: taken only while a question is the front card, the island is open, the pointer is
    /// on it, and nobody types in the field.
    @Test func digitsAreWantedOnlyForAFrontQuestionUnderThePointer() {
        #expect(Hotkeys.wantsDigits(mode: .expanded, pointerInside: true, questionFront: true, typing: false))
        #expect(!Hotkeys.wantsDigits(mode: .expanded, pointerInside: true, questionFront: true, typing: true))
        #expect(!Hotkeys.wantsDigits(mode: .expanded, pointerInside: true, questionFront: false, typing: false))
        #expect(!Hotkeys.wantsDigits(mode: .expanded, pointerInside: false, questionFront: true, typing: false))
        #expect(!Hotkeys.wantsDigits(mode: .compact, pointerInside: true, questionFront: true, typing: false))
    }

    /// The Carbon callback recognises Buddy's keys by this signature ("BDDY").
    @Test func theSignatureIsBuddys() {
        #expect(HotkeyCenter.signature == 0x4244_4459)
    }

    @Test func cyclingFollowsTheListOrderAndWraps() {
        let ids = ["a", "b", "c"]
        #expect(Hotkeys.cycle(ids, from: "a", forward: true) == "b")
        #expect(Hotkeys.cycle(ids, from: "b", forward: true) == "c")
        #expect(Hotkeys.cycle(ids, from: "c", forward: true) == "a")
        #expect(Hotkeys.cycle(ids, from: "a", forward: false) == "c")
        #expect(Hotkeys.cycle(ids, from: "c", forward: false) == "b")
    }

    @Test func cyclingFromNothingStartsAtAnEnd() {
        let ids = ["a", "b", "c"]
        #expect(Hotkeys.cycle(ids, from: nil, forward: true) == "a")
        #expect(Hotkeys.cycle(ids, from: nil, forward: false) == "c")
        #expect(Hotkeys.cycle(ids, from: "gone", forward: true) == "a")
        #expect(Hotkeys.cycle(ids, from: "gone", forward: false) == "c")
        #expect(Hotkeys.cycle([], from: "a", forward: true) == nil)
        #expect(Hotkeys.cycle(["a"], from: "a", forward: true) == "a")
    }
}
