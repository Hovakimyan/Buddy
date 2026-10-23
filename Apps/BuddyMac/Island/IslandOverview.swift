import BuddyKit
import SwiftUI

/// The expanded island: the header (mute, settings, close), the focused session with the character, the other
/// sessions as pills, and under them the front card (an approval, a plan or a question, oldest first) or a status
/// card. Its height is what
/// `IslandGeometry.panelSize` reserves for the same content.
struct IslandOverview: View {
    let feed: any IslandFeed
    let ui: IslandUIState

    var body: some View {
        let focused = IslandLogic.focusedSession(
            sessions: feed.sessions, pending: feed.pending, questions: feed.questions, chosen: ui.chosenSession)
        let others = IslandLogic.otherSessions(feed.sessions, focused: focused?.id)
        VStack(spacing: 0) {
            IslandHeader(ui: ui, cardPending: !feed.pending.isEmpty || !feed.questions.isEmpty)
                .frame(height: ui.placement.barHeight)
            FocusedSessionView(session: focused, ui: ui, pendingCount: feed.pending.count + feed.questions.count)
                .frame(height: IslandLayout.focusHeight)
            if !others.isEmpty {
                HStack(spacing: IslandLayout.pillSpacing) {
                    ForEach(others, id: \.id) { session in
                        SessionPill(
                            session: session, state: pillState(session),
                            badge: IslandLogic.pillBadge(for: session, pending: feed.pending, questions: feed.questions),
                            character: ui.character, reduceMotion: ui.reduceMotion, onTap: { ui.onFocus(session.id) })
                        .frame(maxWidth: .infinity)
                    }
                    // Fewer pills than room keep their size instead of stretching across the island.
                    ForEach(others.count..<IslandLayout.maxPills, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .frame(height: IslandLayout.pillHeight)
                .padding(.top, IslandLayout.pillSpacing)
                .padding(.horizontal, IslandLayout.sidePadding)
            }
            card(focused: focused)
        }
        .padding(.bottom, IslandLayout.bottomPadding)
        .foregroundStyle(.white)
    }

    @ViewBuilder private func card(focused: Session?) -> some View {
        let room = IslandGeometry.cardRoom(
            placement: ui.placement, otherSessions: IslandLogic.otherSessions(feed.sessions, focused: focused?.id).count)
        switch IslandLogic.frontCard(pending: feed.pending, questions: feed.questions) {
        case .approval(let approval):
            approvalCard(approval, room: room)
                .id(approval.id)
                .padding(.top, IslandLayout.cardSpacing)
                .padding(.horizontal, IslandLayout.sidePadding)
                .transition(ui.reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        case .question(let question):
            // The controller keeps the card's state; without it (a preview) the card starts fresh.
            let model = ui.questionCard.flatMap { $0.id == question.id ? $0 : nil } ?? QuestionCardModel(question: question)
            QuestionCardView(
                model: model, height: min(model.naturalHeight, room), armed: ui.armedRequest == question.id,
                onEvent: ui.onQuestion,
                otherText: Binding(
                    get: { ui.questionCard?.otherText ?? "" },
                    set: { if ui.questionCard?.otherText != nil { ui.questionCard?.otherText = $0 } }))
            .id(question.id)
            .padding(.top, IslandLayout.cardSpacing)
            .padding(.horizontal, IslandLayout.sidePadding)
            .transition(ui.reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        case nil:
            statusCard
        }
    }

    @ViewBuilder private func approvalCard(_ approval: PendingApproval, room: CGFloat) -> some View {
        let project = feed.sessions.first { $0.id == approval.sessionId }?.project
        switch approval.kind {
        case .tool:
            ApprovalCardView(
                approval: approval, project: project, armed: ui.armedRequest == approval.id,
                onChoice: { ui.onChoice(approval, $0) }, accent: ui.accent,
                queueCount: IslandLogic.queueCount(pending: feed.pending, questions: feed.questions))
        case .plan:
            PlanCardView(
                approval: approval, height: min(PlanCardView.naturalHeight(for: approval), room),
                armed: ui.armedRequest == approval.id, onChoice: { ui.onPlanChoice(approval, $0) }, accent: ui.accent,
                project: project)
        }
    }

    @ViewBuilder private var statusCard: some View {
        if let status = ui.statusCard {
            StatusCardView(kind: status.kind, accent: ui.accent) {
                if let key = status.key { ui.onDismissStatus(key) }
            }
            .padding(.top, IslandLayout.cardSpacing)
            .padding(.horizontal, IslandLayout.sidePadding)
            .transition(.opacity)
        }
    }

    private func pillState(_ session: Session) -> CharacterState {
        CharacterState.resolve(
            session: session, approvalPending: feed.pending.contains { $0.sessionId == session.id },
            questionPending: feed.questions.contains { $0.sessionId == session.id }, quietFor: 0, islandVisible: true)
    }
}

/// Mute on the left of the notch; settings and close on its right. Close is hidden while a card waits, so the
/// card cannot be put away by accident (Escape still collapses the island).
private struct IslandHeader: View {
    let ui: IslandUIState
    let cardPending: Bool

    var body: some View {
        HStack(spacing: 4) {
            HeaderButton(
                symbol: ui.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: ui.muted ? "Unmute" : "Mute",
                action: ui.onToggleMute)
            Spacer(minLength: ui.placement.notchWidth)
            HeaderButton(symbol: "gearshape.fill", label: "Settings", action: ui.onOpenSettings)
            if !cardPending {
                HeaderButton(symbol: "xmark", label: "Close", action: ui.onClose)
            }
        }
        .padding(.horizontal, IslandLayout.sidePadding + 4)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The focused session: the character, the project and its steps, and its last tools, a new one scrolling in.
private struct FocusedSessionView: View {
    let session: Session?
    let ui: IslandUIState
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 12) {
            IslandCharacterView(ui: ui, size: IslandLayout.focusCharacterSize)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session?.project ?? "No sessions yet")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let session {
                        Text(IslandLogic.stepsText(session.toolCount))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                RecentToolsRow(tools: session.map(IslandLogic.recentTools(of:)) ?? [], reduceMotion: ui.reduceMotion)
            }
            Spacer(minLength: 0)
            Text(IslandLogic.statusWord(ui.face.state, pendingCount: pendingCount))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ui.accent)
                .lineLimit(1)
        }
        .padding(.horizontal, IslandLayout.sidePadding + 4)
    }
}

private struct RecentToolsRow: View {
    let tools: [RecentTool]
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tools) { tool in
                Text(tool.name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.white.opacity(0.75))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(height: 18, alignment: .leading)
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8),
                   value: tools.map(\.id))
    }
}

/// The compact island: the character left of the notch and a short status right of it.
struct CompactIsland: View {
    let feed: any IslandFeed
    let ui: IslandUIState

    var body: some View {
        let side = IslandLayout.compactExtraWidth / 2
        HStack(spacing: 0) {
            IslandCharacterView(ui: ui, size: IslandLayout.compactCharacterSize(barHeight: ui.placement.barHeight))
                .frame(width: side)
            Spacer(minLength: ui.placement.notchWidth)
            Text(IslandLogic.statusWord(ui.face.state, pendingCount: feed.pending.count + feed.questions.count))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ui.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: side - 8)
                .padding(.trailing, 8)
        }
    }
}
