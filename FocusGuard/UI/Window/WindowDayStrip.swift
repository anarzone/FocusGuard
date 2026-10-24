import SwiftUI

/// "Your day": a sessions lane over an activity lane, hour marks under
/// them and a line at now. Hovering a session's block shows how it went.
struct WindowDayStrip: View {
    let window: DateInterval
    let sessions: [TodaySession]
    let activity: [DaySpan]
    /// Nil on a past day.
    let now: Date?
    /// A dashed box after now: the rest of the running session, or the
    /// next session if one started now.
    let preview: DateInterval?

    @State private var hovered: UUID?

    private let labelWidth: CGFloat = 60
    private let sessionLane: ClosedRange<CGFloat> = 4...18
    private let activityLane: ClosedRange<CGFloat> = 27...53
    private let stripHeight: CGFloat = 58

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - labelWidth)
            ZStack(alignment: .topLeading) {
                laneLabels
                ZStack(alignment: .topLeading) {
                    lanes(width: width)
                    hourLabels(width: width)
                }
                .offset(x: labelWidth)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = session(at: point.x, width: width)?.id
                    case .ended: hovered = nil
                    }
                }
                if let id = hovered, let session = sessions.first(where: { $0.id == id }) {
                    tooltip(for: session, width: width)
                }
            }
        }
        .frame(height: 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Geometry

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        let t = date.timeIntervalSince(window.start) / max(1, window.duration)
        return CGFloat(min(1, max(0, t))) * width
    }

    private func session(at px: CGFloat, width: CGFloat) -> TodaySession? {
        sessions.first { s in
            let lo = x(s.start, width: width) - 3
            let hi = x(s.end ?? now ?? s.start, width: width) + 3
            return px >= lo && px <= hi
        }
    }

    // MARK: - Drawing

    private var laneLabels: some View {
        ZStack(alignment: .topLeading) {
            Text("Sessions").offset(y: 4)
            Text("Activity").offset(y: 34)
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.tertiaryText)
        .frame(width: labelWidth, alignment: .leading)
    }

    private func lanes(width: CGFloat) -> some View {
        Canvas { context, _ in
            let sH = sessionLane.upperBound - sessionLane.lowerBound
            let aH = activityLane.upperBound - activityLane.lowerBound
            context.fill(Path(roundedRect: CGRect(x: 0, y: sessionLane.lowerBound, width: width, height: sH), cornerRadius: 4),
                         with: .color(Theme.lane))
            context.fill(Path(roundedRect: CGRect(x: 0, y: activityLane.lowerBound, width: width, height: aH), cornerRadius: 5),
                         with: .color(Theme.lane))

            if let id = hovered, let s = sessions.first(where: { $0.id == id }) {
                let lo = x(s.start, width: width) - 3
                let hi = x(s.end ?? now ?? s.start, width: width) + 3
                context.fill(Path(roundedRect: CGRect(x: lo, y: 0, width: max(6, hi - lo), height: stripHeight - 1), cornerRadius: 5),
                             with: .color(Theme.focus.opacity(0.10)))
            }

            for span in activity {
                let lo = x(span.start, width: width)
                let w = max(1, x(span.end, width: width) - lo - 0.5)
                context.fill(Path(CGRect(x: lo, y: activityLane.lowerBound, width: w, height: aH)),
                             with: .color(windowKindColor(span.kind)))
            }

            for s in sessions {
                let lo = x(s.start, width: width)
                let w = max(2, x(s.end ?? now ?? s.start, width: width) - lo)
                let isHovered = hovered == s.id
                let dim = hovered != nil && !isHovered
                let rect = isHovered
                    ? CGRect(x: lo, y: sessionLane.lowerBound - 1, width: w, height: sH + 2)
                    : CGRect(x: lo, y: sessionLane.lowerBound, width: w, height: sH)
                context.fill(Path(roundedRect: rect, cornerRadius: 3),
                             with: .color(Theme.focus.opacity(isHovered ? 1 : (dim ? 0.45 : 0.85))))
            }

            if let preview {
                let lo = x(preview.start, width: width)
                let w = max(4, x(preview.end, width: width) - lo)
                let rect = CGRect(x: lo + 0.5, y: sessionLane.lowerBound + 0.5, width: w - 1, height: sH - 1)
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Theme.focus),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            }

            if let now, now >= window.start, now <= window.end {
                let px = x(now, width: width)
                context.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: stripHeight)), with: .color(Theme.primaryText))
            }
        }
        .frame(width: width, height: stripHeight)
    }

    private func hourLabels(width: CGFloat) -> some View {
        let calendar = Calendar.current
        let startHour = calendar.component(.hour, from: window.start)
        let hours = Int((window.duration / 3600).rounded())
        let step = hours > 14 ? 3 : 2
        let nowX = now.flatMap { $0 >= window.start && $0 <= window.end ? x($0, width: width) : nil }
        let marks = stride(from: 0, through: hours, by: step).compactMap { offset -> (CGFloat, String)? in
            guard let date = calendar.date(byAdding: .hour, value: offset, to: window.start) else { return nil }
            let px = x(date, width: width)
            if let nowX, abs(px - nowX) < 30 { return nil }
            return (px, String(format: "%02d:00", (startHour + offset) % 24))
        }
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.1) { mark in
                Text(mark.1)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in labelAnchor(mark.0, width: width, labelWidth: d.width) }
            }
            if let nowX, let now {
                Text(WindowFormat.clock(now))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in labelAnchor(nowX, width: width, labelWidth: d.width) }
            }
        }
        .offset(y: 64)
    }

    /// Centred under `px`, but kept inside the strip at either end.
    private func labelAnchor(_ px: CGFloat, width: CGFloat, labelWidth: CGFloat) -> CGFloat {
        -min(max(0, px - labelWidth / 2), width - labelWidth)
    }

    // MARK: - Tooltip

    private func tooltip(for session: TodaySession, width: CGFloat) -> some View {
        let tipWidth: CGFloat = 230
        let mid = labelWidth + (x(session.start, width: width) + x(session.end ?? now ?? session.start, width: width)) / 2
        let left = min(max(0, mid - tipWidth / 2), labelWidth + width - tipWidth)
        return SessionTooltip(session: session, now: now)
            .frame(width: tipWidth)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.top) { d in d.height + 10 }
            .offset(x: left)
            .allowsHitTesting(false)
            .transition(.opacity)
            .zIndex(10)
    }

    private var accessibilitySummary: String {
        let range = "\(WindowFormat.clock(window.start)) to \(WindowFormat.clock(window.end))"
        guard !sessions.isEmpty else { return "Timeline from \(range). No sessions yet." }
        let list = sessions.reversed().map { s in
            "\(s.name) at \(WindowFormat.clock(s.start)), \(FocusRate.percent(focused: s.rate, drifted: 1 - s.rate))% focused"
        }
        return "Timeline from \(range). " + WindowFormat.count(sessions.count, "session") + ": " + list.joined(separator: "; ")
    }
}

/// What hovering a session block shows: its name, rate, times and how its
/// minutes went.
struct SessionTooltip: View {
    let session: TodaySession
    let now: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int((session.rate * 100).rounded()))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.primaryText)
            Text(subtitle)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
            if !session.runs.isEmpty {
                GeometryReader { geo in
                    let total = max(1, session.runs.reduce(0) { $0 + $1.seconds })
                    let gaps = CGFloat(session.runs.count - 1) * 2
                    HStack(spacing: 2) {
                        ForEach(Array(session.runs.enumerated()), id: \.offset) { _, run in
                            Rectangle().fill(windowKindColor(run.kind))
                                .frame(width: max(1, (geo.size.width - gaps) * CGFloat(run.seconds / total)))
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
            }
            if !session.apps.isEmpty {
                HStack(spacing: 10) {
                    ForEach(session.apps, id: \.name) { app in
                        Text("\(app.name) \(WindowFormat.hm(app.seconds))").lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.bodyText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
        .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.18), radius: 15, y: 10)
    }

    private var subtitle: String {
        let end = session.end.map(WindowFormat.clock) ?? "now"
        return "\(WindowFormat.clock(session.start))–\(end) · \(session.minutes) min · \(session.shape)"
    }
}
