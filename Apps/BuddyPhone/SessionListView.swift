import BuddyKit
import SwiftUI

/// The root screen: Buddy and what it is up to, then what waits for an answer, then the sessions, and a line saying
/// whether iCloud works.
struct SessionListView: View {
    let controller: PhoneController

    /// Re-renders every second (the timeline) so requests disappear at their expiry and countdowns stay fresh.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            screen
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await controller.model?.refresh() }
    }

    private var screen: some View {
        let model = controller.model
        let sessions = (model?.sessions ?? []).sorted { $0.updatedAt > $1.updatedAt }
        let approvals = model?.pendingApprovals ?? []
        let questions = model?.pendingQuestions ?? []
        let connected = model != nil
        // Checking iCloud, or connected but the first fetch is not back yet: a loading state, never an empty list.
        let loading = controller.status == .checking || (model.map { !$0.hasLoaded } ?? false)
        let state = loading
            ? .thinking
            : PhoneLook.overall(sessions: sessions, approvals: approvals.count, questions: questions.count, connected: connected)
        let headline = loading
            ? (title: "Looking for Claude", detail: "Checking your Mac's sessions in iCloud.")
            : PhoneLook.headline(sessions: sessions, approvals: approvals.count, questions: questions.count, connected: connected)
        let projects = Dictionary(sessions.map { ($0.sessionId, $0.project) }, uniquingKeysWith: { first, _ in first })

        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Hero(state: state, title: headline.title, detail: headline.detail)

                if let model, !questions.isEmpty || !approvals.isEmpty {
                    Group {
                        SectionTitle(text: "Waiting on you")
                        VStack(spacing: 12) {
                            ForEach(questions, id: \.requestId) { question in
                                NavigationLink(value: PhoneScreen.question(question.requestId)) {
                                    QuestionCard(question: question, project: projects[question.sessionId], now: model.now)
                                }
                            }
                            ForEach(approvals, id: \.requestId) { approval in
                                NavigationLink(value: PhoneScreen.approval(approval.requestId)) {
                                    ApprovalCard(approval: approval, project: projects[approval.sessionId], now: model.now)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if loading {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "Sessions")
                        SkeletonSessions()
                    }
                } else if connected {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "Sessions")
                        if sessions.isEmpty {
                            Text("No Claude Code sessions are running on your Mac.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(sessions.enumerated()), id: \.element.sessionId) { index, session in
                                    if index > 0 { Divider().padding(.leading, 74) }
                                    NavigationLink(value: PhoneScreen.session(session.sessionId)) {
                                        SessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                }

                Footer(status: controller.status, connected: connected)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }
}

/// Buddy, big, with what it is up to.
private struct Hero: View {
    let state: CharacterState
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 18) {
            BuddyFace(state: state, size: 108)
            VStack(alignment: .leading, spacing: 4) {
                Text("Buddy")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: title)
        .accessibilityElement(children: .combine)
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// A small coloured label: what kind of request, or the question's header.
private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }
}

/// Time left before the request goes back to the terminal.
private struct Countdown: View {
    let expiresAt: Date
    let now: Date

    var body: some View {
        let text = PhoneLook.countdown(until: expiresAt, now: now)
        Label(text, systemImage: "timer")
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(text == "Expired" ? Color.red : Color.secondary)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(text == "Expired" ? "Expired" : "Expires in \(text)")
    }
}

/// The shape every waiting request sits in, washed with its colour.
private struct RequestCard<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) { content }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).fill(color.opacity(0.07)).allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct ApprovalCard: View {
    let approval: ApprovalRecord
    let project: String?
    let now: Date

    var body: some View {
        let color = PhoneLook.accent(.approval)
        RequestCard(color: color) {
            HStack(spacing: 8) {
                Tag(text: DisplayText.sanitized(approval.tool), color: color)
                if let project { Text(DisplayText.sanitized(project)).font(.subheadline.weight(.semibold)).lineLimit(1) }
                Spacer(minLength: 4)
                Countdown(expiresAt: approval.expiresAt, now: now)
            }
            // Three lines are enough here; the approval screen shows all of it.
            Text(DisplayText.sanitized(approval.summary))
                .font(.callout.monospaced())
                .lineLimit(3)
                .foregroundStyle(.primary)
            Text("Tap to review").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct QuestionCard: View {
    let question: QuestionRecord
    let project: String?
    let now: Date

    var body: some View {
        let color = PhoneLook.accent(.question)
        RequestCard(color: color) {
            HStack(spacing: 8) {
                Tag(text: question.questions.first.map { DisplayText.sanitized($0.header) } ?? "Question", color: color)
                if let project { Text(DisplayText.sanitized(project)).font(.subheadline.weight(.semibold)).lineLimit(1) }
                Spacer(minLength: 4)
                Countdown(expiresAt: question.expiresAt, now: now)
            }
            // The first question is enough here; the question screen shows them one by one.
            if let first = question.questions.first {
                Text(DisplayText.sanitized(first.text)).font(.body.weight(.medium)).lineLimit(2)
            }
            Text(question.questions.count > 1 ? "\(question.questions.count) questions · tap to answer" : "Tap to answer")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SessionRow: View {
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 14) {
            BuddyFace(state: PhoneLook.characterState(for: session.state), size: 46, animated: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.sanitized(session.project)).font(.headline).lineLimit(1)
                Text(PhoneLook.sessionLine(session)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.awaitingMessage {
                Image(systemName: "bubble.left.fill").foregroundStyle(PhoneLook.accent(.question)).accessibilityHidden(true)
            } else {
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Placeholder rows while the first fetch runs, pulsing gently (still under Reduce Motion).
private struct SkeletonSessions: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                if index > 0 { Divider().padding(.leading, 74) }
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: 40, height: 40).padding(3)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(.quaternary).frame(width: [120, 90, 140][index], height: 12)
                        Capsule().fill(.quaternary).frame(width: [170, 130, 110][index], height: 10)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .opacity(dim ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading sessions")
    }
}

private struct Footer: View {
    let status: PhoneCloudStatus
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(connected ? Color.green : Color.orange).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(status.text).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Built by Sergey Hovakimyan")
                Text("·")
                Link("GitHub", destination: URL(string: "https://github.com/Hovakimyan/Buddy")!)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
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
