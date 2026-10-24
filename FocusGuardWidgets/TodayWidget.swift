import SwiftUI
import WidgetKit

/// Today's ring in small, the ring with a start button in medium, and the
/// week in large. While a session or a break runs, each size shows it.
struct TodayWidget: Widget {
    static let kind = "com.anar.focusguard.today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Today's focus against your goal, the session running now, and your week.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var palette: Palette { Palette(scheme: scheme) }

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium: medium(snapshot)
            case .systemLarge:  large(snapshot)
            default:            small(snapshot)
            }
        } else {
            OpenAppNote(palette: palette)
        }
    }

    // MARK: - Small

    private func small(_ s: SurfaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: title(s), palette: palette, isBreak: s.phase == .onBreak)
            centerRing(s, size: 108, lineWidth: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func title(_ s: SurfaceSnapshot) -> String {
        switch s.phase {
        case .ready:              return "Today"
        case .focusing, .paused:  return s.session?.name ?? "Focusing"
        case .onBreak:            return "Break"
        }
    }

    /// The ring with its numbers inside: today, the session, or the break.
    @ViewBuilder
    private func centerRing(_ s: SurfaceSnapshot, size: CGFloat, lineWidth: CGFloat) -> some View {
        switch s.phase {
        case .ready:
            ZStack {
                ProgressRing(progress: s.today.goalProgress, palette: palette, lineWidth: lineWidth)
                VStack(spacing: 0) {
                    Text(SurfaceWords.duration(s.today.focused))
                        .font(.system(size: size > 100 ? 20 : 16, weight: .semibold)).monospacedDigit()
                    Text("of \(SurfaceWords.duration(s.today.goalSeconds))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(SurfaceWords.duration(s.today.focused)) focused today, of a \(SurfaceWords.duration(s.today.goalSeconds)) goal")
        case .focusing, .paused:
            ZStack {
                SessionRing(snapshot: s, date: entry.date, palette: palette, lineWidth: lineWidth)
                VStack(spacing: 0) {
                    SessionClock(snapshot: s, date: entry.date)
                        .font(.system(size: size > 100 ? 22 : 17, weight: .semibold))
                    Text(s.phase == .paused ? "paused" : (s.session?.plannedSeconds == nil ? "so far" : "left"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
        case .onBreak:
            ZStack {
                ProgressRing(progress: breakProgress(s), palette: palette, lineWidth: lineWidth)
                VStack(spacing: 0) {
                    BreakClock(snapshot: s, date: entry.date)
                        .font(.system(size: size > 100 ? 22 : 17, weight: .semibold))
                    if let end = s.onBreak?.endsAt {
                        Text("back at \(SurfaceWords.clock(end))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
        }
    }

    private func breakProgress(_ s: SurfaceSnapshot) -> Double {
        guard let b = s.onBreak else { return 0 }
        let length = b.endsAt.timeIntervalSince(b.startedAt)
        return length > 0 ? max(0, b.endsAt.timeIntervalSince(entry.date)) / length : 0
    }

    // MARK: - Medium

    private func medium(_ s: SurfaceSnapshot) -> some View {
        HStack(alignment: .center, spacing: 16) {
            centerRing(s, size: 120, lineWidth: 11)
            VStack(alignment: .leading, spacing: 10) {
                switch s.phase {
                case .ready:              readyDetails(s)
                case .focusing, .paused:  sessionDetails(s)
                case .onBreak:            breakDetails(s)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func readyDetails(_ s: SurfaceSnapshot) -> some View {
        if let last = s.lastSession {
            VStack(alignment: .leading, spacing: 1) {
                Text("Last session · \(SurfaceWords.clock(last.endedAt))").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(last.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(last.minutes) min · \(Int((last.focusRate * 100).rounded()))% focused")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(Int((s.today.focusRate * 100).rounded()))% focus rate").font(.system(size: 14, weight: .semibold))
                Text(s.today.sessions == 1 ? "1 session" : "\(s.today.sessions) sessions")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 6) {
            Button(intent: WidgetStartIntent(minutes: s.usualMinutes)) {
                PillLabel(title: "Start \(s.usualMinutes) min", prominent: true, palette: palette, height: 32)
            }
            .buttonStyle(.plain)
            let other = s.usualMinutes == 25 ? 50 : 25
            Button(intent: WidgetStartIntent(minutes: other)) {
                PillLabel(title: "\(other)", prominent: false, palette: palette, height: 32)
            }
            .buttonStyle(.plain)
            .frame(width: 44)
            .accessibilityLabel("Start \(other) min")
        }
    }

    @ViewBuilder
    private func sessionDetails(_ s: SurfaceSnapshot) -> some View {
        if let session = s.session {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(session.focused + session.drifted >= 60
                     ? "\(Int((session.focusRate * 100).rounded()))% focused so far"
                     : (s.phase == .paused ? "Paused" : "Just started"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                LegendRow(color: palette.focus, text: "Focused \(Int(session.focused / 60)) min")
                LegendRow(color: palette.drift, text: "Drifted \(Int(session.drifted / 60)) min")
            }
            SessionButtons(paused: s.phase == .paused, palette: palette)
        }
    }

    @ViewBuilder
    private func breakDetails(_ s: SurfaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Break").font(.system(size: 14, weight: .semibold))
            Text(s.lastSession.map { "After \($0.name)" } ?? "Time to stretch").font(.system(size: 12))
                .foregroundStyle(.secondary).lineLimit(1)
        }
        BreakButtons(canEnd: s.onBreak?.canEndEarly ?? true, palette: palette)
    }

    // MARK: - Large

    private func large(_ s: SurfaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ShieldMark(color: palette.focus)
                Text("Today").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(largeStatus(s)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if s.phase == .ready {
                HStack(spacing: 16) {
                    ZStack {
                        ProgressRing(progress: s.today.goalProgress, palette: palette, lineWidth: 9)
                        Text("\(Int((s.today.goalProgress * 100).rounded()))%").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    }
                    .frame(width: 92, height: 92)
                    .accessibilityHidden(true)
                    totals(s)
                }
            } else {
                totals(s)
                HStack(spacing: 12) {
                    centerRing(s, size: 76, lineWidth: 7)
                    VStack(alignment: .leading, spacing: 8) {
                        if s.phase == .onBreak {
                            BreakButtons(canEnd: s.onBreak?.canEndEarly ?? true, palette: palette)
                        } else {
                            if let session = s.session, session.focused + session.drifted >= 60 {
                                Text("\(Int((session.focusRate * 100).rounded()))% focused so far")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            SessionButtons(paused: s.phase == .paused, palette: palette)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("This week").font(.system(size: 11)).foregroundStyle(.secondary)
                WeekBars(week: s.week, goal: s.today.goalSeconds, todayIndex: s.weekIndex(of: entry.date), palette: palette)
                    .frame(maxHeight: .infinity)
            }
            if s.phase == .ready {
                Button(intent: WidgetStartIntent(minutes: s.usualMinutes)) {
                    PillLabel(title: "Start \(s.usualMinutes) minutes of focus", prominent: true, palette: palette, height: 34)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func totals(_ s: SurfaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SurfaceWords.duration(s.today.focused)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                Text("of \(SurfaceWords.duration(s.today.goalSeconds))\(s.phase == .ready ? "" : " goal")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("\(Int((s.today.focusRate * 100).rounded()))% focus rate · \(s.today.sessions == 1 ? "1 session" : "\(s.today.sessions) sessions")")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func largeStatus(_ s: SurfaceSnapshot) -> String {
        switch s.phase {
        case .ready:
            return s.today.streak >= 2 ? "\(s.today.streak)-day streak" : ""
        case .focusing, .paused:
            let name = s.session?.name ?? "Focusing"
            if s.phase == .paused { return "\(name) · paused" }
            if let left = s.timeLeft(at: entry.date) { return "\(name) · \(SurfaceWords.minutesLeft(left)) left" }
            return name
        case .onBreak:
            return s.onBreak.map { "Break · back at \(SurfaceWords.clock($0.endsAt))" } ?? "Break"
        }
    }
}

// MARK: - Pieces

private struct Header: View {
    let title: String
    let palette: Palette
    let isBreak: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isBreak {
                Image(systemName: "cup.and.saucer").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.focus).accessibilityHidden(true)
            } else {
                ShieldMark(color: palette.focus)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
    }
}

/// Time left (or so far), counting by itself between timeline entries.
struct SessionClock: View {
    let snapshot: SurfaceSnapshot
    let date: Date

    var body: some View {
        Group {
            if snapshot.phase == .focusing, let end = snapshot.sessionEndsAt, end > date {
                Text(timerInterval: date...end, countsDown: true)
            } else if snapshot.phase == .focusing, snapshot.session?.plannedSeconds == nil {
                Text(date.addingTimeInterval(-snapshot.running(at: date)), style: .timer)
            } else {
                Text(SurfaceWords.stopwatch(snapshot.timeLeft(at: date) ?? snapshot.running(at: date)))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.center)
    }
}

struct BreakClock: View {
    let snapshot: SurfaceSnapshot
    let date: Date

    var body: some View {
        Group {
            if let end = snapshot.onBreak?.endsAt, end > date {
                Text(timerInterval: date...end, countsDown: true)
            } else {
                Text("0:00")
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.center)
    }
}

private struct LegendRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct SessionButtons: View {
    let paused: Bool
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: WidgetPauseIntent()) {
                PillLabel(title: paused ? "Resume" : "Pause", prominent: false, palette: palette)
            }
            .buttonStyle(.plain)
            Button(intent: WidgetEndIntent()) {
                PillLabel(title: "End", prominent: false, palette: palette)
            }
            .buttonStyle(.plain)
        }
    }
}

struct BreakButtons: View {
    let canEnd: Bool
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: WidgetExtendBreakIntent()) {
                PillLabel(title: "+5 min", prominent: false, palette: palette)
            }
            .buttonStyle(.plain)
            if canEnd {
                Button(intent: WidgetEndBreakIntent()) {
                    PillLabel(title: "End", prominent: false, palette: palette)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End break")
            }
        }
    }
}

struct OpenAppNote: View {
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShieldMark(color: palette.focus, size: 14)
            Text("Open FocusGuard to see your day here.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
