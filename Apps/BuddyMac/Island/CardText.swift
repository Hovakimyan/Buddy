import Foundation

/// Text on the approval card, kept pure so it is unit-tested without a view.
///
/// The human must be able to read everything that will be allowed. So the card shows the whole text, reserves
/// room for it (height from `lineCount`), and Allow is only offered when the text fits in `maxLines` lines.
/// Hidden-character sanitizing lives in `DisplayText` (Shared), the same code the iPhone screen uses.
/// The line count is an estimate that errs on the high side: it assumes narrower lines than the card really has.
/// `CardMeasureTests` renders real text at the narrowest card and checks the estimate never falls below it.
///
/// The estimate is only trustworthy for glyphs whose width has been measured, so Allow uses an allowlist
/// (`isMeasured`, the shared `DisplayText.isPlainReadable`): one character outside the measured classes (keycaps,
/// Hebrew and Arabic, cuneiform, arrows, box drawing, ...) and the text is not "fully visible", whatever the estimate
/// says. Such a command can still be denied, and can be allowed in the terminal.
enum CardText {
    /// The most lines the card will ever show. More than this and the request cannot be allowed from the card.
    static let maxLines = 8
    /// Characters per line, assumed. The card's text is 11 pt monospaced in `IslandLayout.minimumCardTextWidth`,
    /// far more than 38 columns: the estimate stays on the safe side (it never finds fewer lines than are drawn),
    /// leaving room for wide glyphs and for how the system breaks lines.
    static let columns = 38

    // MARK: Layout estimate

    /// The number of lines the text needs: every newline starts a line, and each line is wrapped greedily at
    /// `columns` (a word that does not fit starts a new line; a word longer than a line is split). The question and
    /// plan cards, whose text scrolls, pass their own wider estimate.
    static func lineCount(of text: String, columns: Int = columns) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + paragraphLines(String($1), columns: columns) }
    }

    /// Whether the human can read all of `text` on the card: every character is in a measured class and the
    /// estimate fits `maxLines`.
    static func isFullyVisible(_ text: String) -> Bool {
        isMeasured(text) && lineCount(of: text) <= maxLines
    }

    // MARK: Allowlist

    /// True when every character of `text` is in a class whose rendered width is known (and checked against real
    /// rendering by `CardMeasureTests`). The classes are `DisplayText.isPlainReadable`'s, the rule the iPhone uses
    /// too: one character outside them (keycaps, Hebrew and Arabic, cuneiform, arrows, box drawing, ...) and the text
    /// is not fully visible, whatever the estimate says.
    static func isMeasured(_ text: String) -> Bool {
        DisplayText.isPlainReadable(text)
    }

    /// The estimated columns of a character in a measured class, or nil when it is not in one. (Combining
    /// diacritics are handled by `isMeasured` and are not here: they sit on their base and add nothing.)
    static func measuredWidth(of scalar: Unicode.Scalar) -> Int? {
        guard DisplayText.isAllowlisted(scalar) else { return nil }
        return scalar == "\n" ? 0 : width(of: scalar)  // a line break is counted by `lineCount`
    }

    private static func paragraphLines(_ paragraph: String, columns: Int) -> Int {
        var lines = 1
        var column = 0
        for (index, token) in paragraph.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let separator = index == 0 ? 0 : 1
            let length = token.unicodeScalars.reduce(0) { $0 + width(of: $1) }
            if length == 0 {  // consecutive spaces hang at the end of a line, they never wrap
                column = min(column + separator, columns)
                continue
            }
            if column + separator + length <= columns {
                column += separator + length
                continue
            }
            if column > 0 {  // does not fit after what is there: start a new line
                lines += 1
                column = 0
            }
            if length <= columns {
                column = length
            } else {  // longer than a line: split across lines
                let extra = (length - 1) / columns
                lines += extra
                column = length - extra * columns
            }
        }
        return lines
    }

    /// Columns a character takes. ASCII is one (tab eight, its widest case). Characters in the Emoji_Presentation set (✅ ❌ ⭐ ☕ ⌛ 😀 ...)
    /// count three: Apple Color Emoji is about 2.5 monospace columns wide at the card's font size (measured: 16 per
    /// 264 pt line, so 2.1 columns, the earlier guess, undercounted a long run of them by a third). (U+FE0F never
    /// gets here: `DisplayText` shows it as a `‹U+FE0F›` marker.) Every other non-ASCII character counts two,
    /// deliberately: CJK is about two columns and accented letters one, and a miss on the
    /// high side only sends a command to the terminal. Other combining marks sit on their base and add nothing.
    private static func width(of scalar: Unicode.Scalar) -> Int {
        if scalar == "\t" { return 8 }  // up to the next tab stop, measured: a run of 76 tabs needed 9 lines at 4 columns each
        if scalar.value <= 0x7F { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return 0
        default: return scalar.properties.isEmojiPresentation ? 3 : 2
        }
    }
}
