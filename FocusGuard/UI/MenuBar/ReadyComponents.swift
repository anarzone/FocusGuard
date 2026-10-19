import AppKit
import SwiftUI

/// How the dial and ruler settle on a length, and glide when the other one
/// changes it.
private let settle = Animation.spring(response: 0.32, dampingFraction: 0.88)

// MARK: - Twist dial

/// The ready menu's length picker: drag round the ring like a kitchen timer.
/// One turn is two hours. The arc follows the pointer and settles on the
/// nearest 5 minutes when you let go. Same size and stroke as
/// `SessionRingView`, so the arc you set is the ring you then watch fill.
struct TwistDial<Center: View>: View {
    @Binding var minutes: Int
    var size: CGFloat = 168
    var lineWidth: CGFloat = 13
    @ViewBuilder var center: () -> Center

    /// Fractional minutes under the pointer while a drag is in progress.
    @State private var scrub: Double?

    var body: some View {
        ZStack {
            DialFace(value: scrub ?? Double(minutes), knobScale: scrub == nil ? 0.65 : 0.8, lineWidth: lineWidth)
            center()
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let continuing = scrub != nil
                    guard continuing || DialMath.isOnRing(value.startLocation, size: size, lineWidth: lineWidth) else { return }
                    let raw = DialMath.rawMinutes(at: value.location, in: size, previous: scrub ?? Double(minutes),
                                                  continuing: continuing)
                    // The first press glides to where it landed; after that the arc tracks the pointer.
                    withAnimation(continuing ? nil : settle) { scrub = raw }
                    setMinutes(DialMath.snap(raw), on: $minutes)
                }
                .onEnded { _ in
                    guard scrub != nil else { return }
                    withAnimation(settle) { scrub = nil }
                }
        )
        .animation(scrub == nil ? settle : nil, value: minutes)
        .help("Drag round the ring to set how long")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session length")
        .accessibilityValue("\(minutes) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: minutes = min(DialMath.maxMinutes, minutes + DialMath.step)
            case .decrement: minutes = max(DialMath.range.lowerBound, minutes - DialMath.step)
            @unknown default: break
            }
        }
    }
}

