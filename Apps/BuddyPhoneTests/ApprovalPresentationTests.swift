import BuddyKit
import Foundation
import Testing

@Suite struct ApprovalPresentationTests {
    let clock = TestClock()

    private func presentation(
        _ approval: ApprovalRecord, decision: Decision? = nil, shownFor: TimeInterval
    ) -> ApprovalPresentation {
        ApprovalPresentation(
            approval: approval, decision: decision, shownAt: clock.now.addingTimeInterval(-shownFor),
            now: clock.now)
    }

    // MARK: Arming

    @Test func allowIsDisabledUntilTheRequestHasBeenOnScreenForTheArmingDelay() {
        let approval = makeApproval(clock: clock)
        #expect(Arming.delay == 0.7)
        #expect(presentation(approval, shownFor: 0).canAllow == false)
        #expect(presentation(approval, shownFor: 0.699).canAllow == false)
        #expect(presentation(approval, shownFor: 0.7).canAllow)
        #expect(presentation(approval, shownFor: 30).canAllow)
    }

    @Test func denyIsNeverDelayed() {
        let approval = makeApproval(clock: clock)
        #expect(presentation(approval, shownFor: 0).canDeny)
    }

    // MARK: Truncated, expired, decided

    @Test func aTruncatedRequestOffersAllowOnYourMacAndNeverAllow() {
        let approval = makeApproval(clock: clock, truncated: true)
        let shown = presentation(approval, shownFor: 60)
        #expect(shown.canAllow == false)
        #expect(shown.allowTitle == "Allow on your Mac")
        #expect(shown.canDeny)
        #expect(shown.notice?.contains("too long") == true)
        #expect(presentation(makeApproval(clock: clock), shownFor: 60).allowTitle == "Allow")
    }

    @Test func anExpiredRequestOffersNothing() {
        let approval = makeApproval(clock: clock, expiresIn: 0)
        let shown = presentation(approval, shownFor: 60)
        #expect(shown.isExpired)
        #expect(shown.canAllow == false)
        #expect(shown.canDeny == false)
        #expect(shown.countdown == "Expired")
    }

    @Test func aResolvedRequestOffersNothing() {
        let approval = makeApproval(clock: clock, status: .resolved)
        let shown = presentation(approval, shownFor: 60)
        #expect(shown.canAllow == false)
        #expect(shown.canDeny == false)
        #expect(shown.notice == "Already answered.")
    }

    @Test func aDecidedRequestShowsWhatWasSent() {
        let approval = makeApproval(clock: clock)
        let allowed = presentation(approval, decision: .allow, shownFor: 60)
        #expect(allowed.canAllow == false && allowed.canDeny == false)
        #expect(allowed.notice == "Allowed. Sent to your Mac.")
        #expect(presentation(approval, decision: .deny, shownFor: 60).notice == "Denied. Sent to your Mac.")
    }

    // MARK: Countdown

    @Test func theCountdownCountsDownInMinutesAndSeconds() {
        #expect(presentation(makeApproval(clock: clock, expiresIn: 42), shownFor: 0).countdown == "Expires in 0:42")
        #expect(presentation(makeApproval(clock: clock, expiresIn: 125), shownFor: 0).countdown == "Expires in 2:05")
        #expect(presentation(makeApproval(clock: clock, expiresIn: 0.4), shownFor: 0).countdown == "Expires in 0:01")
        #expect(presentation(makeApproval(clock: clock, expiresIn: 0), shownFor: 0).countdown == "Expired")
        #expect(presentation(makeApproval(clock: clock, expiresIn: -10), shownFor: 0).countdown == "Expired")
    }

    // MARK: Reading safety

    @Test func theWholeSummaryIsShownWithHiddenCharactersMadeVisible() {
        let long = String(repeating: "echo hello && ", count: 400)
        let approval = makeApproval(clock: clock, summary: long)
        #expect(presentation(approval, shownFor: 5).summary == long)  // never cut

        let sneaky = makeApproval(clock: clock, summary: "ls\u{202E}gnihtemos\u{200B}\u{00A0}x")
        #expect(presentation(sneaky, shownFor: 5).summary == "ls‹U+202E›gnihtemos‹U+200B›‹U+00A0›x")
        #expect(presentation(sneaky, shownFor: 5).summary == DisplayText.sanitized(sneaky.summary))
    }

    // The same rule as the Mac card: Allow only for text whose every character is in the allowlisted classes.
    // Hebrew or Arabic letters beside neutral punctuation reorder the line with no control character at all.
    @Test func rightToLeftTextOffersAllowOnYourMacAndNeverAllow() {
        for summary in ["rm -rf /tmp/א-ב", "cp a.txt /x/مرحبا/", "a → b"] {
            let shown = presentation(makeApproval(clock: clock, summary: summary), shownFor: 60)
            #expect(shown.canAllow == false, "\(summary)")
            #expect(shown.allowTitle == "Allow on your Mac", "\(summary)")
            #expect(shown.canDeny, "\(summary)")
            #expect(shown.notice?.contains("cannot be allowed from here") == true, "\(summary)")
        }
    }

    @Test func plainTextCanBeAllowed() {
        for summary in ["git status", "echo café ☕ 日本語 && ls", "ls\u{202E}x"] {  // the last one shows a marker
            let shown = presentation(makeApproval(clock: clock, summary: summary), shownFor: 60)
            #expect(shown.canAllow, "\(summary)")
            #expect(shown.allowTitle == "Allow")
            #expect(shown.notice == nil)
        }
    }

    @Test func theToolNameIsSanitizedToo() {
        let approval = makeApproval(clock: clock, tool: "Ba\u{200B}sh")
        #expect(presentation(approval, shownFor: 5).tool == "Ba‹U+200B›sh")
    }
}
