import BuddyKit
import SwiftUI

/// What the phone's Buddy shows, and the words beside it. Kept pure so it is unit-tested without a view.
enum PhoneLook {
    /// The character for one session's state.
    static func characterState(for state: SessionState) -> CharacterState {
        switch state {
        case .idle: .idle
        case .working: .working
        case .waiting: .approval
        case .finished: .finished
        case .error: .error
        }
    }

    /// The character for the whole screen: what needs the person first, then what is running.
    static func overall(
        sessions: [SessionRecord], approvals: Int, questions: Int, connected: Bool
    ) -> CharacterState {
        guard connected else { return .sleeping }
        if questions > 0 { return .question }
        if approvals > 0 { return .approval }
        if sessions.contains(where: \.awaitingMessage) { return .question }
        if sessions.contains(where: { $0.state == .error }) { return .error }
        if sessions.contains(where: { $0.state == .working || $0.state == .waiting }) { return .working }
        if sessions.contains(where: { $0.state == .finished }) { return .finished }
        return sessions.isEmpty ? .sleeping : .idle
    }

    /// The headline and the line under it.
    static func headline(
        sessions: [SessionRecord], approvals: Int, questions: Int, connected: Bool
    ) -> (title: String, detail: String) {
        guard connected else { return ("Not connected", "Buddy can't reach iCloud right now.") }
        if questions > 0 {
            return ("Claude is asking", questions == 1 ? "1 question is waiting for you." : "\(questions) questions are waiting for you.")
        }
        if approvals > 0 {
            return ("Claude needs your OK", approvals == 1 ? "1 request is waiting for you." : "\(approvals) requests are waiting for you.")
        }
        if let waiting = sessions.first(where: \.awaitingMessage) {
            return ("Your turn", "Claude finished in \(DisplayText.sanitized(waiting.project)) and waits for your message.")
        }
        let busy = sessions.filter { $0.state == .working || $0.state == .waiting }.count
        if busy > 0 { return ("Working", busy == 1 ? "1 session is busy on your Mac." : "\(busy) sessions are busy on your Mac.") }
        if sessions.contains(where: { $0.state == .finished }) { return ("Done", "Claude finished. Nothing needs you.") }
        if sessions.isEmpty { return ("Nothing running", "Start Claude Code on your Mac and it shows up here.") }
        return ("All quiet", sessions.count == 1 ? "1 session is open on your Mac." : "\(sessions.count) sessions are open on your Mac.")
    }

    /// "Working · Edit · 2 agents"
    static func sessionLine(_ session: SessionRecord) -> String {
        if session.awaitingMessage { return "Waiting for your message" }
        var parts = [session.state.label]
        if let tool = session.lastTool { parts.append(DisplayText.sanitized(tool)) }
        if session.agentCount > 0 { parts.append(session.agentCount == 1 ? "1 agent" : "\(session.agentCount) agents") }
        return parts.joined(separator: " · ")
    }

    /// "Expires in 9:41", or "Expired".
    static func countdown(until expiry: Date, now: Date) -> String {
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return "Expired" }
        let seconds = Int(remaining.rounded(.up))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    @MainActor static func accent(_ state: CharacterState) -> Color { Block().accent(for: state) }
}
