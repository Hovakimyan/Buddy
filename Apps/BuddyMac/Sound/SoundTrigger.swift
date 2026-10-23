import BuddyKit
import Foundation

/// A named sound. The file name is the cue name (`<cue>.wav`, `.caf` or `.m4a`); the bundled set lives in
/// `Resources/sounds/<character folder>/`, and a file of the same name in the user's sounds folder replaces it.
enum SoundCue: String, CaseIterable, Sendable {
    case peek, open, close, hover, boop, annoyed, dizzy, greet, work, think, search, approval, question
    case approve, send, finish, error, rate, love, pop, proud, wink, yawn, sleep, tick
    case switchSession = "switch"
}

/// Terminal apps whose frontmost state means the person is already looking at the session.
enum TerminalApps {
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "org.alacritty",
    ]

    static func isTerminal(bundleID: String?) -> Bool {
        bundleID.map(bundleIDs.contains) ?? false
    }
}

/// Decides which cues a new engine snapshot should play, by comparing it with the previous one.
/// Pure value logic (no audio), so the rules are unit-tested.
///
/// - `work`: a SessionStart (a session's `starts` went up, or a new session arrived with one). A session first seen
///   through another event was already running (before Buddy started, or before it expired) and plays nothing.
/// - `think` / `search` / `rate`: a session's activity changes to thinking / searching / rate limited.
/// - `approval` / `question`: a request or question id not seen before (several in one snapshot make one cue).
/// - `finish` / `error`: a session's state changes to finished / error; skipped when a terminal app is frontmost.
///
/// A session seen for the first time is compared with "nothing", so what created it counts. Snapshots repeat the
/// same data many times and the very first one is whatever was already running; neither makes sound.
struct SoundTrigger: Sendable {
    mutating func cues(previous: EngineSnapshot?, current: EngineSnapshot, terminalFrontmost: Bool) -> [SoundCue] {
        guard let previous else { return [] }
        let before = Dictionary(previous.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        var started = false
        var activities: Set<SessionActivity> = []
        var states: Set<SessionState> = []
        for session in current.sessions {
            let old = before[session.id]
            if session.starts > (old?.starts ?? 0) { started = true }
            if old?.activity != session.activity { activities.insert(session.activity) }
            if old?.state != session.state { states.insert(session.state) }
        }

        var result: [SoundCue] = []
        if started { result.append(.work) }
        if activities.contains(.thinking) { result.append(.think) }
        if activities.contains(.searching) { result.append(.search) }
        if !Set(current.pending.map(\.id)).isSubset(of: Set(previous.pending.map(\.id))) { result.append(.approval) }
        if !Set(current.questions.map(\.id)).isSubset(of: Set(previous.questions.map(\.id))) { result.append(.question) }
        if !terminalFrontmost {
            if states.contains(.finished) { result.append(.finish) }
            if states.contains(.error) { result.append(.error) }
        }
        if activities.contains(.rateLimited) { result.append(.rate) }
        return result
    }
}
