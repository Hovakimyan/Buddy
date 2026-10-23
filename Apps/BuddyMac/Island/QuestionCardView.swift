import BuddyKit
import SwiftUI

/// Claude's question (spec 6.3): a cyan wash, "Claude is asking", "i/N" when there are several, an "Answer in terminal"
/// link, the header, the question, and its options as a row of chips (no descriptions) or a list with descriptions.
/// Keys 1-4 pick (the window controller takes them). "Other..." opens a field for a typed answer; Escape closes it.
/// The options are dimmed and do nothing until `armed`. Everything but the top row and Next / Send scrolls when the
/// card is shorter than its content (`height`).
struct QuestionCardView: View {
    let model: QuestionCardModel
    let height: CGFloat
    /// False during the first moments of the card: picks do nothing.
    let armed: Bool
    let onEvent: (QuestionCardEvent) -> Void
    /// The open field's text (`model.otherText`).
    @Binding var otherText: String

    static let wash = Color.cyan

    var body: some View {
        let question = model.current
        VStack(alignment: .leading, spacing: QuestionCardLayout.spacing) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Self.wash)
                Text("Claude is asking").font(.system(size: 12, weight: .semibold))
                if let progress = model.progress {
                    Text(progress).font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Button("Answer in terminal") { onEvent(.answerInTerminal) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.wash)
                    .underline()
            }
            .frame(height: QuestionCardLayout.topRowHeight)
            CardScroll {
                VStack(alignment: .leading, spacing: QuestionCardLayout.spacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DisplayText.sanitized(question.header))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .frame(height: QuestionCardLayout.headerHeight)
                            .background(Capsule().fill(Self.wash.opacity(0.25)))
                        Text(DisplayText.sanitized(question.text))
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if QuestionCardModel.usesList(question) {
                        optionList(question)
                    } else {
                        optionChips(question)
                    }
                    otherRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.showsFooter {
                HStack {
                    Spacer(minLength: 0)
                    CardButton(
                        title: model.footerTitle, fill: Self.wash.opacity(0.85), isEnabled: armed && model.canAdvance,
                        width: 90
                    ) { onEvent(.next) }
                }
            }
        }
        .padding(QuestionCardLayout.padding)
        .frame(height: height)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Self.wash.opacity(0.24), Color.white.opacity(0.07)], startPoint: .topLeading,
                    endPoint: .bottomTrailing)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude is asking: \(question.text)")
    }

    private func isChosen(_ label: String) -> Bool { model.selections[model.index].contains(label) }

    private func optionChips(_ question: AskQuestion) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(question.options.enumerated()), id: \.element.label) { place, option in
                Button { onEvent(.pick(option.label)) } label: {
                    HStack(spacing: 5) {
                        Text("\(place + 1)").font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                        if question.multiSelect {
                            Image(systemName: isChosen(option.label) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11))
                        }
                        Text(DisplayText.sanitized(option.label)).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: QuestionCardLayout.chipHeight)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(fill(for: option.label)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(armed ? 1 : 0.5)
            }
        }
    }

    private func optionList(_ question: AskQuestion) -> some View {
        VStack(spacing: QuestionCardLayout.rowSpacing) {
            ForEach(Array(question.options.enumerated()), id: \.element.label) { place, option in
                Button { onEvent(.pick(option.label)) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(place + 1)").font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                        if question.multiSelect {
                            Image(systemName: isChosen(option.label) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DisplayText.sanitized(option.label)).font(.system(size: 12, weight: .semibold))
                            if let description = option.description, !description.allSatisfy(\.isWhitespace) {
                                Text(DisplayText.sanitized(description)).font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(fill(for: option.label)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .opacity(armed ? 1 : 0.5)
            }
        }
    }

    private func fill(for label: String) -> Color {
        isChosen(label) ? Self.wash.opacity(0.55) : Color.white.opacity(0.12)
    }

    @ViewBuilder private var otherRow: some View {
        if model.otherText != nil {
            OtherField(text: $otherText, onEvent: onEvent)
        } else {
            Button { onEvent(.openOther) } label: {
                Text("Other...")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: QuestionCardLayout.controlHeight)
                    .background(Capsule().strokeBorder(Color.white.opacity(0.3)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The free-text answer. Focused as it opens (the panel is key while it shows); Return sends or moves on, Escape
/// closes it.
private struct OtherField: View {
    @Binding var text: String
    let onEvent: (QuestionCardEvent) -> Void
    @FocusState private var focused: Bool
    @Environment(\.cardsMakeAppKitViews) private var editable

    private static let placeholder = "Type your answer"

    var body: some View {
        HStack(spacing: 6) {
            field
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: QuestionCardLayout.controlHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14)))
            Button { onEvent(.cancelOther) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel")
        }
        .task { focused = true }
    }

    @ViewBuilder private var field: some View {
        if editable {
            TextField(Self.placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { onEvent(.next) }
                .onExitCommand { onEvent(.cancelOther) }
        } else {
            Text(text.isEmpty ? Self.placeholder : text)
                .foregroundStyle(.white.opacity(text.isEmpty ? 0.45 : 1))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
