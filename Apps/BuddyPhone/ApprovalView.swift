import BuddyKit
import SwiftUI

/// One permission request, in full. Allow asks for Face ID / passcode; Deny does not. A command too long to
/// show is denied here or allowed on the Mac. Nothing here truncates the text: the whole summary is shown (it
/// scrolls), with hidden characters made visible by `DisplayText`.
struct ApprovalView: View {
    let controller: PhoneController
    let requestId: UUID

    @State private var shownAt: Date?
    @State private var working = false
    @State private var failure: String?
    @State private var gaveUp = false

    var body: some View {
        Group {
            if let model = controller.model {
                if let approval = model.approval(id: requestId) {
                    content(model: model, approval: approval)
                } else if gaveUp {
                    message("This request is no longer available.")
                } else {
                    ProgressView("Loading request").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                message(controller.status.text)
            }
        }
        .navigationTitle("Approval")
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

    private func content(model: PhoneModel, approval: ApprovalRecord) -> some View {
        // Ticks fast while the arming delay runs, then once a second for the countdown.
        let armed = shownAt.map { Arming.isArmed(shownAt: $0, now: model.now) } ?? false
        return TimelineView(.periodic(from: .now, by: armed ? 1 : 0.1)) { _ in
            let shown = ApprovalPresentation(
                approval: approval, decision: model.decision(for: requestId), shownAt: shownAt ?? model.now, now: model.now)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shown.tool).font(.title3.monospaced().weight(.semibold))
                    Spacer()
                    Text(shown.countdown).font(.subheadline).foregroundStyle(shown.isExpired ? .red : .secondary)
                }
                ScrollView {
                    Text(shown.summary)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .scrollBounceBehavior(.basedOnSize)

                if let notice = shown.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }

                HStack(spacing: 12) {
                    Button(role: .destructive) { decide(.deny, model: model) } label: {
                        Text("Deny").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!shown.canDeny || working)

                    Button { decide(.allow, model: model) } label: {
                        Label(shown.allowTitle, systemImage: shown.allowsOnlyOnMac ? "desktopcomputer" : "faceid")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!shown.canAllow || working)
                }
                .controlSize(.large)
            }
            .padding()
        }
        .onAppear { if shownAt == nil { shownAt = model.now } }
    }

    private func decide(_ decision: Decision, model: PhoneModel) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                switch decision {
                case .allow: try await model.allow(requestId)
                case .deny: try await model.deny(requestId)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
