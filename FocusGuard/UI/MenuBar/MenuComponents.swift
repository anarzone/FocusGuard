import SwiftUI

// MARK: - Module

/// Rounded module on the menu glass. Radius 13 sits concentric inside the
/// panel's 18 with its 6pt inset. A tint turns it into a status module
/// (drift, permissions) — tinted fill plus a matching hairline.
private struct MenuModule: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tint.map { $0.opacity(0.14) } ?? Theme.module))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.45) } ?? Theme.moduleStroke, lineWidth: 0.5))
    }
}

extension View {
    func menuModule(tint: Color? = nil) -> some View {
        modifier(MenuModule(tint: tint))
    }
}

// MARK: - Buttons

/// Full-width capsule. Prominent = the one accent-filled primary action.
struct CapsuleButton: View {
    let title: String
    var prominent: Bool
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Capsule().fill(prominent ? Theme.focusFill : Theme.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 40pt circular control with a caption, like Control Center's platters.
struct ControlPlatter: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.control))
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Native-looking menu row: accent highlight on hover, shortcut trailing.
struct MenuItemRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

// MARK: - Now row

/// What's frontmost, and how it's classified. Dot + word, never colour alone.
struct NowRow: View {
    let snapshot: ActivitySnapshot?

    var body: some View {
        HStack(spacing: 10) {
            if let snapshot {
                AppGlyph(
                    kind: AppGlyph.kind(forBundleId: snapshot.bundleIdentifier, name: snapshot.appName),
                    bundleId: snapshot.bundleIdentifier,
                    size: 30
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let detail = snapshot.distinctDetail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle().fill(color(snapshot.classification)).frame(width: 7, height: 7)
                    Text(categoryName(snapshot.classification))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                AppGlyph(kind: .generic, size: 30)
                Text("Detecting…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, -2)
        .padding(.vertical, -2)
        .menuModule()
        .accessibilityElement(children: .combine)
    }

    private func color(_ c: Classification) -> Color {
        switch c {
        case .focus:       return Theme.focus
        case .neutral:     return Theme.other
        case .distraction: return Theme.distraction
        }
    }

}

// MARK: - Session ring

/// The timer: a ring that fills clockwise from 12 o'clock as the session
/// runs, coloured by what each stretch actually was. The knob marks now.
struct SessionRingView<Center: View>: View {
    let timeline: SessionTimeline
    /// 0...1 through the timeline for a live session; nil once it has ended.
    let progress: Double?
    var size: CGFloat = 168
    var lineWidth: CGFloat = 13
    /// 0...1 through the current minute. Drawn as a thin inner ring that
    /// fills once a minute, so a running session visibly moves every second
    /// (one second barely moves the knob on a 50-minute ring). Nil when
    /// paused or finished.
    var secondsSweep: Double? = nil
    /// What happened in a hovered arc. When set, hovering an arc highlights
    /// it and shows its time, kind and top apps in the centre.
    var stretchDetail: ((SessionTimeline.RingSegment) -> SessionTimeline.Stretch?)? = nil
    @ViewBuilder var center: () -> Center

    @State private var hovered: Int?

    var body: some View {
        let segments = timeline.ringSegments(progress: progress)
        let knobKind = timeline.cells.lazy.compactMap { cell -> SessionTimeline.Kind? in
            if case .now(let c) = cell { return SessionTimeline.Kind(c) }
            return nil
        }.first

        ZStack {
            Canvas { context, canvasSize in
                let radius = (min(canvasSize.width, canvasSize.height) - lineWidth) / 2 - 3
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

                var track = Path()
                track.addArc(center: c, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(Theme.control), lineWidth: lineWidth)

                for (index, segment) in segments.enumerated() {
                    var arc = Path()
                    arc.addArc(center: c, radius: radius,
                               startAngle: .degrees(segment.start - 90),
                               endAngle: .degrees(segment.end - 90),
                               clockwise: false)
                    let isHovered = hovered == index
                    let dimmed = hovered != nil && !isHovered
                    context.stroke(arc, with: .color(Self.color(segment.kind).opacity(dimmed ? 0.4 : 1)),
                                   style: StrokeStyle(lineWidth: isHovered ? lineWidth + 4 : lineWidth, lineCap: .butt))
                }

                if let secondsSweep {
                    let inner = radius - lineWidth / 2 - max(5, lineWidth * 0.45)
                    let sweepWidth = max(2, lineWidth * 0.2)
                    var sweepTrack = Path()
                    sweepTrack.addArc(center: c, radius: inner, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                    context.stroke(sweepTrack, with: .color(Theme.control), lineWidth: sweepWidth)
                    if secondsSweep > 0 {
                        var sweep = Path()
                        sweep.addArc(center: c, radius: inner, startAngle: .degrees(-90),
                                     endAngle: .degrees(min(1, secondsSweep) * 360 - 90), clockwise: false)
                        context.stroke(sweep, with: .color(Theme.focus.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: sweepWidth, lineCap: .round))
                    }
                }

                if let progress {
                    let angle = Angle.degrees(progress * 360 - 90).radians
                    let p = CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
                    let knobRadius = lineWidth * 0.65
                    let knob = Path(ellipseIn: CGRect(x: p.x - knobRadius, y: p.y - knobRadius,
                                                      width: knobRadius * 2, height: knobRadius * 2))
                    context.fill(knob, with: .color(.white))
                    context.stroke(knob, with: .color(knobKind.map(Self.color) ?? Color.secondary),
                                   lineWidth: lineWidth * 0.23)
                }
            }
            if let index = hovered, segments.indices.contains(index),
               let detail = stretchDetail?(segments[index]) {
                StretchSummary(stretch: detail, compact: size < 150)
                    .frame(width: (size - lineWidth * 2) * 0.74)
                    .transition(.opacity)
            } else {
                center()
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onContinuousHover { phase in
            guard stretchDetail != nil else { return }
            switch phase {
            case .active(let point):
                hovered = Self.segmentIndex(at: point, size: size, lineWidth: lineWidth, segments: segments)
            case .ended:
                hovered = nil
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Which arc is under the pointer: on the ring (with some slack either
    /// side so it's easy to hit), at an angle inside an arc.
    static func segmentIndex(at point: CGPoint, size: CGFloat, lineWidth: CGFloat,
                             segments: [SessionTimeline.RingSegment]) -> Int? {
        let radius = (size - lineWidth) / 2 - 3
        let dx = point.x - size / 2, dy = point.y - size / 2
        guard abs(hypot(dx, dy) - radius) <= lineWidth else { return nil }
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return segments.firstIndex { degrees >= $0.start - 1 && degrees <= $0.end + 1 }
    }

    static func color(_ kind: SessionTimeline.Kind) -> Color {
        switch kind {
        case .focus: return Theme.focus
        case .drift: return Theme.distraction
        case .other: return Theme.other
        }
    }

    private var accessibilitySummary: String {
        let m = timeline.minutesPerCell
        return "Session ring: \(timeline.focusCells * m) minutes focused, "
            + "\(timeline.driftCells * m) drifted, \(timeline.otherCells * m) in other apps"
    }
}

/// "44:12", or "1:05:09" past an hour — the live clock in the ring's centre.
enum SessionClock {
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// How far through the current minute a running session is.
    static func sweep(elapsed: TimeInterval) -> Double {
        elapsed.truncatingRemainder(dividingBy: 60) / 60
    }
}

/// A hovered arc, shown in the ring's centre: when, what kind, top apps.
struct StretchSummary: View {
    let stretch: SessionTimeline.Stretch
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            Text(timeRange)
                .font(.system(size: compact ? 11 : 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                Circle().fill(SessionRingView<EmptyView>.color(stretch.kind)).frame(width: 6, height: 6)
                Text(compact ? "\(kindName) \(stretch.minutes)m" : "\(kindName) · \(stretch.minutes) min")
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if compact {
                if let top = stretch.apps.first {
                    Text(top.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(stretch.apps) { app in
                        HStack(spacing: 4) {
                            Text(app.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 2)
                            Text(Self.duration(app.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var kindName: String {
        switch stretch.kind {
        case .focus: return "Focused"
        case .drift: return "Drifted"
        case .other: return "Other"
        }
    }

    private var timeRange: String {
        let start = stretch.start.formatted(date: .omitted, time: .shortened)
        if stretch.includesNow { return "\(start) – now" }
        return "\(start)–\(stretch.end.formatted(date: .omitted, time: .shortened))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}

/// Legend under the ring. Live sessions show the focus share on the right;
/// the recap shows per-kind minute counts instead.
struct RingLegend: View {
    var counts: (focus: Int, drift: Int, other: Int)?
    var trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            swatch(Theme.focus, "Focused", counts?.focus)
            swatch(Theme.distraction, "Drifted", counts?.drift)
            swatch(Theme.other, "Other", counts?.other)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
    }

    private func swatch(_ color: Color, _ title: String, _ count: Int?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(count.map { "\(title) \($0)" } ?? title)
        }
    }
}

// MARK: - In the zone

/// Current unbroken focus run, measured against today's best.
struct ZoneModule: View {
    let runs: FocusRuns
    let bestToday: TimeInterval
    /// Drifting right now: the counter shows the reset.
    let drifting: Bool

    private var currentMinutes: Int { Int(runs.current / 60) }
    private var bestMinutes: Int { Int(max(bestToday, runs.longest) / 60) }
    private var active: Bool { !drifting && runs.current > 0 }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(active ? Theme.focusTint : Theme.control)
                ZoneGlyph(color: active ? Theme.focus : Color.secondary)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("In the zone")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("\(active ? currentMinutes : 0) min")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 5) {
                if drifting {
                    if runs.lastEnded >= 60 {
                        Text("Run ended at \(Int(runs.lastEnded / 60)) min")
                            .font(.system(size: 11))
                    }
                    Text("Restarts when you're back")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if active, currentMinutes >= bestMinutes, currentMinutes >= 1 {
                    Text("New best today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                } else if bestMinutes > 0 {
                    Text("Best today \(bestMinutes) min")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.control)
                            Capsule().fill(Theme.focus)
                                .frame(width: geo.size.width * CGFloat(min(1, Double(currentMinutes) / Double(bestMinutes))))
                        }
                    }
                    .frame(width: 112, height: 5)
                    .accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .menuModule()
        .accessibilityElement(children: .combine)
    }
}

/// Concentric target used for "in the zone".
struct ZoneGlyph: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = size.width / 18
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for r in [7.0, 3.6] {
                let rr = r * s
                context.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(color), lineWidth: 1.6 * s)
            }
            let dot = 0.9 * s
            context.fill(Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)),
                         with: .color(color))
        }
    }
}
