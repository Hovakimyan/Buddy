import Foundation

/// What the character shows. Owned by the app, not by a character; `resolve` is the single place
/// that turns session state into one of these.
public enum CharacterState: String, CaseIterable, Sendable {
    case idle, working, thinking, searching, approval, question, error, finished, rateLimited, sleeping, dizzy
}

/// A one-shot expression shown on top of the state.
public enum CharacterEmote: String, CaseIterable, Sendable {
    case love, surprised, proud, wink, yawn, happy, annoyed, listening
}

extension CharacterState {
    /// How long a finished session shows `finished` before it counts as idle.
    static let finishedHold: TimeInterval = 5
    /// How long the island must be quiet and visible before the character falls asleep.
    static let sleepAfter: TimeInterval = 120

    /// The state for the focused `session` (nil when there is none). `quietFor` is the time since the
    /// last session event. Never returns `dizzy`: the island sets that from clicks.
    public static func resolve(
        session: Session?,
        approvalPending: Bool,
        questionPending: Bool,
        quietFor: TimeInterval,
        islandVisible: Bool
    ) -> CharacterState {
        if questionPending { return .question }
        if approvalPending { return .approval }
        guard let session else { return idleOrSleeping(quietFor, islandVisible) }
        if session.activity == .asking { return .question }
        switch session.state {
        case .error:
            return .error
        case .finished:
            return quietFor < finishedHold ? .finished : idleOrSleeping(quietFor, islandVisible)
        case .idle:
            return idleOrSleeping(quietFor, islandVisible)
        case .working, .waiting:
            switch session.activity {
            case .thinking: return .thinking
            case .searching: return .searching
            case .rateLimited: return .rateLimited
            case .none, .asking: return .working
            }
        }
    }

    private static func idleOrSleeping(_ quietFor: TimeInterval, _ islandVisible: Bool) -> CharacterState {
        islandVisible && quietFor >= sleepAfter ? .sleeping : .idle
    }
}

/// Picks which session the island shows.
public enum SessionFocus {
    /// A session with a pending card wins (approvals first, then questions, each in the order given),
    /// then `chosen` if it is a live session, then the most recently updated one; nil without sessions.
    public static func focused(
        sessions: [Session],
        approvalSessionIds: [String],
        questionSessionIds: [String],
        chosen: String?
    ) -> String? {
        let live = Set(sessions.map(\.id))
        if let pending = (approvalSessionIds + questionSessionIds).first(where: live.contains) { return pending }
        if let chosen, live.contains(chosen) { return chosen }
        return sessions.max { $0.updatedAt < $1.updatedAt }?.id
    }
}
