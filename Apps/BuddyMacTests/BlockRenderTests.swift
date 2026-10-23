import AppKit
import BuddyKit
import Foundation
import SwiftUI
import Testing

/// Block draws something in every state and emote, at island size and pill size, and its frames depend only on
/// the input and the date. Set `BUDDY_SNAPSHOT_DIR` to also write the images as PNGs for a visual check.
@MainActor
@Suite struct BlockRenderTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    private func input(
        _ state: CharacterState, emote: CharacterEmote? = nil, size: CGFloat = 64, reduceMotion: Bool = false,
        look: CGVector = CGVector(dx: 0.3, dy: -0.2)
    ) -> CharacterInput {
        CharacterInput(
            state: state, emote: emote, emoteStartedAt: emote == nil ? nil : start, stateStartedAt: start,
            hovering: false, boopedAt: nil, greetingStartedAt: nil, look: look, size: size, reduceMotion: reduceMotion)
    }

    /// One frame `seconds` after the state (and emote) started.
    private func frame(_ input: CharacterInput, at seconds: TimeInterval, name: String) throws -> CGImage {
        try render(BlockFrame(input: input, now: start.addingTimeInterval(seconds)), name: name)
    }

    private func render<V: View>(_ view: V, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["BUDDY_SNAPSHOT_DIR"],
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("block-\(name).png"))
        }
        return image
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }

    /// Pixels visibly different from the transparent background.
    private func drawnPixels(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where alpha(rep, x, y) > 0.05 { count += 1 }
        }
        return count
    }

    /// Visible pixels on the outermost ring of the image: anything there is likely cut off by the frame.
    private func edgePixels(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var count = 0
        for x in 0..<w where alpha(rep, x, 0) > 0.05 || alpha(rep, x, h - 1) > 0.05 { count += 1 }
        for y in 0..<h where alpha(rep, 0, y) > 0.05 || alpha(rep, w - 1, y) > 0.05 { count += 1 }
        return count
    }

    /// The pixels as tightly packed RGBA, so two images can be compared whatever the renderer's row layout.
    private func rgba(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Pixels where some channel differs by more than 3 / 255. Gradients are dithered, so two renders of the same
    /// frame can differ by 1 / 255 here and there; that does not count.
    private func changedPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        let pa = rgba(a), pb = rgba(b)
        var count = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            if (0..<4).contains(where: { abs(Int(pa[i + $0]) - Int(pb[i + $0])) > 3 }) { count += 1 }
        }
        return count
    }

    private func same(_ a: CGImage, _ b: CGImage) -> Bool { changedPixels(a, b) == 0 }
    private func differ(_ a: CGImage, _ b: CGImage) -> Bool { changedPixels(a, b) > 10 }

    /// Island size draws a full body; pill size (12 pt at 2x is 24 x 24 pixels) still draws most of its area.
    private func minimumPixels(_ size: CGFloat) -> Int { size >= 24 ? 3000 : 200 }

    @Test(arguments: CharacterState.allCases)
    func everyStateDraws(state: CharacterState) throws {
        for size: CGFloat in [64, 12] {
            let image = try frame(input(state, size: size), at: 1, name: "\(state.rawValue)-\(Int(size))")
            #expect(image.width == Int(size) * 2)
            #expect(drawnPixels(image) > minimumPixels(size), "\(state) at \(size) pt")
        }
    }

    @Test(arguments: CharacterEmote.allCases)
    func everyEmoteDraws(emote: CharacterEmote) throws {
        for size: CGFloat in [64, 12] {
            let image = try frame(
                input(.idle, emote: emote, size: size), at: 0.4, name: "emote-\(emote.rawValue)-\(Int(size))")
            #expect(drawnPixels(image) > minimumPixels(size), "\(emote) at \(size) pt")
        }
    }

    @Test(arguments: CharacterEmote.allCases)
    func everyEmoteChangesTheLook(emote: CharacterEmote) throws {
        let plain = try frame(input(.idle), at: 0.4, name: "idle-plain")
        let withEmote = try frame(input(.idle, emote: emote), at: 0.4, name: "emote-\(emote.rawValue)-64")
        #expect(differ(plain, withEmote), "\(emote)")
    }

    @Test func emotesEnd() throws {
        // Long after it started the emote no longer shows: the frame is the plain state's.
        let plain = try frame(input(.error), at: 30, name: "error-late")
        let ended = try frame(input(.error, emote: .love), at: 30, name: "error-love-late")
        #expect(same(plain, ended))
    }

    @Test func statesDiffer() throws {
        let idle = try frame(input(.idle), at: 3, name: "idle-settled")
        let error = try frame(input(.error), at: 3, name: "error-settled")
        #expect(differ(idle, error))
        // Every state has its own look once its opening motion is over.
        let states = CharacterState.allCases
        let all = try states.map { try frame(input($0), at: 3, name: "\($0.rawValue)-settled") }
        for i in all.indices {
            for j in all.indices where j > i { #expect(differ(all[i], all[j]), "\(states[i]) vs \(states[j])") }
        }
    }

    @Test func reduceMotionDraws() throws {
        for state in CharacterState.allCases {
            for size: CGFloat in [64, 12] {
                let image = try frame(
                    input(state, size: size, reduceMotion: true), at: 0.5, name: "rm-\(state.rawValue)-\(Int(size))")
                #expect(drawnPixels(image) > minimumPixels(size), "\(state) at \(size) pt")
            }
        }
        for emote in CharacterEmote.allCases {
            let image = try frame(input(.idle, emote: emote, reduceMotion: true), at: 0.4, name: "rm-emote-\(emote.rawValue)")
            #expect(drawnPixels(image) > minimumPixels(64), "\(emote)")
        }
    }

    /// Spins, shakes, hops and particles move the picture between two moments; with Reduce Motion they do not.
    @Test func reduceMotionHoldsStill() throws {
        let cases: [(CharacterState, CharacterEmote?, TimeInterval)] = [
            (.finished, nil, 0.6), (.dizzy, nil, 0.6), (.error, nil, 0.15), (.sleeping, nil, 0.8),
            (.approval, nil, 0.25), (.finished, .surprised, 0.2),
        ]
        for (state, emote, moving) in cases {
            let label = "\(state.rawValue)-\(emote?.rawValue ?? "none")"
            let a = try frame(input(state, emote: emote), at: moving, name: "motion-\(label)-a")
            let b = try frame(input(state, emote: emote), at: moving + 1.3, name: "motion-\(label)-b")
            #expect(differ(a, b), "\(label) moves without Reduce Motion")
            let stillA = try frame(input(state, emote: emote, reduceMotion: true), at: moving, name: "still-\(label)-a")
            let stillB = try frame(
                input(state, emote: emote, reduceMotion: true), at: moving + 0.4, name: "still-\(label)-b")
            #expect(same(stillA, stillB), "\(label) holds still with Reduce Motion")
        }
    }

    @Test func staysInsideItsFrame() throws {
        for state in CharacterState.allCases {
            for size: CGFloat in [64, 12] {
                for seconds in [0.1, 0.25, 0.5, 0.8, 1.2, 2.0, 3.0] {
                    let image = try frame(input(state, size: size), at: seconds, name: "edge-\(state.rawValue)-\(Int(size))")
                    #expect(edgePixels(image) == 0, "\(state) at \(size) pt, \(seconds) s")
                }
            }
        }
        // Every emote on top of idle and of each state with a badge (a jump on top of a hop must not push the
        // badge out).
        for state in [CharacterState.idle, .working, .thinking, .approval, .question] {
            for emote in CharacterEmote.allCases {
                for size: CGFloat in [64, 12] {
                    for seconds in [0.1, 0.2, 0.25, 0.3, 0.5, 1.0] {
                        let image = try frame(input(state, emote: emote, size: size), at: seconds, name: "edge-emote")
                        #expect(edgePixels(image) == 0, "\(state) + \(emote) at \(size) pt, \(seconds) s")
                    }
                }
            }
        }
    }

    private let corners = [
        CGVector(dx: -1, dy: -1), CGVector(dx: 1, dy: -1), CGVector(dx: -1, dy: 1), CGVector(dx: 1, dy: 1),
    ]

    @Test func extremeLooksDrawInside() throws {
        for look in corners {
            for state in [CharacterState.idle, .question, .rateLimited] {
                for size: CGFloat in [64, 12] {
                    let image = try frame(
                        input(state, size: size, look: look), at: 0.5, name: "look-\(state.rawValue)-\(Int(size))")
                    #expect(drawnPixels(image) > minimumPixels(size), "\(state) looking \(look)")
                    #expect(edgePixels(image) == 0, "\(state) looking \(look) at \(size) pt")
                }
            }
            let listening = try frame(input(.idle, emote: .listening, look: look), at: 0.5, name: "look-listening")
            #expect(edgePixels(listening) == 0, "listening towards \(look)")
        }
    }

    @Test func looksBeyondTheRangeAreClamped() throws {
        // The pupils stop at the edge of the eye: a look past -1...1 draws the same as the corner it points to.
        for look in corners {
            let far = CGVector(dx: look.dx * 3, dy: look.dy * 3)
            for emote in [nil, CharacterEmote.listening] {
                let atCorner = try frame(input(.idle, emote: emote, look: look), at: 0.5, name: "look-corner")
                let beyond = try frame(input(.idle, emote: emote, look: far), at: 0.5, name: "look-beyond")
                #expect(same(atCorner, beyond), "\(far) with \(emote?.rawValue ?? "no emote")")
            }
        }
    }

    @Test func framesDependOnlyOnInputAndDate() throws {
        for state in [CharacterState.idle, .working, .sleeping, .finished] {
            let a = try frame(input(state), at: 1.7, name: "same-\(state.rawValue)-a")
            let b = try frame(input(state), at: 1.7, name: "same-\(state.rawValue)-b")
            #expect(same(a, b), "\(state)")
        }
    }

    @Test func idleBlinks() throws {
        // Somewhere in 10 s of idle the eyes close: at least one frame differs from the open-eyed ones.
        let open = try frame(input(.idle, reduceMotion: true), at: 0, name: "blink-open")
        let frames = try stride(from: 0.0, to: 10, by: 0.04).map {
            try frame(input(.idle, reduceMotion: true), at: $0, name: "blink")
        }
        #expect(frames.contains { differ($0, open) })
    }

    @Test func boopAndGreetingShow() throws {
        let plain = try frame(input(.idle), at: 0.2, name: "idle-0.2")
        var booped = input(.idle)
        booped.boopedAt = start.addingTimeInterval(0.1)
        #expect(try differ(frame(booped, at: 0.2, name: "booped"), plain))
        var greeting = input(.idle)
        greeting.greetingStartedAt = start
        #expect(try differ(frame(greeting, at: 0.2, name: "greeting-drop"), plain))
        // With Reduce Motion the greeting does not drop in; only the eyes look around later.
        var still = greeting
        still.reduceMotion = true
        let stillPlain = try frame(input(.idle, reduceMotion: true), at: 0.2, name: "rm-idle-0.2")
        #expect(try same(frame(still, at: 0.2, name: "rm-greeting-0.2"), stillPlain))
        let lookingAround = try frame(still, at: 1.4, name: "rm-greeting-1.4")
        #expect(try differ(lookingAround, frame(input(.idle, reduceMotion: true), at: 1.4, name: "rm-idle-1.4")))
    }

    @Test func theTimelineViewDraws() throws {
        let image = try render(Block().view(input(.working)), name: "timeline")
        #expect(drawnPixels(image) > minimumPixels(64))
        let still = try render(Block().view(input(.working, reduceMotion: true)), name: "timeline-still")
        #expect(drawnPixels(still) > minimumPixels(64))
    }

    /// 30 frames a second while awake, 10 while sleeping (slow breathing and drifting "z"s), and no running
    /// timeline at all under Reduce Motion.
    @Test func theTimelinePacesWithTheStateAndReduceMotion() {
        #expect(BlockView.pace(for: input(.working)) == .animated(minimumInterval: 1.0 / 30))
        #expect(BlockView.pace(for: input(.idle)) == .animated(minimumInterval: 1.0 / 30))
        #expect(BlockView.pace(for: input(.sleeping)) == .animated(minimumInterval: 0.1))
        for state in CharacterState.allCases {
            #expect(BlockView.pace(for: input(state, reduceMotion: true)) == .still, "\(state)")
        }
    }

    /// Paused, the picture is redrawn only when the look really changes: when the state, an emote, a boop or the
    /// greeting starts, halfway into an emote (a wink or yawn shows then) and when each ends.
    @Test func aPausedTimelineRedrawsWhenTheLookChanges() {
        var still = input(.idle, emote: .wink, reduceMotion: true)
        still.boopedAt = start.addingTimeInterval(2)
        still.greetingStartedAt = start.addingTimeInterval(5)
        let dates = BlockView.stillDates(for: still)
        let wink = BlockPose.duration(of: .wink)
        for expected in [
            start, start.addingTimeInterval(wink / 2), start.addingTimeInterval(wink),
            start.addingTimeInterval(2), start.addingTimeInterval(2.45), start.addingTimeInterval(5),
            start.addingTimeInterval(9),
        ] {
            #expect(dates.contains(expected), "\(expected.timeIntervalSince(start))")
        }
        #expect(dates == dates.sorted())
        #expect(BlockView.stillDates(for: input(.idle, reduceMotion: true)) == [start])
    }

    /// A paused picture never freezes with the lids half down: a moment inside a blink moves past it.
    @Test func aPausedPictureIsNeverMidBlink() {
        for step in stride(from: 0.0, to: 20, by: 0.01) {
            let moment = BlockView.stillMoment(start.addingTimeInterval(step), stateStartedAt: start)
            #expect(BlockPose.blink(at: moment.timeIntervalSince(start)) == 0, "\(step)")
            #expect(moment >= start.addingTimeInterval(step))
            #expect(moment.timeIntervalSince(start) - step < 0.6)
        }
    }

    /// CIELAB (D65) from sRGB components.
    private func lab(_ c: Color.Resolved) -> (Double, Double, Double) {
        func linear(_ v: Float) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.red), g = linear(c.green), b = linear(c.blue)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    @Test func accentsDistinct() throws {
        let block = Block()
        let states = CharacterState.allCases
        let resolved = states.map { block.accent(for: $0).resolve(in: EnvironmentValues()) }
        #expect(Set(resolved).count == 11)
        // Every pair at least 15 apart in CIE76 Delta E (about 2.3 is a just-noticeable difference; 15 reads as
        // clearly different colours side by side). The closest pair today is thinking / sleeping at about 18.7.
        let labs = resolved.map(lab)
        for i in labs.indices {
            for j in labs.indices where j > i {
                let (a, b) = (labs[i], labs[j])
                let deltaE = ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
                #expect(deltaE >= 15, "\(states[i]) vs \(states[j]): \(deltaE)")
            }
        }
        let error = block.accent(for: .error).resolve(in: EnvironmentValues())
        #expect(error.red > error.green + 0.4 && error.red > error.blue + 0.4, "error reads red")
    }

    @Test func blockIsRegisteredFirst() {
        let block = Block()
        #expect(block.id == "block")
        #expect(block.displayName == "Block")
        #expect(block.soundFolder == "block")
        #expect(CharacterRegistry.all.first?.id == "block")
    }
}
