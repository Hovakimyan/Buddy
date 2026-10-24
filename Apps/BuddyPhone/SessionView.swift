import BuddyKit
import SwiftUI

/// One session: what it is doing, and a box to send Claude a message. The Mac hands the message over when Claude's
/// turn ends, at once if it is waiting for one (Away is on). Sending asks for Face ID / passcode, like Allow.
struct SessionView: View {
    let controller: PhoneController
    let sessionId: String

    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var editing: Bool

    var body: some View {
        Group {
            if let model = controller.model {
                if let session = model.sessions.first(where: { $0.sessionId == sessionId }) {
                    content(model: model, session: session)
                } else {
                    message("This session has ended on your Mac.")
                }
            } else {
                message(controller.status.text)
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(model: PhoneModel, session: SessionRecord) -> some View {
        let state: CharacterState = session.awaitingMessage ? .question : PhoneLook.characterState(for: session.state)
        let sent = model.sentMessages[sessionId] ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    BuddyFace(state: state, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(DisplayText.sanitized(session.project))
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .lineLimit(1)
                        Text(PhoneLook.sessionLine(session)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                if session.lastPrompt != nil || session.lastReply != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Latest")
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        if let prompt = session.lastPrompt { Bubble(author: "You", text: prompt, isClaude: false) }
                        if let reply = session.lastReply {
                            Bubble(author: "Claude", text: reply, isClaude: true)
                        } else if session.lastPrompt != nil, session.state == .working {
                            Text("Claude is working on it…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Text(Self.deliveryNote(for: session))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Message Claude", text: $draft, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($editing)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .disabled(sending)
                    HStack {
                        Text("\(draft.count)/\(MessageRecord.maxLength)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(draft.count > MessageRecord.maxLength ? Color.red : Color.secondary)
                        Spacer()
                        Button { send(model: model) } label: {
                            Label(sending ? "Sending" : "Send", systemImage: "faceid")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || !Self.canSend(draft))
                    }
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }

                if !sent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sent from this iPhone")
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        ForEach(sent.reversed(), id: \.messageId) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.text).font(.callout)
                                Text(record.sentAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private static func canSend(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= MessageRecord.maxLength
    }

    /// When Claude will get the message, in words.
    static func deliveryNote(for session: SessionRecord) -> String {
        if session.awaitingMessage { return "Claude finished and is waiting for you: it gets your message right away." }
        switch session.state {
        case .working, .waiting:
            return "Claude is working. It gets your message when this turn ends."
        case .idle, .finished, .error:
            return "Claude is not waiting now (it waits 10 minutes after a turn, or until someone uses the Mac). It gets your message the next time it finishes a turn."
        }
    }

    private func send(model: PhoneModel) {
        sending = true
        failure = nil
        let text = draft
        Task {
            defer { sending = false }
            do {
                try await model.send(message: text, to: sessionId)
                draft = ""
                editing = false
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// One side of the latest exchange: the prompt, or Claude's reply (selectable, so it can be copied).
private struct Bubble: View {
    let author: String
    let text: String
    let isClaude: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(DisplayText.sanitized(text))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            isClaude ? Color(.secondarySystemGroupedBackground) : PhoneLook.accent(.idle).opacity(0.15),
            in: RoundedRectangle(cornerRadius: 14))
        .padding(isClaude ? .trailing : .leading, 24)
        .accessibilityElement(children: .combine)
    }
}