/// The dial's ring, ticks, arc and knob at `value` minutes. Animatable so
/// the arc glides rather than jumping between 5-minute marks.
private struct DialFace: View, Animatable {
    var value: Double
    var knobScale: Double
    let lineWidth: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(value, knobScale) }
        set { value = newValue.first; knobScale = newValue.second }
    }

    var body: some View {
        Canvas { context, canvasSize in
            let radius = (min(canvasSize.width, canvasSize.height) - lineWidth) / 2 - 3
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            func point(_ degrees: Double, _ r: CGFloat) -> CGPoint {
                let a = Angle.degrees(degrees - 90).radians
                return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
            func arc(to degrees: Double) -> Path {
                var p = Path()
                p.addArc(center: c, radius: radius, startAngle: .degrees(-90),
                         endAngle: .degrees(degrees - 90), clockwise: false)
                return p
            }

            var track = Path()
            track.addArc(center: c, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .color(Theme.control), lineWidth: lineWidth)

            // A tick every 5 minutes, longer each quarter hour.
            let tickOuter = radius - lineWidth / 2 - 4
            let ticks = DialMath.minutesPerTurn / DialMath.step
            for i in 0..<ticks {
                let degrees = Double(i) / Double(ticks) * 360
                let major = (i * DialMath.step) % 15 == 0
                var tick = Path()
                tick.move(to: point(degrees, tickOuter))
                tick.addLine(to: point(degrees, tickOuter - (major ? 6 : 3)))
                context.stroke(tick, with: .color(major ? Theme.other : Theme.gridFuture),
                               style: StrokeStyle(lineWidth: major ? 1.5 : 1, lineCap: .round))
            }
            for mark in [30, 60, 90] {
                let label = Text("\(mark)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                context.draw(label, at: point(DialMath.degrees(for: Double(mark)), tickOuter - 18))
            }

            // The set length, from 12 o'clock. Past one turn, the extra
            // lap rides on top with a shadow, like an overfull Activity ring.
            let laps = DialMath.laps(for: value)
            context.stroke(arc(to: laps.full > 0 ? 360 : laps.degrees), with: .color(Theme.focus), lineWidth: lineWidth)
            if laps.full > 0 {
                var lap = context
                lap.addFilter(.shadow(color: .black.opacity(0.35), radius: 2))
                lap.stroke(arc(to: laps.degrees), with: .color(Theme.focus), lineWidth: lineWidth)
            }

            let p = point(laps.degrees, radius)
            let knobRadius = lineWidth * knobScale
            let knob = Path(ellipseIn: CGRect(x: p.x - knobRadius, y: p.y - knobRadius,
                                              width: knobRadius * 2, height: knobRadius * 2))
            context.fill(knob, with: .color(.white))
            context.stroke(knob, with: .color(Theme.focus), lineWidth: lineWidth * 0.23)
        }
    }
}

/// Sets the length if it changed, with a trackpad tick for each 5-minute
/// step crossed. Shared by the dial and the ruler.
@MainActor
private func setMinutes(_ value: Int, on minutes: Binding<Int>) {
    guard value != minutes.wrappedValue else { return }
    minutes.wrappedValue = value
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

/// Angle ↔ minutes for `TwistDial`.
enum DialMath {
    static let minutesPerTurn = 120
    static let step = 5
    /// What the dial can set. Longer sessions come from the ruler.
    static let range = 5...120
    static let maxMinutes = Constants.SessionDurations.customMax

    /// Clockwise from 12 o'clock.
    static func degrees(for minutes: Double) -> Double {
        minutes / Double(minutesPerTurn) * 360
    }

    /// Whole turns, and where the knob sits on the last one. 120 is one full
    /// turn with the knob back at the top, not zero.
    static func laps(for minutes: Double) -> (full: Int, degrees: Double) {
        guard minutes > 0 else { return (0, 0) }
        let full = max(0, Int((minutes / Double(minutesPerTurn)).rounded(.up)) - 1)
        return (full, degrees(for: minutes - Double(full * minutesPerTurn)))
    }

    /// Presses start a drag only on or just inside the ring, so clicking the
    /// numbers in the middle doesn't change the length.
    static func isOnRing(_ point: CGPoint, size: CGFloat, lineWidth: CGFloat) -> Bool {
        let radius = (size - lineWidth) / 2 - 3
        let distance = hypot(point.x - size / 2, point.y - size / 2)
        return distance >= radius - lineWidth * 2.5 && distance <= radius + lineWidth
    }

    /// The unsnapped length for a pointer at `point` on a dial `size` across.
    static func rawMinutes(at point: CGPoint, in size: CGFloat, previous: Double, continuing: Bool) -> Double {
        var degrees = atan2(point.x - size / 2, size / 2 - point.y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return rawMinutes(atDegrees: degrees, previous: previous, continuing: continuing)
    }

    /// While a drag is `continuing`, sweeping past 12 o'clock pins to the
    /// nearer end instead of jumping from 2 hours to 5 minutes. A fresh press
    /// right at the top goes to whichever end the length was nearer.
    static func rawMinutes(atDegrees degrees: Double, previous: Double, continuing: Bool) -> Double {
        let turn = Double(minutesPerTurn)
        let raw = degrees / 360 * turn
        let low = Double(range.lowerBound), high = Double(range.upperBound)
        if continuing {
            if previous >= turn * 0.75, raw < turn * 0.25 { return high }
            if previous <= turn * 0.25, raw > turn * 0.75 { return low }
        } else if raw < Double(step) / 2 || raw > turn - Double(step) / 2 {
            return previous > turn / 2 ? high : low
        }
        return min(max(raw, low), high)
    }

    static func snap(_ raw: Double) -> Int {
        let snapped = Int((raw / Double(step)).rounded()) * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    static func minutes(atDegrees degrees: Double, previous: Int, continuing: Bool) -> Int {
        snap(rawMinutes(atDegrees: degrees, previous: Double(previous), continuing: continuing))
    }
}

// MARK: - Length ruler

/// Scrub sideways to set the length, like a camera's zoom ruler: the marks
/// slide under a fixed line in the middle. Covers 5 minutes to 8 hours, so
/// it reaches past the dial's two-hour turn. Drag or swipe with two fingers
/// (momentum carries it on); a flick coasts before it settles. Presets are
/// labelled in the accent colour; click a mark to jump to it.
struct LengthRuler: View {
    @Binding var minutes: Int

    /// Fractional minutes under the line while a drag or swipe is in progress.
    @State private var scrub: Double?
    @State private var dragStart: Int?
    @State private var pendingSettle: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            RulerMarks(value: scrub ?? Double(minutes))
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                             .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .top) {
                    Capsule().fill(Theme.focus).frame(width: 2.5, height: 24)
                }
                .contentShape(Rectangle())
                .background(ScrollWheelReader(onScroll: scroll))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStart ?? minutes
                            dragStart = start
                            guard abs(value.translation.width) >= 3 || scrub != nil else { return }
                            let raw = RulerMath.value(start: Double(start), translation: value.translation.width)
                            scrub = raw
                            setMinutes(RulerMath.snap(raw), on: $minutes)
                        }
                        .onEnded { value in
                            if scrub == nil {
                                // A click: jump to the mark under the pointer.
                                let target = RulerMath.value(start: Double(minutes), translation: width / 2 - value.location.x)
                                setMinutes(RulerMath.snap(target), on: $minutes)
                            } else {
                                // A flick coasts on to where it was heading, then settles.
                                let start = Double(dragStart ?? minutes)
                                let target = RulerMath.snap(RulerMath.value(start: start, translation: value.predictedEndTranslation.width))
                                withAnimation(settle) {
                                    scrub = nil
                                    minutes = target
                                }
                            }
                            dragStart = nil
                        }
                )
        }
        .frame(height: 40)
        .animation(scrub == nil ? settle : nil, value: minutes)
        .help("Drag or swipe sideways to set how long")
        .accessibilityElement()
        .accessibilityLabel("Session length ruler")
        .accessibilityValue("\(minutes) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: minutes = min(RulerMath.range.upperBound, minutes + RulerMath.step)
            case .decrement: minutes = max(RulerMath.range.lowerBound, minutes - RulerMath.step)
            @unknown default: break
            }
        }
        .accessibilityActions {
            ForEach(Constants.SessionDurations.presets, id: \.self) { preset in
                Button("\(preset) minutes") { minutes = preset }
            }
        }
    }

    /// Trackpad swipes scrub like a drag, momentum included, then settle.
    /// A mouse wheel moves 5 minutes a notch.
    private func scroll(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
            guard delta != 0 else { return }
            let next = minutes + (delta > 0 ? RulerMath.step : -RulerMath.step)
            setMinutes(min(RulerMath.range.upperBound, max(RulerMath.range.lowerBound, next)), on: $minutes)
            return
        }

        if event.phase == .began || event.momentumPhase == .began {
            pendingSettle?.cancel()
            pendingSettle = nil
        }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if delta != 0 {
            let raw = RulerMath.value(start: scrub ?? Double(minutes), translation: delta)
            scrub = raw
            setMinutes(RulerMath.snap(raw), on: $minutes)
        }

        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            settleScrub()
        } else if event.phase == .ended || event.phase == .cancelled {
            // Momentum, if any, starts right after the fingers lift; wait for it.
            let work = DispatchWorkItem { settleScrub() }
            pendingSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    private func settleScrub() {
        pendingSettle = nil
        guard scrub != nil else { return }
        withAnimation(settle) { scrub = nil }
    }
}

