import AppKit
import SwiftUI

/// What the menu-bar item is telling the user. Menu-bar extras are drawn as
/// monochrome template images that the system tints, so every state has to
/// read by *shape* alone — no colour, no digits.
enum StatusGlyphState: Equatable {
    static let fillSteps = 26

    /// Outline shield.
    case ready
    /// Shield filling from the bottom as the session runs (0...1).
    case focusing(progress: Double)
    /// Outline shield with pause bars.
    case paused
    /// Outline shield with "!".
    case drifted
    /// Filled shield with a knocked-out check.
    case complete
    /// Cup.
    case onBreak

    var accessibilityLabel: String {
        switch self {
        case .ready:                  return "FocusGuard, ready"
        case .focusing(let progress): return "FocusGuard, focusing, \(Int((progress * 100).rounded())) percent through session"
        case .paused:                 return "FocusGuard, session paused"
        case .drifted:                return "FocusGuard, drifted off task"
        case .complete:               return "FocusGuard, session complete"
        case .onBreak:                return "FocusGuard, on a break"
        }
    }

    /// Fill steps are quantised to one Retina pixel of the shield's height
    /// (26 steps), so the status item redraws only when the shield visibly
    /// rises — every minute or two in a typical session — not every second.
    static func focusing(elapsed: TimeInterval, planned: TimeInterval?) -> StatusGlyphState {
        guard let planned, planned > 0 else { return .focusing(progress: 0.5) }
        let raw = min(1, max(0, elapsed / planned))
        return .focusing(progress: (raw * Double(fillSteps)).rounded(.down) / Double(fillSteps))
    }
}

/// Geometry for the glyphs, on a 16×16 y-down grid. Rendered twice: as an
/// AppKit template image for the status item, and as a tinted SwiftUI view in
/// the menu header — so both always match.
/// One frame's tweaks to a glyph, for the status item's short animations.
struct GlyphStyle: Equatable {
    /// Overrides the focusing fill (0...1), e.g. while sweeping on start.
    var fill: Double?
    /// Horizontal nudge in points, for the drift shake.
    var dx: CGFloat = 0
    /// How much of the completion check is drawn (0...1).
    var checkProgress: Double = 1
    /// Opacity of the break cup's steam (0...1).
    var steamOpacity: Double = 1

    static let still = GlyphStyle()
}

enum StatusGlyph {
    enum Op {
        case stroke(CGPath, width: CGFloat, alpha: CGFloat = 1)
        case fill(CGPath)
        /// Fill `rect`, clipped to `clip`.
        case fillClipped(CGRect, clip: CGPath)
        /// Punch the stroke out of whatever is underneath.
        case knockout(CGPath, width: CGFloat)
    }

    static func ops(for state: StatusGlyphState, style: GlyphStyle = .still) -> [Op] {
        let shield = shieldPath()
        switch state {
        case .ready:
            return [.stroke(shield, width: 1.4)]
        case .focusing(let progress):
            let top: CGFloat = 1.6, bottom: CGFloat = 14.4
            let level = style.fill ?? progress
            let y = bottom - (bottom - top) * CGFloat(min(1, max(0, level)))
            return [
                .fillClipped(CGRect(x: 0, y: y, width: 16, height: 16 - y), clip: shield),
                .stroke(shield, width: 1.4),
            ]
        case .paused:
            let bars = CGMutablePath()
            bars.move(to: CGPoint(x: 6.6, y: 5.6)); bars.addLine(to: CGPoint(x: 6.6, y: 9.8))
            bars.move(to: CGPoint(x: 9.4, y: 5.6)); bars.addLine(to: CGPoint(x: 9.4, y: 9.8))
            return [.stroke(shield, width: 1.4), .stroke(bars, width: 1.5)]
        case .drifted:
            let bang = CGMutablePath()
            bang.move(to: CGPoint(x: 8, y: 4.8)); bang.addLine(to: CGPoint(x: 8, y: 8.6))
            let dot = CGPath(ellipseIn: CGRect(x: 7.05, y: 10.05, width: 1.9, height: 1.9), transform: nil)
            return [.stroke(shield, width: 1.4), .stroke(bang, width: 1.6), .fill(dot)]
        case .complete:
            let check = partialPolyline([CGPoint(x: 5.4, y: 8.1), CGPoint(x: 7.2, y: 9.9), CGPoint(x: 10.6, y: 6.3)],
                                        fraction: style.checkProgress)
            return [.fill(shield), .stroke(shield, width: 1.4), .knockout(check, width: 1.5)]
        case .onBreak:
            return [.stroke(cupPath(), width: 1.4),
                    .stroke(steamPath(), width: 1.4, alpha: CGFloat(min(1, max(0, style.steamOpacity))))]
        }
    }

