import BuddyKit
import Foundation

/// What the approval screen shows and which buttons work, kept pure so it is unit-tested without a view.
///
/// Reading safety is the same as on the Mac card: the summary is shown in FULL (the view must not truncate it)
/// with hidden, bidirectional and lookalike characters replaced by visible markers (`DisplayText`); display only.
/// And Allow follows the Mac card's rule: only for text whose every character is in the allowlisted classes
/// (`DisplayText.isPlainReadable`), so implicit right-to-left runs cannot reorder what is read.
struct ApprovalPresentation: Equatable {
    let approval: ApprovalRecord
    /// What this phone already sent for the request.
    let decision: Decision?
    /// When this request first appeared on screen (the arming delay counts from here).
    let shownAt: Date
    let now: Date

    var tool: String { DisplayText.sanitized(approval.tool) }
    var summary: String { DisplayText.sanitized(approval.summary) }

    var isExpired: Bool { now >= approval.expiresAt }
    private var isOpen: Bool { approval.status == .pending && !isExpired && decision == nil }

    /// Deny is never delayed.
    var canDeny: Bool { isOpen }

    /// Allow needs an open request, a command that can be read in full here (`approval.canBeAllowedOnPhone`), and
    /// the arming delay (a stray tap guard, the same 0.7 s as the Mac card). Face ID still follows the tap.
    var canAllow: Bool {
        isOpen && approval.canBeAllowedOnPhone && Arming.isArmed(shownAt: shownAt, now: now)
    }

    /// The command is truncated or not plain text: Allow is only possible on the Mac (in the terminal).
    var allowsOnlyOnMac: Bool { !approval.canBeAllowedOnPhone }

    var allowTitle: String { allowsOnlyOnMac ? "Allow on your Mac" : "Allow" }

    var countdown: String {
        let remaining = approval.expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Expired" }
        let seconds = Int(remaining.rounded(.up))
        return "Expires in \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// A line under the text explaining why a button is off, or what happened.
    var notice: String? {
        switch decision {
        case .allow?: return "Allowed. Sent to your Mac."
        case .deny?: return "Denied. Sent to your Mac."
        case nil: break
        }
        if approval.status != .pending { return "Already answered." }
        if isExpired { return "This request has expired." }
        if approval.isTruncated {
            return "This command is too long to show in full, so it cannot be allowed from here. Allow it on your Mac or in the terminal."
        }
        if allowsOnlyOnMac {
            return "This command has characters that can change how it reads on screen, so it cannot be allowed from here. Allow it in the terminal on your Mac."
        }
        return nil
    }
}