/// Hands scroll-wheel and trackpad scroll events over the view to
/// `onScroll`. Sits behind the SwiftUI content and never takes clicks. Once a
/// swipe starts over the view, it keeps the swipe (momentum too) even if the
/// pointer drifts off.
private struct ScrollWheelReader: NSViewRepresentable {
    let onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView() }
    func updateNSView(_ view: ReaderView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: ReaderView, coordinator: ()) { view.stopMonitoring() }

    final class ReaderView: NSView {
        var onScroll: ((NSEvent) -> Void)?
        private var monitor: Any?
        private var tracking = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if event.phase == .began || event.phase == .mayBegin { self.tracking = inside }
                guard inside || self.tracking else { return event }
                self.onScroll?(event)
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled { self.tracking = false }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            tracking = false
        }
    }
}

/// The ruler's marks, centred on `value`. Animatable so the marks glide when
/// the length changes from the dial or a click.
private struct RulerMarks: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.width / 2
            let reach = Double(mid / RulerMath.pointsPerMinute) + Double(RulerMath.step)
            let first = max(RulerMath.range.lowerBound, Int((value - reach) / Double(RulerMath.step)) * RulerMath.step)
            let last = min(RulerMath.range.upperBound, Int(value + reach))
            guard first <= last else { return }
            for m in stride(from: first, through: last, by: RulerMath.step) {
                let x = mid + CGFloat(Double(m) - value) * RulerMath.pointsPerMinute
                let label = RulerMath.label(for: m)
                let preset = Constants.SessionDurations.presets.contains(m)
                let height: CGFloat = label != nil ? 14 : (m % 15 == 0 ? 10 : 6)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 4))
                tick.addLine(to: CGPoint(x: x, y: 4 + height))
                let color = preset ? Theme.focus : (label != nil || m % 15 == 0 ? Theme.other : Theme.gridFuture)
                context.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: preset ? 2 : 1.2, lineCap: .round))
                if let label {
                    let text = Text(label)
                        .font(.system(size: preset ? 11 : 10, weight: preset ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(preset ? AnyShapeStyle(Theme.focus) : AnyShapeStyle(.secondary))
                    context.draw(text, at: CGPoint(x: x, y: 32))
                }
            }
        }
    }
}

/// Minutes ↔ points for `LengthRuler`.
enum RulerMath {
    static let pointsPerMinute: CGFloat = 3.2
    static let step = 5
    static let range = Constants.SessionDurations.customMin...Constants.SessionDurations.customMax

