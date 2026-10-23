import BuddyKit
import SwiftUI

/// Claude's plan (spec 6.5, `ExitPlanMode`): "Claude has a plan", the plan text (scrolling inside the card), and
/// "Change plan", "Go (auto-accept edits)" (primary), "Go (ask each time)". The Go buttons are dimmed and do nothing
/// until `armed`; "Change plan" is never delayed, like Deny. Mac only: the phone just shows the session waiting.
struct PlanCardView: View {
    let approval: PendingApproval
    let height: CGFloat
    let armed: Bool
    let onChoice: (PlanChoice) -> Void
    /// The character's accent, washed over the card.
    var accent: Color?
    /// The session's project, if the session is known.
    var project: String?

    static let padding: CGFloat = 10
    static let lineHeight: CGFloat = 14
    /// Characters per line of the 11 pt plan text, low so the estimate errs tall.
    static let columns = 85
    /// The most lines the card grows for; a longer plan scrolls.
    static let maxLines = 20
    /// Everything but the plan's lines: padding, title, the text box's padding, spacing, buttons.
    static let baseHeight: CGFloat = 2 * padding + 16 + 6 + 8 + 6 + 26
    static let maxHeight: CGFloat = baseHeight + CGFloat(maxLines) * lineHeight

    static func planText(of approval: PendingApproval) -> String {
        guard case .plan(let text) = approval.kind else { return approval.summary.text }
        return DisplayText.sanitized(text)
    }

    /// The card's height for the whole plan, at most `maxHeight`.
    static func naturalHeight(for approval: PendingApproval) -> CGFloat {
        let lines = CardText.lineCount(of: planText(of: approval), columns: columns)
        return baseHeight + CGFloat(min(max(lines, 1), maxLines)) * lineHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(accent ?? .white)
                Text("Claude has a plan").font(.system(size: 12, weight: .semibold))
                if let project {
                    Text(project).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 16)
            CardScroll {
                Text(Self.planText(of: approval))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IslandLayout.textHorizontalPadding)
                    .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            HStack(spacing: 6) {
                CardButton(title: "Change plan", fill: .red.opacity(0.85), width: 110) { onChoice(.change) }
                CardButton(title: "Go (auto-accept edits)", fill: .green.opacity(0.85), isEnabled: armed) {
                    onChoice(.acceptEdits)
                }
                CardButton(title: "Go (ask each time)", fill: .blue.opacity(0.85), isEnabled: armed, width: 150) {
                    onChoice(.askEachTime)
                }
            }
        }
        .padding(Self.padding)
        .frame(height: height)
        .foregroundStyle(.white)
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude has a plan")
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
