import BuddyKit
import SwiftUI

/// How Block's timeline runs.
enum BlockPace: Equatable {
    /// Redrawn every `minimumInterval` seconds at most.
    case animated(minimumInterval: TimeInterval)
    /// Paused (Reduce Motion): redrawn only at `BlockView.stillDates`, when the picture really changes.
    case still
}

/// Block on a timeline. Every frame is `BlockFrame` at the timeline's date, so what shows depends only on the
/// input and that date: no timers, no stored random state. 30 frames a second is smooth for this motion and
/// half the work of a 60 Hz display (the island is always on screen); 10 while sleeping, where nothing moves fast.
/// Under Reduce Motion nothing moves, so the timeline is paused and redraws only when the look changes.
struct BlockView: View {
    let input: CharacterInput

    var body: some View {
        switch Self.pace(for: input) {
        case .animated(let interval):
            TimelineView(.animation(minimumInterval: interval)) { context in
                BlockFrame(input: input, now: context.date)
            }
        case .still:
            let now = Date()
            TimelineView(.explicit(Self.stillDates(for: input).filter { $0 > now })) { _ in
                BlockFrame(input: input, now: Self.stillMoment(Date(), stateStartedAt: input.stateStartedAt))
            }
        }
    }

    static func pace(for input: CharacterInput) -> BlockPace {
        if input.reduceMotion { return .still }
        return .animated(minimumInterval: input.state == .sleeping ? 0.1 : 1.0 / 30)
    }

    /// When a paused picture must be redrawn: the state's start; an emote's start, middle (a wink or a yawn shows
    /// then) and end; a boop's start and end; the greeting's start and end. Sorted, without repeats.
    static func stillDates(for input: CharacterInput) -> [Date] {
        var dates: Set<Date> = [input.stateStartedAt]
        if let emote = input.emote, let start = input.emoteStartedAt {
            let duration = BlockPose.duration(of: emote)
            dates.formUnion([start, start.addingTimeInterval(duration / 2), start.addingTimeInterval(duration)])
        }
        if let booped = input.boopedAt { dates.formUnion([booped, booped.addingTimeInterval(0.45)]) }
        if let greeting = input.greetingStartedAt {
            dates.formUnion([greeting, greeting.addingTimeInterval(CharacterDirector.greetingDuration)])
        }
        return dates.sorted()
    }

    /// The moment a paused picture shows for `date`: `date` itself, or a little later when that falls inside a
    /// blink, so the picture never freezes with the lids half down.
    static func stillMoment(_ date: Date, stateStartedAt: Date) -> Date {
        var moment = date
        for _ in 0..<12 where BlockPose.blink(at: max(0, moment.timeIntervalSince(stateStartedAt))) != 0 {
            moment = moment.addingTimeInterval(0.05)
        }
        return moment
    }
}

/// One frame of Block at `now`.
struct BlockFrame: View {
    let input: CharacterInput
    let now: Date

    var body: some View {
        let pose = BlockPose(input, now: now)
        Canvas { context, size in BlockDrawing.draw(pose, in: context, size: size) }
            .frame(width: input.size, height: input.size)
    }
}

/// Everything that moves, for one frame. Lengths are in body sides; the stretch is anchored at the bottom of the
/// body and the rotation turns it about its centre.
struct BlockPose {
    var body: BlockRGB
    /// Badges, particles and the sweat drop show only at island size; at pill size they would be specks.
    var detailed: Bool
    var offset = CGVector.zero
    var stretch = CGSize(width: 1, height: 1)
    var rotation = Angle.zero
    var left = BlockEye()
    var right = BlockEye()
    /// Where the pupils point, each axis -1...1 (y down).
    var gaze = CGVector.zero
    var blush: Double = 0
    var badge: BlockBadge?
    /// How far the drop has run down the side, 0...1; nil without a drop.
    var sweat: Double?
    var particles: [BlockParticle] = []

