import AppKit
import SwiftUI

// Pieces shared by the full-screen moments: the block screen, the daily
// limit screen and the break screen. They follow the system's light or dark
// appearance.

/// Colours the moments use on top of their blurred backdrop.
enum MomentPalette {
    /// Laid over the blur, so the words read the same whatever was on screen.
    static let veil = dynamic(
        light: Color(red: 244/255, green: 244/255, blue: 248/255).opacity(0.76),
        dark:  Color(red: 14/255, green: 14/255, blue: 22/255).opacity(0.64)
    )
    static let tertiaryText = dynamic(
        light: Color(red: 110/255, green: 110/255, blue: 120/255),   // #6E6E78
        dark:  Color.white.opacity(0.55)
    )
    /// The dark label next to the orange dot in the place pill.
    static let pillLabel = dynamic(
        light: Color(red: 58/255, green: 58/255, blue: 66/255),      // #3A3A42
        dark:  Color.white.opacity(0.85)
    )
    static let pillFill = dynamic(
        light: Color(red: 255/255, green: 141/255, blue: 40/255).opacity(0.13),
        dark:  Color(red: 220/255, green: 118/255, blue: 32/255).opacity(0.2)
    )
    static let pillStroke = dynamic(
        light: Color(red: 224/255, green: 115/255, blue: 22/255).opacity(0.4),
        dark:  Color(red: 255/255, green: 146/255, blue: 48/255).opacity(0.5)
    )
    static let ringTrack = dynamic(light: .black.opacity(0.07), dark: .white.opacity(0.10))
    /// Secondary capsules and the inline confirm.
    static let quietFill = dynamic(light: .black.opacity(0.06), dark: .white.opacity(0.10))
    static let quietStroke = dynamic(light: .black.opacity(0.10), dark: .white.opacity(0.18))
    static let keyCap = dynamic(light: .black.opacity(0.07), dark: .white.opacity(0.12))

    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

/// A borderless full-screen window that still takes keys, so esc and return
/// reach the buttons.
final class MomentWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Words and numbers the moments share.
enum MomentText {
    /// "1 minute", "3 minutes".
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }

    /// "18:24", or "1:05:09" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "19:40" in the user's own time format.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Seconds left before a button with this wait opens, counted from when
    /// the screen came up. Every screen of a multi-display Mac counts from
    /// the same moment, so they open together.
    static func secondsLeft(wait: Int, shownAt: Date, now: Date) -> Int {
        max(0, wait - Int(max(0, now.timeIntervalSince(shownAt))))
    }

    /// The preset an override policy belongs to.
    static func preset(for policy: OverridePolicy) -> DriftResponse {
        DriftResponse.allCases.first { $0.overridePolicy == policy } ?? .standard
    }
}

// MARK: - Buttons

/// The moments' 44 pt capsules: one primary (indigo, white text), quiet
/// grey ones, ghosts with no fill for buttons that are still waiting, and
/// links for a way out that asks first.
struct MomentButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, ghost, link, destructive }
    var kind: Kind
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        MomentButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct MomentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: MomentButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: height >= 40 ? 15 : 13, weight: kind == .primary || kind == .destructive ? .semibold : .regular))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, kind == .ghost || kind == .link ? 18 : 22)
            .frame(height: height)
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(Theme.focusFill)
                        .shadow(color: Theme.focusFill.opacity(0.3), radius: 11, y: 8)
                case .quiet:
                    Capsule().fill(MomentPalette.quietFill)
                        .overlay(Capsule().strokeBorder(MomentPalette.quietStroke, lineWidth: 0.5))
                case .destructive:
                    Capsule().fill(Theme.destructiveTint)
                case .ghost, .link:
                    Color.clear
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }

    private var ink: Color {
        switch kind {
        case .primary:     return .white
        case .destructive: return Theme.destructive
        case .quiet:       return isEnabled ? Theme.primaryText : Theme.secondaryText
        case .ghost:       return isEnabled ? Theme.primaryText : MomentPalette.tertiaryText
        case .link:        return Theme.link
        }
    }
}

/// A button that opens after `wait` seconds, with a small ring counting the
/// seconds down. Until then it's dimmed and does nothing.
struct MomentWaitingButton: View {
    let title: String
    let secondsLeft: Int
    let wait: Int
    /// How it looks while it waits, and once it's open.
    var waiting: MomentButtonStyle.Kind = .ghost
    var open: MomentButtonStyle.Kind = .quiet
    let action: () -> Void

