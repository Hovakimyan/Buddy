import BuddyKit
import CoreGraphics
import Foundation

/// What the director tells the island to react to.
enum DirectorEvent: Equatable {
    case emote(CharacterEmote), dizzyStarted, dizzyEnded, boop, greet
}

/// Turns hover, click and greet input into timed emotes and the dizzy state. Pure: the caller passes the time
/// and calls `tick` regularly; events are queued by the input methods and returned (once) by `tick`.
struct CharacterDirector {
    static let longHover: TimeInterval = 1.9
    static let loveCooldown: TimeInterval = 6
    static let loveRearmDistance: CGFloat = 40
    static let clickWindow: TimeInterval = 1.7
    static let clicksForDizzy = 3
    static let dizzyDuration: TimeInterval = 3.3
    static let greetingDuration: TimeInterval = 4
    static let awayBeforeGreeting: TimeInterval = 180

    /// When the dizzy state ends; nil when not dizzy.
    private(set) var dizzyUntil: Date?
    /// The latest emote and when it started. Never cleared here: the character decides how long it shows.
    private(set) var emote: (CharacterEmote, Date)?
    private(set) var boopedAt: Date?
    /// Non-nil for `greetingDuration` after `greet`.
    private(set) var greetingStartedAt: Date?
    private(set) var hovering = false

    private var hoverStartedAt: Date?
    private var pointer: CGPoint?
    private var lastLove: (at: Date, pointer: CGPoint)?
    private var clicks: [Date] = []
    private var pending: [DirectorEvent] = []

    /// Date arithmetic is floating point, so thresholds compare with a microsecond of slack.
    private static func elapsed(_ seconds: TimeInterval, since start: Date, now: Date) -> Bool {
        now.timeIntervalSince(start) >= seconds - 1e-6
    }

    mutating func hoverBegan(at point: CGPoint, now: Date) {
        hovering = true
        hoverStartedAt = now
        pointer = point
    }

    mutating func hoverMoved(to point: CGPoint, now: Date) {
        pointer = point
    }

    mutating func hoverEnded(now: Date) {
        hovering = false
        hoverStartedAt = nil
        pointer = nil
    }

    /// The first and second click in the window boop; the third is dizzy. Clicks while dizzy are ignored.
    mutating func click(now: Date) {
        guard dizzyUntil == nil else { return }
        clicks = clicks.filter { now.timeIntervalSince($0) <= Self.clickWindow + 1e-6 }
        if clicks.count + 1 >= Self.clicksForDizzy {
            clicks = []
            dizzyUntil = now.addingTimeInterval(Self.dizzyDuration)
            pending.append(.dizzyStarted)
        } else {
            clicks.append(now)
            boopedAt = now
            pending.append(.boop)
            show(.annoyed, at: now)
        }
    }

    mutating func greet(now: Date) {
        greetingStartedAt = now
        pending.append(.greet)
    }

    /// Greets at `to` when the Mac was away for 3 minutes or more.
    mutating func screenAway(from: Date, to: Date) {
        guard Self.elapsed(Self.awayBeforeGreeting, since: from, now: to) else { return }
        greet(now: to)
    }

    /// Advances the timers and returns the events since the last call.
    mutating func tick(now: Date) -> [DirectorEvent] {
        if let until = dizzyUntil, Self.elapsed(0, since: until, now: now) {
            dizzyUntil = nil
            pending.append(.dizzyEnded)
            show(.happy, at: now)
            // A hover that carried through the dizzy spell must last a full 1.9 s again before love.
            if hoverStartedAt != nil { hoverStartedAt = now }
        }
        if let start = greetingStartedAt, Self.elapsed(Self.greetingDuration, since: start, now: now) {
            greetingStartedAt = nil
        }
        if dizzyUntil == nil, let start = hoverStartedAt, let pointer,
           Self.elapsed(Self.longHover, since: start, now: now), canLove(at: pointer, now: now) {
            lastLove = (now, pointer)
            show(.love, at: now)
        }
        defer { pending = [] }
        return pending
    }

    private func canLove(at point: CGPoint, now: Date) -> Bool {
        guard let last = lastLove else { return true }
        return Self.elapsed(Self.loveCooldown, since: last.at, now: now)
            && hypot(point.x - last.pointer.x, point.y - last.pointer.y) >= Self.loveRearmDistance
    }

    private mutating func show(_ new: CharacterEmote, at now: Date) {
        emote = (new, now)
        pending.append(.emote(new))
    }
}