    init(_ input: CharacterInput, now: Date) {
        body = BlockRGB.accent(for: input.state)
        detailed = input.size >= 24
        let look = CGVector(dx: Self.clamp(input.look.dx), dy: Self.clamp(input.look.dy))
        gaze = look
        let motion = !input.reduceMotion
        applyState(input.state, t: max(0, now.timeIntervalSince(input.stateStartedAt)), motion: motion)
        var droppingIn = false
        if let start = input.greetingStartedAt {
            droppingIn = applyGreeting(now.timeIntervalSince(start), motion: motion)
        }
        if let emote = input.emote, let start = input.emoteStartedAt {
            let e = now.timeIntervalSince(start)
            if e >= 0, e < Self.duration(of: emote) { applyEmote(emote, e: e, motion: motion, look: look) }
        }
        if let booped = input.boopedAt { applyBoop(now.timeIntervalSince(booped), motion: motion, look: look) }
        if input.hovering {
            left.scale *= 1.06
            right.scale *= 1.06
        }
        // A jump or stretch on top of a hop could lift the badge out of the frame; the drop-in starts outside on
        // purpose.
        if detailed, badge != nil, !droppingIn { keepBadgeInside() }
        if !detailed {
            badge = nil
            sweat = nil
            particles = []
            // The pill has no room around the body: it stays in place and squashes half as much.
            offset = .zero
            stretch = CGSize(width: 1 + (stretch.width - 1) / 2, height: 1 + (stretch.height - 1) / 2)
        }
    }

    // MARK: States

    private mutating func applyState(_ state: CharacterState, t: TimeInterval, motion: Bool) {
        let lid = Self.blink(at: t)
        switch state {
        case .idle:
            if motion { breathe(t, period: 3.2, depth: 0.025) }
            blink(lid)
        case .working:
            eyes { $0.openness = 0.78 }
            gaze = Self.dart(t)
            if motion { offset.dy = -0.015 * abs(sin(2 * .pi * t / 0.5)) }
            badge = .dots(phase: motion ? t : nil)
            blink(lid)
        case .thinking:
            gaze = CGVector(dx: 0.65 + (motion ? 0.15 * sin(2 * .pi * t / 2.6) : 0), dy: -0.8)
            rotation = .degrees(5 + (motion ? 1.5 * sin(2 * .pi * t / 3) : 0))
            badge = .dots(phase: motion ? t : nil)
            blink(lid)
        case .searching:
            gaze = CGVector(dx: 0.9 * sin(2 * .pi * t / 1.6), dy: 0.1)
            eyes { $0.scale = 1.05 }
            if motion {
                rotation = .degrees(3 * sin(2 * .pi * t / 1.6))
                offset.dx = 0.02 * sin(2 * .pi * t / 1.6)
            }
            blink(lid)
        case .approval:
            eyes {
                $0.scale = 1.2
                $0.pupil = 0.85
            }
            badge = .exclamation
            if motion {
                if t < 0.5 {
                    // The hop: up and stretched.
                    offset.dy = -0.13 * Self.bump(t, 0.5)
                    squash(-0.07 * Self.bump(t, 0.5))
                } else if t < 0.7 {
                    squash(0.12 * Self.bump(t - 0.5, 0.2))
                } else {
                    // Then a gentle bounce while waiting.
                    offset.dy = -0.035 * abs(sin(.pi * (t - 0.7) / 0.8))
                }
            }
            blink(lid)
        case .question:
            rotation = .degrees(-9 * (motion ? Self.ease(t / 0.35) : 1))
            left.scale = 0.94
            right.scale = 1.18
            gaze.dy = min(gaze.dy, -0.3)
            badge = .question
            blink(lid)
        case .error:
            eyes { $0.shape = .flat }
            if motion, t < 0.6 { offset.dx = 0.07 * sin(2 * .pi * 6 * t) * (1 - t / 0.6) }
            stretch.height = 0.97
        case .finished:
            eyes { $0.shape = .arc }
            if motion {
                // Crouch, spin with a little hop, land with a squash; sparkles after.
                squash(0.12 * Self.bump(t, 0.5) + 0.1 * Self.bump(t - 0.95, 0.3))
                if t > 0.25, t < 0.95 {
                    rotation = .degrees(360 * Self.ease((t - 0.25) / 0.7))
                    offset.dy = -0.12 * Self.bump(t - 0.25, 0.7)
                }
                sparkles(t - 0.6)
            }
        case .rateLimited:
            eyes { $0.openness = 0.42 }
            gaze.dy = 0.35
            stretch = CGSize(width: 1.02, height: 0.96)
            sweat = motion ? t.truncatingRemainder(dividingBy: 1.8) / 1.8 : 0
        case .sleeping:
            eyes { $0.shape = .closed }
            if motion {
                breathe(t, period: 4.5, depth: 0.04)
                sleepZs(t)
            } else {
                badge = .sleep
            }
        case .dizzy:
            eyes { $0.shape = .spiral(motion ? .degrees(t * 540) : .zero) }
            if motion {
                if t < 1.3 {
                    rotation = .degrees(720 * Self.ease(t / 1.3))
                } else {
                    rotation = .degrees(7 * sin(2 * .pi * (t - 1.3) / 1.1))
                    offset.dx = 0.03 * sin(2 * .pi * (t - 1.3) / 1.1)
                }
            }
        }
    }

