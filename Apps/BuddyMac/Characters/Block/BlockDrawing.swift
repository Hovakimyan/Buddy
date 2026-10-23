import SwiftUI

/// Draws a `BlockPose` into a Canvas: the body, eyes, blush, sweat drop and badge move with the body; particles
/// stay put around where the body rests. Body-local lengths are multiples of `side`, the body's side length.
enum BlockDrawing {
    static let eyeWhite = BlockRGB(0.97, 0.98, 1.00)
    static let ink = BlockRGB(0.10, 0.11, 0.16)
    static let blushPink = BlockRGB(1.00, 0.45, 0.60)
    static let heartRed = BlockRGB(0.96, 0.20, 0.38)
    static let starGold = BlockRGB(1.00, 0.86, 0.28)
    static let dropBlue = BlockRGB(0.55, 0.82, 1.00)
    static let sparkleCream = BlockRGB(1.00, 0.97, 0.78)

    /// At island size the body is this fraction of the frame and rests this far down it, leaving room above for
    /// hops, badges and particles; in the pill it fills more and sits in the middle.
    static let bodyFraction: CGFloat = 0.66
    static let restFraction: CGFloat = 0.56
    static let pillBodyFraction: CGFloat = 0.76

    /// The badge bubble, body-local.
    static let badgeCenter = CGPoint(x: 0.42, y: -0.43)
    static let badgeRadius: CGFloat = 0.16

    /// The highest the badge's top may go, in body sides from the resting centre: the frame's top plus room for
    /// antialiasing.
    static let highestBadgeTop = -(restFraction - 0.03) / bodyFraction

    /// The badge's top in body sides from the resting centre, for a body with `stretch` and `rotation` and no
    /// offset (the same transform as `draw`).
    static func badgeTop(stretch: CGSize, rotation: Angle) -> CGFloat {
        let x = badgeCenter.x * stretch.width
        let y = 0.5 + (badgeCenter.y - 0.5) * stretch.height
        let turned = x * sin(rotation.radians) + y * cos(rotation.radians)
        return turned - badgeRadius * max(stretch.width, stretch.height)
    }

    static func draw(_ pose: BlockPose, in context: GraphicsContext, size: CGSize) {
        let canvas = min(size.width, size.height)
        let side = canvas * (pose.detailed ? bodyFraction : pillBodyFraction)
        let rest = CGPoint(x: size.width / 2, y: size.height * (pose.detailed ? restFraction : 0.5))

        var body = context
        body.translateBy(x: rest.x + pose.offset.dx * side, y: rest.y + pose.offset.dy * side)
        body.rotate(by: pose.rotation)
        body.translateBy(x: 0, y: side / 2)
        body.scaleBy(x: pose.stretch.width, y: pose.stretch.height)
        body.translateBy(x: 0, y: -side / 2)

        drawBody(pose, in: body, side: side)
        let lidColor = pose.body.mixed(with: .black, 0.45)
        for (eye, x) in [(pose.left, -0.2), (pose.right, 0.2)] {
            drawEye(
                eye, at: CGPoint(x: x * side, y: 0.03 * side), gaze: pose.gaze, lid: lidColor, detailed: pose.detailed,
                in: body, side: side)
        }
        if pose.blush > 0 { drawBlush(pose.blush, in: body, side: side) }
        if let sweat = pose.sweat { drawSweat(sweat, in: body, side: side) }
        if let badge = pose.badge { drawBadge(badge, glyph: lidColor, in: body, side: side) }

        var around = context
        around.translateBy(x: rest.x, y: rest.y)
        for particle in pose.particles { drawParticle(particle, in: around, side: side) }
    }

    // MARK: Body

