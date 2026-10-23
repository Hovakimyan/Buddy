import BuddyKit
import SwiftUI

/// The permission request: which tool, what it will do (`summary.text`), and Deny / Allow / Always.
/// "Always" answers like Allow for this request only. The whole command is shown (the card is as tall as its text
/// needs, up to `CardText.maxLines`): one that cannot be shown in full cannot be allowed from here (Allow and
/// Always are disabled, Allow reads "Allow in terminal"); Deny still works. Allow and Always are also dimmed until
/// `armed`, a moment after the card appeared.
struct ApprovalCardView: View {
    let approval: PendingApproval
    /// The session's project (last component of its cwd), if the session is known.
    let project: String?
    /// False during the first moments of a card: Allow and Always are dimmed and do nothing. Deny is always live.
    let armed: Bool
    let onChoice: (ApprovalChoice) -> Void
    /// The character's accent, washed over the card; nil for the plain card.
    var accent: Color?
    /// How many cards wait in all; above one the header shows "1/N" (this card is the front one).
    var queueCount = 1
    /// The subagent asking ("Explore agent"); nil for the main conversation.
    var asker: String?

    private var canAllow: Bool { IslandLogic.canAllow(approval) }
    private var allowLive: Bool { canAllow && armed }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(approval.toolName).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                if let project {
                    Text(project).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                if let asker {
                    Text("· " + asker).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if queueCount > 1 {
                    Text("1/\(queueCount)").font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            CardCommandText(approval: approval)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                CardButton(title: "Deny", fill: .red.opacity(0.85), width: 66) { onChoice(.deny) }
                CardButton(title: canAllow ? "Allow" : "Allow in terminal", fill: .green.opacity(0.85), isEnabled: allowLive) {
                    onChoice(.allow)
                }
                CardButton(title: "Always", fill: .blue.opacity(0.85), isEnabled: allowLive, width: 66) {
                    onChoice(.always)
                }
            }
        }
        .padding(IslandLayout.cardPadding)
        .frame(height: IslandLayout.cardHeight(lines: IslandLogic.cardLines(for: approval)))
        .foregroundStyle(.white)
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request for \(approval.toolName)")
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if let accent {
            shape.fill(LinearGradient(
                colors: [accent.opacity(0.2), Color.white.opacity(0.08)], startPoint: .topLeading,
                endPoint: .bottomTrailing))
        } else {
            shape.fill(Color.white.opacity(0.08))
        }
    }
}

/// The command text of the card: all of it, in its own box. No tail truncation: an allowable command is shown whole
/// (no line limit, never an ellipsis). One that does not fit the card cannot be allowed, so cutting its display at
/// the maximum is harmless. Internal so a test can measure it.
struct CardCommandText: View {
    let approval: PendingApproval

    var body: some View {
        Text(IslandLogic.displayText(for: approval))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(IslandLogic.canAllow(approval) ? nil : CardText.maxLines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IslandLayout.textHorizontalPadding)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
    }
}

/// A capsule button of the cards (approval and plan).
struct CardButton: View {
    let title: String
    let fill: Color
    var isEnabled = true
    /// Fixed width, or nil to take the room left over.
    var width: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(width: width, height: 26)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .background(Capsule().fill(isEnabled ? fill : Color.white.opacity(0.12)))
                .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