    // MARK: Emotes

    /// How long each emote shows; after that the state's look is back.
    static func duration(of emote: CharacterEmote) -> TimeInterval {
        switch emote {
        case .love: 2.4
        case .surprised: 1.0
        case .proud: 1.8
        case .wink: 0.9
        case .yawn: 2.0
        case .happy: 1.6
        case .annoyed: 1.1
        case .listening: 3.0
        }
    }

    private mutating func applyEmote(_ emote: CharacterEmote, e: TimeInterval, motion: Bool, look: CGVector) {
        let d = Self.duration(of: emote)
        // Eases body changes in and out so the emote does not snap.
        let envelope = Self.ease(e / 0.15) * Self.ease((d - e) / 0.25)
        left = BlockEye()
        right = BlockEye()
        switch emote {
        case .love:
            eyes { $0.shape = .heart }
            blush = 1
            if motion {
                let pulse = 1 + 0.04 * sin(2 * .pi * e / 0.6) * envelope
                stretch = CGSize(width: stretch.width * pulse, height: stretch.height * pulse)
                hearts(e)
            }
        case .surprised:
            eyes {
                $0.scale = 1.35
                $0.pupil = 0.6
            }
            if motion {
                offset.dy -= 0.2 * Self.bump(e, 0.45)
                squash(-0.08 * Self.bump(e, 0.45))
            }
        case .proud:
            eyes { $0.shape = .star }
            gaze.dy = -0.3
            if motion {
                stretch = CGSize(
                    width: stretch.width * (1 + 0.08 * envelope), height: stretch.height * (1 + 0.05 * envelope))
            }
        case .wink:
            if e > 0.1, e < 0.7 { right.shape = .arc }
            blush = 0.4
        case .yawn:
            if e > 0.15, e < 1.75 { eyes { $0.shape = .closed } } else { eyes { $0.openness = 0.6 } }
            if motion { squash(-0.1 * Self.bump(e, d)) }
        case .happy:
            eyes { $0.shape = .arc }
            blush = 0.8
            if motion, e < 1.2 { offset.dy -= 0.05 * abs(sin(.pi * e / 0.4)) }
        case .annoyed:
            eyes { $0.openness = 0.42 }
            // Lids slope down towards the middle.
            left.lidTilt = 0.35
            right.lidTilt = -0.35
            gaze = CGVector(dx: -0.5, dy: 0.15)
            if motion, e < 0.6 { offset.dx += 0.04 * sin(2 * .pi * 5 * e) * (1 - e / 0.6) }
        case .listening:
            gaze = CGVector(dx: Self.clamp(look.dx * 1.3), dy: Self.clamp(look.dy * 1.3))
            eyes { $0.scale = 1.05 }
            if motion {
                rotation += .degrees(7 * look.dx * envelope)
                offset.dx += 0.03 * look.dx * envelope
            }
        }
    }