    /// The fractional length under the line after dragging `translation`
    /// points from `start`. Dragging left brings longer lengths in.
    static func value(start: Double, translation: CGFloat) -> Double {
        let raw = start - Double(translation / pointsPerMinute)
        return min(Double(range.upperBound), max(Double(range.lowerBound), raw))
    }

    static func snap(_ value: Double) -> Int {
        let snapped = Int((value / Double(step)).rounded()) * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    /// Presets in minutes, the hour, then whole hours from two.
    static func label(for minutes: Int) -> String? {
        if Constants.SessionDurations.presets.contains(minutes) || minutes == 60 { return "\(minutes)" }
        if minutes >= 120, minutes % 60 == 0 { return "\(minutes / 60)h" }
        return nil
    }
}

// MARK: - Day strip

/// Today on one line: each stretch coloured by what it was, a line at now,
/// and a dashed block where the session you're about to start would land.
/// Animatable so the block glides as the length changes.
struct DayStripView: View, Animatable {
    let spans: [DaySpan]
    let now: Date
    /// Length of the session being set up; 0 hides the preview.
    var previewMinutes: Double = 0
    var calendar: Calendar = .current

    var animatableData: Double {
        get { previewMinutes }
        set { previewMinutes = newValue }
    }

    var body: some View {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let previewEnd = previewMinutes > 0 ? min(dayEnd, now.addingTimeInterval(previewMinutes * 60)) : nil
        let window = DayStrip.window(dayStart: dayStart, firstActivity: spans.first?.start,
                                     until: max(now, previewEnd ?? now), calendar: calendar)

        Canvas { context, size in
            let w = size.width
            let barHeight: CGFloat = 14
            func x(_ date: Date) -> CGFloat {
                min(w, max(0, CGFloat(date.timeIntervalSince(window.start) / window.duration) * w))
            }
            func bar(_ start: Date, _ end: Date) -> CGRect {
                let x0 = x(start), x1 = x(end)
                return CGRect(x: x0, y: 0, width: max(1, x1 - x0 - 0.5), height: barHeight)
            }

            let strip = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: barHeight), cornerRadius: 4)
            context.fill(strip, with: .color(Theme.control))
            var spansContext = context
            spansContext.clip(to: strip)
            for span in spans where span.end > window.start {
                spansContext.fill(Path(bar(span.start, span.end)), with: .color(SessionRingView<EmptyView>.color(span.kind)))
            }

            if let previewEnd, previewEnd > now {
                let rect = bar(now, previewEnd).insetBy(dx: 0.75, dy: 0.75)
                let ghost = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(ghost, with: .color(Theme.focus.opacity(0.18)))
                context.stroke(ghost, with: .color(Theme.focus),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }

            let nx = x(now)
            context.fill(Path(CGRect(x: nx - 0.75, y: -2, width: 1.5, height: barHeight + 4)), with: .color(.primary))

            // Hour labels, spaced so they never crowd.
            let hours = window.duration / 3600
            let every = hours > 18 ? 4 : (hours > 12 ? 3 : 2)
            var tick = calendar.nextDate(after: window.start.addingTimeInterval(-1),
                                         matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? window.start
            while tick <= window.end {
                if calendar.component(.hour, from: tick) % every == 0 {
                    let label = Text(tick.formatted(.dateTime.hour()))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    let px = x(tick)
                    let anchor: UnitPoint = px < 14 ? .leading : (px > w - 14 ? .trailing : .center)
                    context.draw(label, at: CGPoint(x: px, y: barHeight + 11), anchor: anchor)
                }
                tick = tick.addingTimeInterval(3600)
            }
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary(previewEnd: previewEnd))
    }

    private func accessibilitySummary(previewEnd: Date?) -> String {
        let focused = spans.filter { $0.kind == .focus }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let base = "Today so far: \(formatDuration(focused)) focused"
        guard let previewEnd else { return base }
        return base + ". A session now would end at \(previewEnd.formatted(date: .omitted, time: .shortened))"
    }
}

enum DayStrip {
    /// 8 AM to 6 PM, stretched to the hour to cover the day's first activity
    /// and `until` (now, or the end of the session being set up). Never past
    /// midnight.
    static func window(dayStart: Date, firstActivity: Date?, until: Date, calendar: Calendar) -> DateInterval {
        func hours(_ date: Date) -> Double { date.timeIntervalSince(dayStart) / 3600 }
        let startHour = min(8, firstActivity.map { floor(hours($0)) } ?? 8)
        let endHour = min(24, max(18, ceil(hours(until))))
        let start = calendar.date(byAdding: .hour, value: Int(max(0, startHour)), to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: Int(endHour), to: dayStart) ?? until
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(3600)))
    }
}
