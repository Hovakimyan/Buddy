#!/usr/bin/env swift
//
// Generates the PLACEHOLDER app icons for BuddyPhone and BuddyMac: a flat coloured rounded square with a white
// capital "B". Drawn from scratch with CoreGraphics and CoreText (the "B" is a glyph of a system font), no third-party
// art. It is a stand-in so that App Store Connect accepts the TestFlight upload (the 1024x1024 marketing icon is
// mandatory) and the dmg does not look bare. Replace it with real artwork whenever one exists, see
// "Replacing the app icon" in scripts/README.md.
//
// Run once (the generated files are committed, so nobody needs to run it again):
//   swift scripts/make-icons.swift
//
// Writes, relative to the repo root:
//   Apps/BuddyPhone/Assets.xcassets/AppIcon.appiconset/  icon-1024.png (single 1024 universal icon, Xcode 15+, no alpha)
//   Apps/BuddyMac/Assets.xcassets/AppIcon.appiconset/    icon-16 ... icon-1024.png (the macOS sizes, rounded square)
// plus the two Contents.json files and an Assets.xcassets/Contents.json for each catalog.
//
// iOS: a full-bleed square without any alpha channel (the system applies the rounded mask; App Store Connect rejects
// transparency). macOS: the rounded square sits inside the canvas with transparent margins (the usual macOS icon grid).

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ---- the look (change these to restyle the placeholder) -------------------------------------------------------------

let background = CGColor(srgbRed: 0.231, green: 0.357, blue: 0.859, alpha: 1)  // flat blue #3B5BDB
let letterColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let letter = "B"

// ---- drawing --------------------------------------------------------------------------------------------------------

/// Draws the icon into a square canvas of `size` pixels. `rounded` draws the macOS style (rounded square with margin and
/// transparent corners); otherwise the whole canvas is filled (iOS).
func render(size: Int, rounded: Bool) -> CGImage {
  let s = CGFloat(size)
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  // iOS: no alpha channel at all. macOS: premultiplied alpha for the transparent corners.
  let info = rounded ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
  guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
    fatalError("cannot create a \(size)px bitmap context")
  }
  ctx.setAllowsAntialiasing(true)
  ctx.setShouldAntialias(true)
  ctx.interpolationQuality = .high

  // The icon body: macOS uses 824/1024 of the canvas with a corner radius of about 22.4% of that body.
  let body: CGRect
  if rounded {
    let inset = s * (1 - 824.0 / 1024.0) / 2
    body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  } else {
    body = CGRect(x: 0, y: 0, width: s, height: s)
  }
  ctx.setFillColor(background)
  if rounded {
    let radius = body.width * 0.224
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
  } else {
    ctx.fill(body)
  }

  // The letter: a glyph outline of a bold system font, centred on the body by its bounding box (optical centre).
  let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, body.height * 0.62, nil)
  var chars = Array(letter.utf16)
  var glyphs = [CGGlyph](repeating: 0, count: chars.count)
  guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count), let glyphPath = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
    fatalError("cannot build the glyph for \(letter)")
  }
  let box = glyphPath.boundingBoxOfPath
  var move = CGAffineTransform(translationX: body.midX - box.midX, y: body.midY - box.midY)
  guard let placed = glyphPath.copy(using: &move) else { fatalError("cannot place the glyph") }
  ctx.setFillColor(letterColor)
  ctx.addPath(placed)
  ctx.fillPath()

  guard let image = ctx.makeImage() else { fatalError("cannot make the image") }
  return image
}

func writePNG(_ image: CGImage, to url: URL) {
  guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot write \(url.path)")
  }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { fatalError("cannot finalize \(url.path)") }
}

func writeJSON(_ object: Any, to url: URL) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  try! (data + Data("\n".utf8)).write(to: url)
}

// ---- output ---------------------------------------------------------------------------------------------------------

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
// Run as `swift scripts/make-icons.swift` from anywhere: the repo root is the folder above scripts/.
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let catalogInfo: [String: Any] = ["info": ["author": "xcode", "version": 1]]

func catalog(for target: String) -> URL {
  let assets = root.appendingPathComponent("Apps/\(target)/Assets.xcassets")
  let set = assets.appendingPathComponent("AppIcon.appiconset")
  try! fm.createDirectory(at: set, withIntermediateDirectories: true)
  writeJSON(catalogInfo, to: assets.appendingPathComponent("Contents.json"))
  return set
}

// iOS: one 1024 universal icon (Xcode 15+ single-size app icon), full bleed, no alpha.
do {
  let set = catalog(for: "BuddyPhone")
  writePNG(render(size: 1024, rounded: false), to: set.appendingPathComponent("icon-1024.png"))
  writeJSON(
    [
      "images": [["filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
      "info": ["author": "xcode", "version": 1],
    ], to: set.appendingPathComponent("Contents.json"))
  print("wrote \(set.path)")
}

// macOS: the usual sizes, 16 to 512 points at 1x and 2x.
do {
  let set = catalog(for: "BuddyMac")
  var images: [[String: String]] = []
  var pixelSizes = Set<Int>()
  for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
      let pixels = points * scale
      pixelSizes.insert(pixels)
      images.append(["filename": "icon-\(pixels).png", "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
  }
  for pixels in pixelSizes.sorted() {
    writePNG(render(size: pixels, rounded: true), to: set.appendingPathComponent("icon-\(pixels).png"))
  }
  writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: set.appendingPathComponent("Contents.json"))
  print("wrote \(set.path)")
}