    // MARK: Reactions

    /// Drops in, lands with a squash, looks around, blinks twice; about 4 s. True while it is still falling.
    private mutating func applyGreeting(_ g: TimeInterval, motion: Bool) -> Bool {
        guard g >= 0, g < 4 else { return false }
        if motion {
            if g < 0.45 {
                let p = g / 0.45
                offset.dy -= 1.3 * (1 - p * p)
                squash(-0.07)
            } else {
                squash(0.18 * Self.bump(g - 0.45, 0.35))
            }
        }
        if g >= 1, g < 2.6 { gaze = CGVector(dx: 0.9 * sin(2 * .pi * (g - 1) / 1.6), dy: -0.1) }
        blink(max(Self.lid(g - 2.8), Self.lid(g - 3.1)))
        return motion && g < 0.45
    }

    /// Lowers the body just enough that the top of the badge stays inside the frame.
    private mutating func keepBadgeInside() {
        let top = BlockDrawing.badgeTop(stretch: stretch, rotation: rotation) + offset.dy
        let highest = BlockDrawing.highestBadgeTop
        if top < highest { offset.dy += highest - top }
    }

    /// A click: the eyes squeeze shut and the body flinches away from the pointer.
    private mutating func applyBoop(_ b: TimeInterval, motion: Bool, look: CGVector) {
        guard b >= 0, b < 0.45 else { return }
        if b < 0.22 { blink(1) }
        if motion {
            squash(0.14 * Self.bump(b, 0.45))
            offset.dx -= 0.05 * (look.dx < 0 ? -1 : 1) * Self.bump(b, 0.45)
        }
    }

    // MARK: Pieces

    private mutating func eyes(_ change: (inout BlockEye) -> Void) {
        change(&left)
        change(&right)
    }

    /// Lowers the lids of open round eyes by `amount` (1 shut).
    private mutating func blink(_ amount: CGFloat) {
        eyes { if $0.shape == .round { $0.openness *= 1 - amount } }
    }

    /// Wider and shorter for positive `amount`, taller and thinner for negative.
    private mutating func squash(_ amount: CGFloat) {
        stretch = CGSize(width: stretch.width * (1 + amount * 0.8), height: stretch.height * (1 - amount))
    }

    private mutating func breathe(_ t: TimeInterval, period: TimeInterval, depth: CGFloat) {
        squash(-depth * sin(2 * .pi * t / period))
    }

    /// A few sparkles twinkling around the body, `t` seconds after they start, for 2.4 s.
    private mutating func sparkles(_ t: TimeInterval) {
        guard t >= 0, t < 2.4 else { return }
        let spots = [(-0.62, -0.42), (0.6, -0.5), (0.64, 0.12), (-0.64, 0.18), (0.04, -0.7)]
        for (i, spot) in spots.enumerated() {
            let since = t - Double(i) * 0.17
            guard since >= 0 else { continue }
            let size = 0.14 * Self.bump(since.truncatingRemainder(dividingBy: 0.9), 0.7)
            if size > 0 {
                particles.append(BlockParticle(kind: .sparkle, position: CGPoint(x: spot.0, y: spot.1), size: size, opacity: 1))
            }
        }
    }

    /// Hearts floating up from the top of the body.
    private mutating func hearts(_ e: TimeInterval) {
        for (i, x) in [-0.3, 0.32, 0.02].enumerated() {
            let since = e - Double(i) * 0.45
            guard since >= 0, since < 1.3 else { continue }
            let p = since / 1.3
            particles.append(
                BlockParticle(
                    kind: .heart, position: CGPoint(x: x + 0.04 * sin(2 * .pi * p), y: -0.42 - 0.32 * p),
                    size: 0.12 + 0.04 * p, opacity: min(1, p * 4) * (1 - p)))
        }
    }

