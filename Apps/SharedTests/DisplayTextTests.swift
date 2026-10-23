import Testing

// Shared by BuddyMacTests and BuddyPhoneTests: one sanitizer, one set of tests.
@Suite struct DisplayTextTests {
    // MARK: Sanitizing

    @Test func ordinaryTextIsUnchanged() {
        let text = "git commit -m \"fix: café ☕ 日本語\"\n\tindented"
        #expect(DisplayText.sanitized(text) == text)
    }

    @Test func bidiAndInvisibleCharactersBecomeVisibleMarkers() {
        #expect(DisplayText.sanitized("a\u{202E}b") == "a‹U+202E›b")
        #expect(DisplayText.sanitized("\u{202A}\u{202B}\u{202C}\u{202D}") == "‹U+202A›‹U+202B›‹U+202C›‹U+202D›")
        #expect(DisplayText.sanitized("\u{2066}x\u{2069}") == "‹U+2066›x‹U+2069›")
        #expect(DisplayText.sanitized("r\u{200B}m") == "r‹U+200B›m")
        #expect(DisplayText.sanitized("\u{200F}\u{200E}") == "‹U+200F›‹U+200E›")
        #expect(DisplayText.sanitized("\u{FEFF}ls") == "‹U+FEFF›ls")
        #expect(DisplayText.sanitized("a\u{2028}b") == "a‹U+2028›b")
    }

    @Test func controlCharactersOtherThanNewlineAndTabBecomeMarkers() {
        #expect(DisplayText.sanitized("a\u{07}b") == "a‹U+0007›b")
        #expect(DisplayText.sanitized("a\rb") == "a‹U+000D›b")
        #expect(DisplayText.sanitized("a\u{1B}[31mb") == "a‹U+001B›[31mb")
        #expect(DisplayText.sanitized("a\u{7F}b") == "a‹U+007F›b")
        #expect(DisplayText.sanitized("a\u{85}b") == "a‹U+0085›b")
        #expect(DisplayText.sanitized("a\nb\tc") == "a\nb\tc")
    }

    // MARK: Hidden and lookalike-blank characters

    @Test func blankLookingCharactersBecomeMarkers() {
        let blanks: [UInt32] = [
            0x00A0, 0x2000, 0x2005, 0x200A, 0x202F, 0x205F, 0x3000, 0x2800, 0x3164, 0xFFA0, 0x115F, 0x1160,
            0x17B4, 0x17B5, 0xFE00, 0xFE0F, 0xE0100, 0xE01EF,
        ]
        for value in blanks {
            let scalar = Unicode.Scalar(value)!
            let expected = "a" + DisplayText.marker(for: scalar) + "b"
            #expect(DisplayText.sanitized("a\(scalar)b") == expected, "U+\(String(value, radix: 16, uppercase: true))")
        }
        #expect(DisplayText.sanitized("a\u{00A0}b") == "a‹U+00A0›b")
        #expect(DisplayText.sanitized("x\u{E0100}") == "x‹U+E0100›")
        #expect(DisplayText.sanitized("rm\u{3000}-rf") == "rm‹U+3000›-rf")
    }

    @Test func ordinaryNonAsciiLettersAreNotMarked() {
        let text = "café Ünï ß 日本語 ☕ ✅ — “quotes”"
        #expect(DisplayText.sanitized(text) == text)
    }

    // MARK: Plain, readable text (the Allow rule of both approval screens)

    @Test func ordinaryCommandsArePlain() {
        for text in [
            "git status", "ls -la ~/code && echo done", "git commit -m \"fix: café ☕ 日本語\"\n\tindented",
            "Ελληνικά кириллица ひらがな カタカナ 한국어 “quotes” — …", "e\u{301}", "",
        ] {
            #expect(DisplayText.isPlainReadable(text), "\(text.debugDescription)")
        }
    }

    // Hebrew or Arabic letters next to neutral punctuation reorder the line on screen with no bidi control
    // character at all (implicit bidi), so what is read is not what runs.
    @Test func rightToLeftLettersAreNotPlain() {
        for text in [
            "rm -rf /tmp/א-ב", "echo שלום && ls", "cp a.txt /x/مرحبا/", "a\u{05D0}", "\u{0627}",
            "printf ' %s ' -ב- 1 2",
        ] {
            #expect(DisplayText.isPlainReadable(text) == false, "\(text.debugDescription)")
        }
    }

    @Test func glyphsOutsideTheAllowlistAreNotPlain() {
        for text in [
            "#\u{FE0F}\u{20E3}", "a → b", "box ─┼─", "\u{E000}", "\u{12000}", "ⓐ", "\u{FC20}",
            "\u{301}", " \u{301}", "e" + String(repeating: "\u{301}", count: 4),
        ] {
            #expect(DisplayText.isPlainReadable(text) == false, "\(text.debugDescription)")
        }
    }

    @Test func sanitizedHiddenCharactersArePlainMarkers() {
        // The screens check the text as shown: a hidden override is a visible `‹U+202E›` marker by then.
        #expect(DisplayText.isPlainReadable("a\u{202E}b") == false)
        #expect(DisplayText.isPlainReadable(DisplayText.sanitized("a\u{202E}b\u{200B}c\rd")))
    }
}