    private static func drawBody(_ pose: BlockPose, in context: GraphicsContext, side: CGFloat) {
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        let shape = Path(roundedRect: rect, cornerRadius: side * 0.28, style: .continuous)
        let gradient = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                pose.body.mixed(with: .white, 0.3).color, pose.body.color, pose.body.mixed(with: .black, 0.22).color,
            ]),
            startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY))
        if pose.detailed {
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: side * 0.05, x: 0, y: side * 0.035))
                layer.fill(shape, with: gradient)
            }
        } else {
            context.fill(shape, with: gradient)
        }

        // Gloss: a reflection band hugging the top-left corner, and a specular dot near it.
        var gloss = context
        gloss.clip(to: shape)
        var band = Path()
        band.move(to: point(-0.40, 0.0, side))
        band.addQuadCurve(to: point(0.0, -0.40, side), control: point(-0.42, -0.42, side))
        band.addQuadCurve(to: point(-0.40, 0.0, side), control: point(-0.27, -0.27, side))
        gloss.fill(
            band,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.65), .white.opacity(0.08)]), startPoint: point(-0.35, -0.35, side),
                endPoint: point(0.0, 0.0, side)))
        gloss.fill(circle(point(-0.13, -0.24, side), side * 0.035), with: .color(.white.opacity(0.9)))
    }

    // MARK: Eyes

    private static func drawEye(
        _ eye: BlockEye, at center: CGPoint, gaze: CGVector, lid: BlockRGB, detailed: Bool, in context: GraphicsContext,
        side: CGFloat
    ) {
        let w = 0.2 * side * eye.scale
        let h = 0.27 * side * eye.scale
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let line = max(0.055 * side, 0.9)
        switch eye.shape {
        case .round:
            if eye.openness < 0.12 {
                drawClosed(rect, line: line, in: context, side: side)
                return
            }
            let white = Path(roundedRect: rect, cornerRadius: w * 0.48, style: .continuous)
            let lidY = rect.minY + (1 - eye.openness) * h
            let leftY = lidY - eye.lidTilt * h * 0.25
            let rightY = lidY + eye.lidTilt * h * 0.25
            var open = Path()
            open.addLines([
                CGPoint(x: rect.minX, y: leftY), CGPoint(x: rect.maxX, y: rightY),
                CGPoint(x: rect.maxX, y: rect.maxY + 1), CGPoint(x: rect.minX, y: rect.maxY + 1),
            ])
            open.closeSubpath()
            var inside = context
            inside.clip(to: white)
            var visible = inside
            visible.clip(to: open)
            visible.fill(white, with: .color(eyeWhite.color))

            let r = 0.075 * side * eye.scale * eye.pupil
            let pupil = CGPoint(
                x: center.x + gaze.dx * (w / 2 - r) * 0.8, y: center.y + gaze.dy * (h / 2 - r) * 0.75)
            visible.fill(circle(pupil, r), with: .color(ink.color))
            if detailed {
                visible.fill(circle(CGPoint(x: pupil.x - 0.35 * r, y: pupil.y - 0.38 * r), 0.32 * r), with: .color(.white))
            }
            if eye.openness < 0.99 || eye.lidTilt != 0 {
                var lidLine = Path()
                lidLine.move(to: CGPoint(x: rect.minX, y: leftY))
                lidLine.addLine(to: CGPoint(x: rect.maxX, y: rightY))
                inside.stroke(lidLine, with: .color(lid.color), lineWidth: line * 0.8)
            }
        case .flat:
            let dash = CGRect(x: center.x - w * 0.55, y: center.y - line * 0.6, width: w * 1.1, height: line * 1.2)
            context.fill(Path(roundedRect: dash, cornerRadius: line * 0.6), with: .color(ink.color))
        case .arc:
            var arc = Path()
            arc.move(to: CGPoint(x: rect.minX, y: center.y + 0.03 * side))
            arc.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: center.y + 0.03 * side),
                control: CGPoint(x: center.x, y: center.y - 0.16 * side * eye.scale))
            context.stroke(arc, with: .color(ink.color), style: StrokeStyle(lineWidth: line, lineCap: .round))
        case .closed:
            drawClosed(rect, line: line, in: context, side: side)
        case .spiral(let angle):
            let radius = 0.12 * side * eye.scale
            context.fill(circle(center, radius), with: .color(eyeWhite.color))
            context.stroke(
                spiral(center, radius: radius * 0.85, angle: angle), with: .color(ink.color),
                style: StrokeStyle(lineWidth: line * 0.6, lineCap: .round))
        case .heart:
            let s = 0.26 * side * eye.scale
            // A slightly bigger white heart behind gives the red one a rim on any body colour.
            let rim = CGRect(x: center.x - s * 0.58, y: center.y - s * 0.55, width: s * 1.16, height: s * 1.12)
            context.fill(heart(rim), with: .color(.white))
            let fill = CGRect(x: center.x - s / 2, y: center.y - s * 0.45, width: s, height: s * 0.95)
            context.fill(heart(fill), with: .color(heartRed.color))
        case .star:
            let shape = star(center, radius: 0.15 * side * eye.scale)
            context.fill(shape, with: .color(starGold.color))
            context.stroke(shape, with: .color(ink.color), style: StrokeStyle(lineWidth: line * 0.35, lineJoin: .round))
        }
    }

    /// A shut eye: a shallow downward curve.
    private static func drawClosed(_ rect: CGRect, line: CGFloat, in context: GraphicsContext, side: CGFloat) {
        var curve = Path()
        curve.move(to: CGPoint(x: rect.minX, y: rect.midY + 0.02 * side))
        curve.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY + 0.02 * side), control: CGPoint(x: rect.midX, y: rect.midY + 0.12 * side))
        context.stroke(curve, with: .color(ink.color), style: StrokeStyle(lineWidth: line, lineCap: .round))
    }

    private static func drawBlush(_ amount: Double, in context: GraphicsContext, side: CGFloat) {
        for x in [-0.32, 0.32] {
            let rect = CGRect(
                x: (x - 0.07) * side, y: (0.24 - 0.0375) * side, width: 0.14 * side, height: 0.075 * side)
            context.fill(Path(ellipseIn: rect), with: .color(blushPink.color.opacity(0.6 * amount)))
        }
    }

    // MARK: Sweat drop and badges

    /// A drop on the upper right of the body, `progress` of the way down; it fades as it ends.
    private static func drawSweat(_ progress: Double, in context: GraphicsContext, side: CGFloat) {
        let w = 0.11 * side
        let h = 0.16 * side
        let c = point(0.42, -0.28 + 0.26 * progress, side)
        let round = CGPoint(x: c.x, y: c.y + h / 2 - w / 2)
        let tip = CGPoint(x: c.x, y: c.y - h / 2)
        var drop = Path()
        drop.move(to: tip)
        drop.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: round.y), control: CGPoint(x: c.x + w / 2, y: c.y - h * 0.05))
        drop.addArc(center: round, radius: w / 2, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
        drop.addQuadCurve(to: tip, control: CGPoint(x: c.x - w / 2, y: c.y - h * 0.05))
        let opacity = 1 - pow(progress, 4)
        context.fill(drop, with: .color(dropBlue.color.opacity(opacity)))
        context.stroke(drop, with: .color(ink.color.opacity(0.3 * opacity)), lineWidth: max(0.012 * side, 0.5))
        let shine = CGPoint(x: c.x - w * 0.15, y: round.y - w * 0.1)
        context.fill(circle(shine, w * 0.14), with: .color(.white.opacity(0.85 * opacity)))
    }

    /// A white bubble at the top right of the body with dots, "!", "?" or "z".
    private static func drawBadge(_ badge: BlockBadge, glyph: BlockRGB, in context: GraphicsContext, side: CGFloat) {
        let center = point(badgeCenter.x, badgeCenter.y, side)
        let bubble = circle(center, badgeRadius * side)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.3), radius: side * 0.03, x: 0, y: side * 0.015))
            layer.fill(bubble, with: .color(.white.opacity(0.96)))
        }
        switch badge {
        case .dots(let phase):
            for i in 0..<3 {
                let lift = phase.map { BlockPose.bump(($0 - Double(i) * 0.15).truncatingRemainder(dividingBy: 0.9), 0.45) } ?? 0
                let dot = CGPoint(x: center.x + Double(i - 1) * 0.075 * side, y: center.y - lift * 0.03 * side)
                let opacity = phase == nil ? 1 : 0.45 + 0.55 * lift
                context.fill(circle(dot, 0.027 * side), with: .color(ink.color.opacity(opacity)))
            }
        case .exclamation:
            drawGlyph("!", at: center, color: glyph, in: context, side: side)
        case .question:
            drawGlyph("?", at: center, color: glyph, in: context, side: side)
        case .sleep:
            drawGlyph("z", at: center, color: glyph, in: context, side: side)
        }
    }

    private static func drawGlyph(
        _ text: String, at center: CGPoint, color: BlockRGB, in context: GraphicsContext, side: CGFloat
    ) {
        let glyph = Text(text).font(.system(size: 0.25 * side, weight: .black, design: .rounded)).foregroundColor(color.color)
        context.draw(glyph, at: center)
    }

    // MARK: Particles

    private static func drawParticle(_ particle: BlockParticle, in context: GraphicsContext, side: CGFloat) {
        let c = point(particle.position.x, particle.position.y, side)
        let s = particle.size * side
        switch particle.kind {
        case .sparkle:
            context.fill(sparkle(c, radius: s / 2), with: .color(sparkleCream.color.opacity(particle.opacity)))
        case .heart:
            let rect = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s * 0.95)
            context.fill(heart(rect), with: .color(heartRed.mixed(with: .white, 0.2).color.opacity(particle.opacity)))
        case .sleepZ:
            let z = Text("z").font(.system(size: s, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.9 * particle.opacity))
            context.draw(z, at: c)
        }
    }

    // MARK: Shapes

    private static func point(_ x: Double, _ y: Double, _ side: CGFloat) -> CGPoint { CGPoint(x: x * side, y: y * side) }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Two lobes and a point, filling `rect`.
    private static func heart(_ rect: CGRect) -> Path {
        let lobe = rect.width / 4
        var path = Path()
        path.addPath(circle(CGPoint(x: rect.midX - lobe, y: rect.minY + lobe), lobe * 1.05))
        path.addPath(circle(CGPoint(x: rect.midX + lobe, y: rect.minY + lobe), lobe * 1.05))
        path.addLines([
            CGPoint(x: rect.minX + rect.width * 0.015, y: rect.minY + lobe * 1.35),
            CGPoint(x: rect.maxX - rect.width * 0.015, y: rect.minY + lobe * 1.35),
            CGPoint(x: rect.midX, y: rect.maxY),
        ])
        path.closeSubpath()
        return path
    }

    private static func star(_ center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let points = (0..<10).map { i -> CGPoint in
            let r = i.isMultiple(of: 2) ? radius : radius * 0.45
            let a = -Double.pi / 2 + Double(i) * .pi / 5
            return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        }
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// A four-pointed twinkle with curved sides.
    private static func sparkle(_ center: CGPoint, radius: CGFloat) -> Path {
        let tips = [
            CGPoint(x: center.x, y: center.y - radius), CGPoint(x: center.x + radius, y: center.y),
            CGPoint(x: center.x, y: center.y + radius), CGPoint(x: center.x - radius, y: center.y),
        ]
        var path = Path()
        path.move(to: tips[0])
        for i in 1...4 { path.addQuadCurve(to: tips[i % 4], control: center) }
        path.closeSubpath()
        return path
    }

    /// About two and a quarter turns outward from `center`, turned by `angle`.
    private static func spiral(_ center: CGPoint, radius: CGFloat, angle: Angle) -> Path {
        let turns = 2.25
        let steps = 48
        var path = Path()
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let a = angle.radians + f * turns * 2 * .pi
            let p = CGPoint(x: center.x + radius * f * cos(a), y: center.y + radius * f * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