    /// Three "z"s drifting up and to the right, one every second.
    private mutating func sleepZs(_ t: TimeInterval) {
        for i in 0..<3 {
            let since = t - Double(i)
            guard since >= 0 else { continue }
            let p = since.truncatingRemainder(dividingBy: 3) / 3
            particles.append(
                BlockParticle(
                    kind: .sleepZ, position: CGPoint(x: 0.36 + 0.2 * p, y: -0.48 - 0.24 * p), size: 0.13 + 0.09 * p,
                    opacity: Self.bump(p, 1)))
        }
    }

    // MARK: Timing

    /// How far the lids are down for blinks, `t` seconds into a state: one blink in each 3.5 s window, 1.2...2.7 s
    /// into it (so 2-5 s apart, none in the first second), a quarter of them double. Pseudo-random from the window
    /// number, so the same moment always looks the same.
    static func blink(at t: TimeInterval) -> CGFloat {
        let window = (t / 3.5).rounded(.down)
        let k = Int(window)
        let at = window * 3.5 + 1.2 + 1.5 * noise(k, 0)
        var closed = lid(t - at)
        if noise(k, 1) < 0.25 { closed = max(closed, lid(t - at - 0.3)) }
        return closed
    }

    /// One blink `dt` seconds after it began: shut at 80 ms, open again at 160 ms.
    private static func lid(_ dt: TimeInterval) -> CGFloat { bump(dt, 0.16) }

    /// Eyes darting about while working: a new spot every 0.55 s, reached in 0.12 s.
    private static func dart(_ t: TimeInterval) -> CGVector {
        let k = Int((t / 0.55).rounded(.down))
        func spot(_ k: Int) -> CGVector { CGVector(dx: noise(k, 2) * 1.6 - 0.8, dy: noise(k, 3) * 0.5) }
        let from = spot(k - 1), to = spot(k)
        let f = ease((t - Double(k) * 0.55) / 0.12)
        return CGVector(dx: from.dx + (to.dx - from.dx) * f, dy: from.dy + (to.dy - from.dy) * f)
    }

    /// A value in 0..<1 that looks random but is fixed for (`k`, `salt`).
    static func noise(_ k: Int, _ salt: UInt64) -> Double {
        var x = UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15 &+ (salt &+ 1) &* 0xD1B5_4A32_D192_ED03
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE5_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }

    /// 0, up to 1, back to 0 over `duration`; 0 outside it.
    static func bump(_ t: TimeInterval, _ duration: TimeInterval) -> CGFloat {
        t >= 0 && t <= duration ? sin(.pi * t / duration) : 0
    }

    /// Smoothstep of `x` clamped to 0...1.
    static func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    private static func clamp(_ v: CGFloat) -> CGFloat { min(max(v, -1), 1) }
}

struct BlockEye {
    var shape: BlockEyeShape = .round
    var scale: CGFloat = 1
    var pupil: CGFloat = 1
    /// 1 open, 0 shut; the lid comes down from the top.
    var openness: CGFloat = 1
    /// Lowers the lid's right end (positive) or left end (negative), in eye heights.
    var lidTilt: CGFloat = 0
}

enum BlockEyeShape: Equatable {
    /// White rounded shape, dark pupil, catch-light.
    case round
    /// A flat dash.
    case flat
    /// A happy upward arc.
    case arc
    /// A shut, downward curve.
    case closed
    case spiral(Angle)
    case heart
    case star
}

enum BlockBadge {
    /// Three dots; `phase` animates them, nil holds them still.
    case dots(phase: TimeInterval?)
    case exclamation
    case question
    /// A still "z", the Reduce Motion stand-in for the drifting ones.
    case sleep
}

struct BlockParticle {
    enum Kind { case sparkle, heart, sleepZ }
    var kind: Kind
    /// Relative to the body's resting centre, in body sides.
    var position: CGPoint
    var size: CGFloat
    var opacity: Double
}
