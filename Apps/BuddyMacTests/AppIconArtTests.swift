import AppKit
import BuddyKit
import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Not a test of behaviour: the app icon generator. The icons are Block itself (idle, Sky), its body filling the whole
/// icon, drawn by the same code as the island, so the logo and the character never drift apart.
///
/// It does nothing unless `BUDDY_WRITE_ICONS=1` is set; pass it to xcodebuild as `TEST_RUNNER_BUDDY_WRITE_ICONS=1`:
///
///     cd Apps && TEST_RUNNER_BUDDY_WRITE_ICONS=1 xcodebuild -project Buddy.xcodeproj -scheme BuddyMac \
///       -destination 'platform=macOS' test -only-testing:BuddyMacTests/AppIconArtTests
///
/// It writes the PNGs into both asset catalogs (the files are committed, so nobody needs to run it again):
/// - `BuddyPhone/.../AppIcon.appiconset/icon-1024.png`: full bleed, no alpha channel (App Store Connect rejects one).
/// - `BuddyMac/.../AppIcon.appiconset/icon-16 ... icon-1024.png`: the macOS rounded square, 824/1024 of the canvas,
///   with transparent margins; Block's body fills the square.
/// - `BuddyNotificationService/Resources/buddy-approval.png` and `buddy-question.png`: the picture on a notification.
@MainActor
@Suite struct AppIconArtTests {
    /// Block's idle body colour, behind it in case a corner shows.
    static let sky = CGColor(srgbRed: 0.36, green: 0.66, blue: 1.00, alpha: 1)
    /// How far the body overflows the icon on each side, as a fraction of the icon.
    static let bleed: CGFloat = 0.06

    /// The box of the image's (nearly) opaque pixels, in image coordinates (top-left origin): Block's body without its
    /// soft shadow.
    static func opaqueBounds(of image: CGImage) throws -> CGRect {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 250 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        #expect(maxX >= minX, "the character has no opaque pixels")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test func writeAppIcons() throws {
        guard ProcessInfo.processInfo.environment["BUDDY_WRITE_ICONS"] == "1" else { return }
        let apps = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let character = try Self.character()

        let phone = try Self.icon(size: 1024, character: character, macShape: false)
        let phoneSet = apps.appendingPathComponent("BuddyPhone/Assets.xcassets/AppIcon.appiconset")
        try Self.writePNG(phone, to: phoneSet.appendingPathComponent("icon-1024.png"))
        // iOS dark and tinted home screens: without these the system derives its own versions (and kept showing the
        // old placeholder's in notifications). Dark is Buddy as is; tinted is its grey tones, which iOS colours.
        try Self.writePNG(phone, to: phoneSet.appendingPathComponent("icon-1024-dark.png"))
        try Self.writePNG(try Self.grey(phone), to: phoneSet.appendingPathComponent("icon-1024-tinted.png"))

        // The picture on a notification: Buddy asking for approval, or asking a question (transparent, 300 px).
        for (state, name) in [(CharacterState.approval, "buddy-approval"), (.question, "buddy-question")] {
            let picture = try Self.scaled(try Self.character(state: state), to: 300)
            try Self.writePNG(picture, to: apps.appendingPathComponent("BuddyNotificationService/Resources/\(name).png"))
        }

        let master = try Self.icon(size: 1024, character: character, macShape: true)
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let image = pixels == 1024 ? master : try Self.scaled(master, to: pixels)
            try Self.writePNG(image, to: apps.appendingPathComponent("BuddyMac/Assets.xcassets/AppIcon.appiconset/icon-\(pixels).png"))
        }
    }

    /// Block (idle by default: eyes open and centred) on a transparent 1024 canvas.
    static func character(state: CharacterState = .idle) throws -> CGImage {
        let start = Date(timeIntervalSince1970: 0)
        let input = CharacterInput(
            state: state, emote: nil, emoteStartedAt: nil, stateStartedAt: start, hovering: false, boopedAt: nil,
            greetingStartedAt: nil, look: .zero, size: 1024, reduceMotion: true)
        let view = BlockFrame(input: input, now: BlockView.stillMoment(start + 0.5, stateStartedAt: start))
            .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    /// The icon at `size` pixels: Block's body filling the whole square on iOS, or the macOS rounded square.
    static func icon(size: Int, character: CGImage, macShape: Bool) throws -> CGImage {
        let s = CGFloat(size)
        let info = macShape ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        ctx.interpolationQuality = .high

        let body: CGRect
        if macShape {
            let inset = s * (1 - 824.0 / 1024.0) / 2
            body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
            let radius = body.width * 0.224
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
        } else {
            body = CGRect(x: 0, y: 0, width: s, height: s)
        }
        // Block's body fills the icon: scaled so its opaque part (measured, so a redesign of the character still fits)
        // overflows the shape a little, and its rounded corners fall outside the mask. The Sky behind it only shows
        // if a corner still peeks in.
        ctx.setFillColor(sky)
        ctx.fill(body)
        let opaque = try Self.opaqueBounds(of: character)
        let scale = body.width * (1 + 2 * Self.bleed) / opaque.width
        let art = CGRect(
            x: body.midX - (opaque.midX * scale), y: body.midY - ((CGFloat(character.height) - opaque.midY) * scale),
            width: CGFloat(character.width) * scale, height: CGFloat(character.height) * scale)
        ctx.draw(character, in: art)
        return try #require(ctx.makeImage())
    }

    /// `image` in grey tones, without alpha (the tinted iOS icon).
    static func grey(_ image: CGImage) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(ctx.makeImage())
    }

    static func scaled(_ image: CGImage, to pixels: Int) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return try #require(ctx.makeImage())
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