    // MARK: - Paths

    static func shieldPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 8, y: 1.6))
        p.addLine(to: CGPoint(x: 13.1, y: 3.7))
        p.addLine(to: CGPoint(x: 13.1, y: 7.4))
        p.addCurve(to: CGPoint(x: 8, y: 14.4),
                   control1: CGPoint(x: 13.1, y: 10.5), control2: CGPoint(x: 11, y: 13.2))
        p.addCurve(to: CGPoint(x: 2.9, y: 7.4),
                   control1: CGPoint(x: 5, y: 13.2), control2: CGPoint(x: 2.9, y: 10.5))
        p.addLine(to: CGPoint(x: 2.9, y: 3.7))
        p.closeSubpath()
        return p
    }

    private static func cupPath() -> CGPath {
        let p = CGMutablePath()
        // Body.
        p.move(to: CGPoint(x: 2.5, y: 6))
        p.addLine(to: CGPoint(x: 11, y: 6))
        p.addLine(to: CGPoint(x: 11, y: 9.5))
        p.addArc(center: CGPoint(x: 7.5, y: 9.5), radius: 3.5, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 6, y: 13))
        p.addArc(center: CGPoint(x: 6, y: 9.5), radius: 3.5, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.closeSubpath()
        // Handle.
        p.move(to: CGPoint(x: 11, y: 7))
        p.addLine(to: CGPoint(x: 12, y: 7))
        p.addArc(center: CGPoint(x: 12, y: 8.8), radius: 1.8, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 10.8, y: 10.6))
        return p
    }

    private static func steamPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 5.5, y: 2)); p.addLine(to: CGPoint(x: 5.5, y: 3.8))
        p.move(to: CGPoint(x: 8, y: 2)); p.addLine(to: CGPoint(x: 8, y: 3.8))
        return p
    }

    /// The first `fraction` of a polyline, by length — the check drawing itself.
    static func partialPolyline(_ points: [CGPoint], fraction: Double) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) * CGFloat(min(1, max(0, fraction)))
        path.move(to: first)
        for (i, length) in lengths.enumerated() where remaining > 0 {
            let a = points[i], b = points[i + 1]
            let t = min(1, remaining / length)
            path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            remaining -= length
        }
        return path
    }

    // MARK: - AppKit

    /// 18×18pt template image (16pt glyph + 1pt inset) for the status item.
    static func templateImage(for state: StatusGlyphState, style: GlyphStyle = .still) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 1 + style.dx, y: 1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            for op in ops(for: state, style: style) {
                switch op {
                case .stroke(let path, let width, let alpha):
                    ctx.saveGState()
                    ctx.setAlpha(alpha)
                    ctx.setLineWidth(width)
                    ctx.addPath(path)
                    ctx.strokePath()
                    ctx.restoreGState()
                case .fill(let path):
                    ctx.addPath(path)
                    ctx.fillPath()
                case .fillClipped(let rect, let clip):
                    ctx.saveGState()
                    ctx.addPath(clip)
                    ctx.clip()
                    ctx.fill(rect)
                    ctx.restoreGState()
                case .knockout(let path, let width):
                    ctx.saveGState()
                    ctx.setBlendMode(.clear)
                    ctx.setLineWidth(width)
                    ctx.addPath(path)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }
}

