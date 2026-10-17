import AppKit
import SwiftUI

/// What the menu-bar item is telling the user. Menu-bar extras are drawn as
/// monochrome template images that the system tints, so every state has to
/// read by *shape* alone — no colour, no digits.
enum StatusGlyphState: Equatable {
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

    /// Fill steps are quantised so the status item only redraws when the
    /// shield visibly changes, not on every 1 Hz tick.
    static func focusing(elapsed: TimeInterval, planned: TimeInterval?) -> StatusGlyphState {
        guard let planned, planned > 0 else { return .focusing(progress: 0.5) }
        let raw = min(1, max(0, elapsed / planned))
        return .focusing(progress: (raw * 16).rounded(.down) / 16)
    }
}

/// Geometry for the glyphs, on a 16×16 y-down grid. Rendered twice: as an
/// AppKit template image for the status item, and as a tinted SwiftUI view in
/// the menu header — so both always match.
enum StatusGlyph {
    enum Op {
        case stroke(CGPath, width: CGFloat)
        case fill(CGPath)
        /// Fill `rect`, clipped to `clip`.
        case fillClipped(CGRect, clip: CGPath)
        /// Punch the stroke out of whatever is underneath.
        case knockout(CGPath, width: CGFloat)
    }

    static func ops(for state: StatusGlyphState) -> [Op] {
        let shield = shieldPath()
        switch state {
        case .ready:
            return [.stroke(shield, width: 1.4)]
        case .focusing(let progress):
            let top: CGFloat = 1.6, bottom: CGFloat = 14.4
            let y = bottom - (bottom - top) * CGFloat(min(1, max(0, progress)))
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
            let check = CGMutablePath()
            check.move(to: CGPoint(x: 5.4, y: 8.1))
            check.addLine(to: CGPoint(x: 7.2, y: 9.9))
            check.addLine(to: CGPoint(x: 10.6, y: 6.3))
            return [.fill(shield), .stroke(shield, width: 1.4), .knockout(check, width: 1.5)]
        case .onBreak:
            return [.stroke(cupPath(), width: 1.4)]
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
        // Steam.
        p.move(to: CGPoint(x: 5.5, y: 2)); p.addLine(to: CGPoint(x: 5.5, y: 3.8))
        p.move(to: CGPoint(x: 8, y: 2)); p.addLine(to: CGPoint(x: 8, y: 3.8))
        return p
    }

    // MARK: - AppKit

    /// 18×18pt template image (16pt glyph + 1pt inset) for the status item.
    static func templateImage(for state: StatusGlyphState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 1, y: 1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            for op in ops(for: state) {
                switch op {
                case .stroke(let path, let width):
                    ctx.setLineWidth(width)
                    ctx.addPath(path)
                    ctx.strokePath()
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
                    case .stroke(let path, let width):
                        layer.stroke(Path(path), with: .color(tint), style: style(width))
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