    var body: some View {
        Button {
            if secondsLeft == 0 { action() }
        } label: {
            HStack(spacing: 8) {
                if secondsLeft > 0 { MomentCountdownRing(left: secondsLeft, total: wait) }
                Text(title)
            }
        }
        .buttonStyle(MomentButtonStyle(kind: secondsLeft > 0 ? waiting : open))
        .disabled(secondsLeft > 0)
        .accessibilityLabel(secondsLeft == 0 ? title : "\(title), available in \(MomentText.counted(secondsLeft, "second"))")
    }
}

/// The ring on a button that isn't open yet, with the seconds left.
struct MomentCountdownRing: View {
    let left: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(MomentPalette.ringTrack, lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(left) / CGFloat(max(1, total)))
                .stroke(MomentPalette.tertiaryText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(left)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// "esc  back to Xcode" under the buttons.
struct MomentKeyHint: View {
    let key: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .foregroundStyle(MomentPalette.pillLabel)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(MomentPalette.keyCap))
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(MomentPalette.tertiaryText)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Place pill

/// What you drifted to, or what ran out: its icon, its name, and an orange
/// dot with a dark label ("Drifted 1:42"). Orange never carries the text.
struct MomentPlacePill: View {
    let request: BlockRequest
    let status: String

    private var place: String { request.host ?? request.appName }

    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(kind: request.host == nil ? AppGlyph.kind(forBundleId: request.bundleId, name: request.appName) : .generic,
                     bundleId: request.host == nil ? request.bundleId : nil, host: request.host, size: 24)
            Text(place)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            HStack(spacing: 6) {
                Circle().fill(Theme.distraction).frame(width: 8, height: 8)
                Text(status)
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(MomentPalette.pillLabel)
            }
        }
        .lineLimit(1)
        .padding(.leading, 5)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(Capsule().fill(MomentPalette.pillFill))
        .overlay(Capsule().strokeBorder(MomentPalette.pillStroke, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place), \(status)")
    }
}

// MARK: - Footer

/// The quiet line at the bottom of a moment: an icon, the preset and what
/// it means here, and sometimes a link.
struct MomentFooter: View {
    let systemImage: String
    var iconColor: Color = Theme.focus
    let text: String
    var link: (title: String, action: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            Text(text)
            if let link {
                Button(link.title, action: link.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.link)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(1)
    }
}

// MARK: - Session ring

/// The live session ring: focus, drift and other arcs with small gaps
/// between them, and a white knob at "now" ringed in what you're doing.
struct MomentRing<Center: View>: View {
    let timeline: SessionTimeline
    /// 0...1 through the timeline.
    let progress: Double
    var size: CGFloat = 236
    var lineWidth: CGFloat = 15
    @ViewBuilder var center: () -> Center

    var body: some View {
        let segments = timeline.ringSegments(progress: progress)
        let knobKind = timeline.cells.lazy.compactMap { cell -> SessionTimeline.Kind? in
            if case .now(let classification) = cell { return SessionTimeline.Kind(classification) }
            return nil
        }.first
        let lineWidth = lineWidth

        ZStack {
            Canvas { context, canvasSize in
                let radius = min(canvasSize.width, canvasSize.height) / 2 - lineWidth * 1.2
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

                var track = Path()
                track.addArc(center: c, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(MomentPalette.ringTrack), lineWidth: lineWidth)

                for segment in segments {
                    var arc = Path()
                    arc.addArc(center: c, radius: radius, startAngle: .degrees(segment.start - 90),
                               endAngle: .degrees(segment.end - 90), clockwise: false)
                    context.stroke(arc, with: .color(Self.color(segment.kind)),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }

                let angle = Angle.degrees(progress * 360 - 90).radians
                let p = CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
                let knobRadius = lineWidth * 0.66
                let knob = Path(ellipseIn: CGRect(x: p.x - knobRadius, y: p.y - knobRadius,
                                                  width: knobRadius * 2, height: knobRadius * 2))
                context.fill(knob, with: .color(.white))
                context.stroke(knob, with: .color(knobKind.map(Self.color) ?? Theme.neutral), lineWidth: lineWidth * 0.23)
            }
            center()
        }
        .frame(width: size, height: size)
    }

    static func color(_ kind: SessionTimeline.Kind) -> Color {
        switch kind {
        case .focus: return Theme.focus
        case .drift: return Theme.distraction
        case .other: return Theme.other
        }
    }
}

/// "● Focused 27 min  ● Drifted 2 min  ● Other 2 min" under a ring. Drift
/// and other only show once there's a minute of them.
struct MomentLegend: View {
    let focused: Int
    let drifted: Int
    let other: Int

    var body: some View {
        HStack(spacing: 18) {
            entry(Theme.focus, "Focused \(focused) min")
            if drifted > 0 { entry(Theme.distraction, "Drifted \(drifted) min") }
            if other > 0 { entry(Theme.other, "Other \(other) min") }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.primaryText)
    }

    private func entry(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .lineLimit(1)
    }
}