// MARK: - SwiftUI

/// The same glyph, tinted, for the menu header.
struct StatusGlyphView: View {
    let state: StatusGlyphState
    var tint: Color
    var size: CGFloat = 22

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 16
            context.scaleBy(x: scale, y: scale)
            let style: (CGFloat) -> StrokeStyle = { StrokeStyle(lineWidth: $0 * 0.93, lineCap: .round, lineJoin: .round) }
            context.drawLayer { layer in
                for op in StatusGlyph.ops(for: state) {
                    switch op {
                    case .stroke(let path, let width, let alpha):
                        layer.stroke(Path(path), with: .color(tint.opacity(alpha)), style: style(width))
                    case .fill(let path):
                        layer.fill(Path(path), with: .color(tint))
                    case .fillClipped(let rect, let clip):
                        layer.drawLayer { inner in
                            inner.clip(to: Path(clip))
                            inner.fill(Path(rect), with: .color(tint))
                        }
                    case .knockout(let path, let width):
                        layer.blendMode = .destinationOut
                        layer.stroke(Path(path), with: .color(.black), style: style(width))
                        layer.blendMode = .normal
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Animation

/// Short, one-off animations when the status item changes state. Nothing
/// loops: a focus app's menu-bar icon shouldn't keep pulling the eye.
enum GlyphAnimation {
    static let framesPerSecond: Double = 30

    /// Frames to play on the way to `new`, or none for an instant change.
    static func frames(from old: StatusGlyphState?, to new: StatusGlyphState) -> [GlyphStyle] {
        guard let old, old != new else { return [] }
        switch new {
        case .focusing(let p):
            switch old {
            case .focusing(let q):
                // The shield rises a step: glide instead of jumping.
                return ramp(9) { GlyphStyle(fill: q + (p - q) * $0) }
            case .ready, .complete, .onBreak:
                // Session start: sweep up full, then settle at the real level.
                return ramp(14) { GlyphStyle(fill: $0) } + ramp(10) { GlyphStyle(fill: 1 + (p - 1) * $0) }
            case .paused, .drifted:
                return ramp(9) { GlyphStyle(fill: p * $0) }
            }
        case .drifted:
            // One small shake.
            return [0, -1.5, 1.5, -1.2, 1.2, -0.7, 0.7, 0].map { GlyphStyle(dx: $0) }
        case .complete:
            return ramp(12) { GlyphStyle(checkProgress: $0) }
        case .onBreak:
            return ramp(15) { GlyphStyle(steamOpacity: $0) }
        case .ready, .paused:
            return []
        }
    }

    /// Once a minute while focusing, the fill swells a little and settles —
    /// a visible "time is passing" beat without anything looping. When the
    /// fill also steps up that minute, the pulse lands on the new level.
    static func pulse(from old: StatusGlyphState?, to new: StatusGlyphState) -> [GlyphStyle] {
        guard case .focusing(let p) = new else { return [] }
        var q = p
        if case .focusing(let previous)? = old { q = previous }
        let peak = min(1, max(p, q) + 0.12)
        return ramp(7) { GlyphStyle(fill: q + (peak - q) * $0) } + ramp(9) { GlyphStyle(fill: peak + (p - peak) * $0) }
    }

    /// A new running minute of the same focusing session.
    static func shouldPulse(previousMinute: Int?, minute: Int?, state: StatusGlyphState) -> Bool {
        guard case .focusing = state, let previousMinute, let minute else { return false }
        return minute > previousMinute
    }

    /// `count` frames with eased progress from just above 0 to exactly 1.
    private static func ramp(_ count: Int, _ make: (Double) -> GlyphStyle) -> [GlyphStyle] {
        (1...count).map { make(easeInOut(Double($0) / Double(count))) }
    }

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
