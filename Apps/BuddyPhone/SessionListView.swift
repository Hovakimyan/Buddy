import BuddyKit
import SwiftUI

/// The root screen: pending approvals on top, then the sessions, and a line saying whether iCloud works.
struct SessionListView: View {
    let controller: PhoneController

    /// Re-renders every second (the timeline) so approvals disappear at their expiry and countdowns stay fresh.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            list
        }
        .navigationTitle("Buddy")
        .refreshable { await controller.model?.refresh() }
    }

    private var list: some View {
        List {
            if let model = controller.model {
                let pending = model.pendingApprovals
                if !pending.isEmpty {
                    Section("Needs approval") {
                        ForEach(pending, id: \.requestId) { approval in
                            NavigationLink(value: PhoneScreen.approval(approval.requestId)) { PendingRow(approval: approval, now: model.now) }
                        }
                    }
                }
                let asking = model.pendingQuestions
                if !asking.isEmpty {
                    Section("Claude is asking") {
                        ForEach(asking, id: \.requestId) { question in
                            NavigationLink(value: PhoneScreen.question(question.requestId)) {
                                QuestionRow(question: question, now: model.now)
                            }
                        }
                    }
                }
                Section("Sessions") {
                    if model.sessions.isEmpty {
                        Text("No Claude Code sessions are running on your Mac.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.sessions.sorted { $0.updatedAt > $1.updatedAt }, id: \.sessionId) { session in
                            SessionRow(session: session)
                        }
                    }
                }
            }
            Section("About Buddy") {
                Text("Built by Sergey Hovakimyan")
                Link("GitHub repository", destination: URL(string: "https://github.com/Hovakimyan/Buddy")!)
            }
            Section {
                Text(controller.status.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PendingRow: View {
    let approval: ApprovalRecord
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DisplayText.sanitized(approval.tool)).font(.headline)
            // Two lines of the summary are enough here; the approval screen shows all of it.
            Text(DisplayText.sanitized(approval.summary))
                .font(.subheadline.monospaced())
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Text(Self.remaining(approval, now: now)).font(.caption).foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }

    private static func remaining(_ approval: ApprovalRecord, now: Date) -> String {
        let seconds = max(0, Int(approval.expiresAt.timeIntervalSince(now).rounded(.up)))
        return "Expires in \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

private struct QuestionRow: View {
    let question: QuestionRecord
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The first question is enough here; the question screen shows them one by one.
            if let first = question.questions.first {
                Text(DisplayText.sanitized(first.header)).font(.headline)
                Text(DisplayText.sanitized(first.text)).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
            }
            Text(QuestionView.countdown(question, now: now)).font(.caption).foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }
}

private struct SessionRow: View {
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(session.state.color).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.sanitized(session.project)).font(.headline)
                HStack(spacing: 4) {
                    Text(session.state.label)
                    if let tool = session.lastTool { Text("· " + DisplayText.sanitized(tool)) }
                    Text("· " + session.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension SessionState {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Waiting"
        case .finished: "Finished"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle: .gray
        case .working: .green
        case .waiting: .orange
        case .finished: .blue
        case .error: .red
        }
    }
}
