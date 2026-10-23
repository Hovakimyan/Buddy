import Foundation

/// Makes untrusted text safe to read before a human approves something because of it. Pure Foundation, shared
/// by the Mac approval card and the iPhone approval screen so both show a request the same way.
enum DisplayText {
    /// The text with every character the eye cannot see (or that changes how text is laid out) replaced by a
    /// visible marker such as `‹U+202E›`: C0/C1 controls except newline and tab, zero-width and bidirectional
    /// marks and overrides, line and paragraph separators, byte order mark, and characters that look blank or
    /// like another (NBSP and the other spaces, blank braille, fillers, variation selectors). Only used for display: what goes to
    /// the engine and the phone is untouched.
    static func sanitized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isHidden(scalar) {
                result.append(contentsOf: marker(for: scalar).unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: Plain, readable text

    /// The most combining marks in a row after one letter. More than this is "zalgo" text, which can draw far
    /// outside its line.
    static let maxCombiningMarks = 3

    /// True when every character of `text` is in an allowlisted class: printable ASCII, newline and tab; Latin-1
    /// Supplement and Latin Extended-A/B letters; Greek; Cyrillic; common General Punctuation; kana, CJK ideographs and
    /// Hangul syllables; Emoji Presentation characters; and combining diacritics (U+0300 to U+036F, at most
    /// `maxCombiningMarks` in a row) on a letter or ASCII character before them. Anything else (Hebrew, Arabic and the
    /// other scripts, enclosing marks such as the keycap U+20E3, symbols, arrows, private use, unassigned) makes it
    /// false. Both approval screens offer Allow only for such text, checked on the text as shown (`sanitized`): every
    /// allowed class is drawn left to right in reading order (no right-to-left letters, so no implicit reordering of
    /// the line) and its width on the Mac card has been measured (`CardText`, `CardMeasureTests`).
    static func isPlainReadable(_ text: String) -> Bool {
        var canTakeMarks = false
        var marks = 0
        for scalar in text.unicodeScalars {
            if isAllowlisted(scalar) {
                canTakeMarks = takesCombiningMarks(scalar)
                marks = 0
            } else if isCombiningDiacritic(scalar) {
                marks += 1
                guard canTakeMarks, marks <= maxCombiningMarks else { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Whether `scalar` is in one of the allowlisted classes of `isPlainReadable` (combining diacritics are not: they
    /// are only allowed on a base character, which `isPlainReadable` checks).
    static func isAllowlisted(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x20...0x7E: return true
        default: break
        }
        guard isPlainCharacter(scalar) else { return false }
        switch scalar.value {
        case 0xA1...0x24F,  // Latin-1 Supplement, Latin Extended-A and B
            0x370...0x3FF,  // Greek and Coptic
            0x400...0x4FF,  // Cyrillic
            0x2010...0x2027, 0x2030...0x205E,  // General Punctuation (the invisible and space characters are in the gaps)
            0x3041...0x3096, 0x30A1...0x30FA,  // Hiragana, Katakana
            0x3400...0x4DBF, 0x4E00...0x9FFF,  // CJK ideographs
            0xAC00...0xD7A3:  // Hangul syllables
            return true
        default:
            return scalar.properties.isEmojiPresentation
        }
    }

    /// Assigned, visible characters only: no marks, controls, format characters, separators, private use or
    /// unassigned code points, whatever block they are in.
    private static func isPlainCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .unassigned, .control, .format, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator,
            .spaceSeparator, .nonspacingMark, .spacingMark, .enclosingMark:
            false
        default:
            true
        }
    }

    private static func isCombiningDiacritic(_ scalar: Unicode.Scalar) -> Bool {
        (0x300...0x36F).contains(scalar.value) && scalar.properties.generalCategory == .nonspacingMark
    }

    /// A combining mark may follow printable ASCII (not a space) and the Latin, Greek and Cyrillic letters.
    private static func takesCombiningMarks(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21...0x7E, 0xA1...0x4FF: true
        default: false
        }
    }

    // MARK: Markers

    static func marker(for scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "‹U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "›"
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: false
        case 0x00...0x1F, 0x7F...0x9F: true  // C0 and C1 controls, DEL
        case 0x00AD, 0x034F, 0x061C, 0x180E: true  // soft hyphen, grapheme joiner, Arabic letter mark, Mongolian vowel separator
        case 0x00A0, 0x202F, 0x205F, 0x3000: true  // no-break and ideographic spaces: look like a space, are not
        case 0x2000...0x200F: true  // en/em/thin/hair spaces, zero-width space/joiners, LRM, RLM
        case 0x2028...0x202E: true  // line/paragraph separators, bidi embeddings and overrides
        case 0x2800, 0x3164, 0xFFA0, 0x115F, 0x1160, 0x17B4, 0x17B5: true  // blank braille, Hangul and Khmer fillers
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF: true  // variation selectors
        case 0x2060...0x206F: true  // word joiner, invisible operators, bidi isolates, deprecated formatting
        case 0xFEFF, 0xFFF9...0xFFFB: true  // byte order mark, interlinear annotation
        case 0xE0000...0xE007F: true  // tag characters
        default: false
        }
    }
}

/// The stray-tap guard shared by both approval UIs: Allow does nothing until the request has been on screen for
/// `delay`, so a tap or click aimed at something else (the request appears under the finger on its own) cannot
/// approve it. Deny is never delayed.
enum Arming {
    static let delay: TimeInterval = 0.7

    /// Whether Allow is live: `delay` has passed since the request was first shown.
    static func isArmed(shownAt: Date, now: Date) -> Bool {
        now >= shownAt.addingTimeInterval(delay)
    }
}
