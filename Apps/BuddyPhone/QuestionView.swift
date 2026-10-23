import BuddyKit
import SwiftUI

/// The person's picks for one question set, kept pure so it is unit-tested without a view. One set of option
/// indexes per question; a single-choice question keeps one (a radio row), a multi-select one toggles.
struct QuestionSelection: Equatable {
    let questions: [AskQuestion]
    private var picks: [Set<Int>]

    init(questions: [AskQuestion]) {
        self.questions = questions
        picks = Array(repeating: [], count: questions.count)
    }

    func isSelected(question: Int, option: Int) -> Bool {
        picks.indices.contains(question) && picks[question].contains(option)
    }

    func hasPick(question: Int) -> Bool {
        picks.indices.contains(question) && !picks[question].isEmpty
    }

    /// Every question has at least one pick: "Send answer" is enabled.
    var isComplete: Bool { picks.allSatisfy { !$0.isEmpty } }

    mutating func toggle(question: Int, option: Int) {
        guard questions.indices.contains(question), questions[question].options.indices.contains(option) else { return }
        if questions[question].multiSelect {
            if !picks[question].insert(option).inserted { picks[question].remove(option) }
        } else {
            picks[question] = [option]
        }
    }

    /// The labels picked per question, in the order the options are listed. What is sent: the labels as the
    /// Mac published them (never the sanitized display text).
    var responses: [[String]] {
        zip(questions, picks).map { question, picked in picked.sorted().map { question.options[$0].label } }
    }
}

/// One question set from Claude, one question at a time. Sending asks for Face ID / passcode, like Allow. There
/// is no free text here: the person picks among the options, or answers in the terminal.
struct QuestionView: View {
    let controller: PhoneController
    let requestId: UUID

    @State private var selection: QuestionSelection?
    @State private var index = 0
    @State private var working = false
    @State private var failure: String?
    @State private var gaveUp = false

    var body: some View {
        Group {
            if let model = controller.model {
                if let question = model.question(id: requestId) {
                    content(model: model, question: question)
                } else if gaveUp {
                    message("This question is no longer available.")
                } else {
                    ProgressView("Loading question").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                message(controller.status.text)
            }
        }
        .navigationTitle("Claude is asking")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await controller.start()
            await controller.model?.refresh()
            try? await Task.sleep(for: .seconds(10))
            gaveUp = true
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(model: PhoneModel, question record: QuestionRecord) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let picks = selection ?? QuestionSelection(questions: record.questions)
            let current = min(index, record.questions.count - 1)
            let asked = record.questions[current]
            let isLast = current == record.questions.count - 1
            let sent = model.answer(for: requestId) != nil
            let expired = model.now >= record.expiresAt
            let isOpen = record.status == .pending && !expired && !sent

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    if record.questions.count > 1 {
                        Text("\(current + 1)/\(record.questions.count)").font(.subheadline.monospacedDigit())
                    }
                    Text(DisplayText.sanitized(asked.header))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Text(Self.countdown(record, now: model.now))
                        .font(.subheadline).foregroundStyle(expired ? .red : .secondary)
                }
                Text(DisplayText.sanitized(asked.text)).font(.title3.weight(.semibold))
                if asked.multiSelect { Text("Pick all that apply.").font(.footnote).foregroundStyle(.secondary) }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(asked.options.indices, id: \.self) { option in
                            optionRow(asked, option: option, isOn: picks.isSelected(question: current, option: option)) {
                                var updated = picks
                                updated.toggle(question: current, option: option)
                                selection = updated
                            }
                            .disabled(!isOpen || working)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)

                if let notice = Self.notice(status: record.status, expired: expired, sent: sent) {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }

                HStack(spacing: 12) {
                    if current > 0 {
                        Button { index = current - 1 } label: { Text("Back").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    if isLast {
                        Button { send(picks, model: model) } label: {
                            Label("Send answer", systemImage: "faceid").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isOpen || !picks.isComplete || working)
                    } else {
                        Button { index = current + 1 } label: { Text("Next").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!picks.hasPick(question: current))
                    }
                }
                .controlSize(.large)

                Text("If you don't answer in about 2 minutes, Claude asks in the terminal.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func optionRow(_ question: AskQuestion, option: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        let shape = question.multiSelect ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "largecircle.fill.circle" : "circle")
        let item = question.options[option]
        return Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: shape).foregroundStyle(isOn ? Color.accentColor : .secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.sanitized(item.label)).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if let description = item.description, !description.isEmpty {
                        Text(DisplayText.sanitized(description)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func send(_ picks: QuestionSelection, model: PhoneModel) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await model.answer(requestId, responses: picks.responses)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    static func countdown(_ question: QuestionRecord, now: Date) -> String {
        let remaining = question.expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Expired" }
        let seconds = Int(remaining.rounded(.up))
        return "Expires in \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// A line explaining why nothing can be sent, or what happened.
    static func notice(status: ApprovalStatus, expired: Bool, sent: Bool) -> String? {
        if sent { return "Answer sent to your Mac." }
        if status != .pending { return "Already answered." }
        if expired { return "This question has expired. Claude asks in the terminal." }
        return nil
    }
}
