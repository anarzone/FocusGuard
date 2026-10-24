import SwiftUI
import WidgetKit

/// The redesign's colours for widgets: indigo for focus, orange for drift
/// (never on small text: a dot or a mark, with a dark label beside it).
struct Palette {
    let scheme: ColorScheme

    var focus: Color { scheme == .dark ? Color(hex: 0x6D7CFF) : Color(hex: 0x6155F5) }
    var track: Color { scheme == .dark ? .white.opacity(0.10) : Color(hex: 0x6155F5).opacity(0.14) }
    var drift: Color { Color(hex: 0xDC7620) }
    var other: Color { scheme == .dark ? .white.opacity(0.34) : .black.opacity(0.22) }
    /// Quiet buttons ("Pause", "End", "25").
    var quiet: Color { scheme == .dark ? .white.opacity(0.13) : .black.opacity(0.07) }
    var goalLine: Color { scheme == .dark ? .white.opacity(0.30) : .black.opacity(0.22) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The shield from the app icon, as the header mark.
struct ShieldMark: View {
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: "shield.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

/// A plain progress ring: today against the goal, or a break.
struct ProgressRing: View {
    let progress: Double
    let palette: Palette
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(palette.focus, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(lineWidth / 2)
    }
}

/// The session ring the menu draws: one slice per cell, coloured by what
/// filled it, with small gaps where the kind changes.
struct SessionRing: View {
    let snapshot: SurfaceSnapshot
    let date: Date
    let palette: Palette
    var lineWidth: CGFloat = 10

    private struct Run { let kind: Character; let from: Int; let to: Int }

    /// The ring at `date`: cells since the snapshot was written count as
    /// in progress, since what filled them isn't known yet.
    private var cells: [Character] {
        var cells = Array(snapshot.session?.ring ?? "")
        guard !cells.isEmpty, let progress = snapshot.sessionProgress(at: date) else { return cells }
        let done = Int(progress * Double(cells.count))
        for i in 0..<min(done, cells.count) where cells[i] == "." { cells[i] = "n" }
        return cells
    }

    private var runs: [Run] {
        var runs: [Run] = []
        for (i, kind) in cells.enumerated() where kind != "." {
            if let last = runs.last, last.kind == kind, last.to == i {
                runs[runs.count - 1] = Run(kind: kind, from: last.from, to: i + 1)
            } else {
                runs.append(Run(kind: kind, from: i, to: i + 1))
            }
        }
        return runs
    }

    private func color(_ kind: Character) -> Color {
        switch kind {
        case "f": return palette.focus
        case "d": return palette.drift
        case "n": return palette.focus.opacity(0.55)
        default:  return palette.other
        }
    }

    var body: some View {
        let count = max(1, cells.count)
        let gap = 0.006
        ZStack {
            Circle().stroke(palette.track, lineWidth: lineWidth)
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                let from = Double(run.from) / Double(count) + (index > 0 ? gap : 0)
                let to = Double(run.to) / Double(count) - (index < runs.count - 1 ? gap : 0)
                if to > from {
                    Circle()
                        .trim(from: from, to: to)
                        .stroke(color(run.kind), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .padding(lineWidth / 2)
    }
}

/// Focus per day this week against the goal line. Days to come are drawn
/// as empty outlines at the goal's height.
struct WeekBars: View {
    let week: SurfaceSnapshot.Week
    let goal: TimeInterval
    let todayIndex: Int?
    let palette: Palette

    private var letters: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        let top = max(goal * 1.25, week.focused.max() ?? 0, 1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let height = geo.size.height
                ZStack(alignment: .bottom) {
                    if goal > 0 {
                        Path { path in
                            let y = height - height * goal / top
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(palette.goalLine, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(0..<7, id: \.self) { day in
                            bar(day, height: height, top: top)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { day in
                    Text(letters[day])
                        .font(.system(size: 10, weight: day == todayIndex ? .bold : .regular))
                        .foregroundStyle(day == todayIndex ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func bar(_ day: Int, height: CGFloat, top: TimeInterval) -> some View {
        let isFuture = todayIndex.map { day > $0 } ?? false
        if isFuture {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(palette.goalLine, lineWidth: 1)
                .frame(maxWidth: .infinity)
                .frame(height: max(4, height * goal / top))
        } else {
            let value = week.focused.indices.contains(day) ? week.focused[day] : 0
            RoundedRectangle(cornerRadius: 5)
                .fill(palette.focus.opacity(day == todayIndex && value < goal ? 0.6 : 1))
                .frame(maxWidth: .infinity)
                .frame(height: max(3, height * value / top))
                .widgetAccentable()
        }
    }

    private var accessibilityText: String {
        let calendar = Calendar.current
        let names = calendar.standaloneWeekdaySymbols
        let days = (0...(todayIndex ?? 6)).map { day -> String in
            let name = names[(calendar.firstWeekday - 1 + day) % 7]
            let value = week.focused.indices.contains(day) ? week.focused[day] : 0
            return "\(name) \(SurfaceWords.duration(value))"
        }
        return "Focus per day this week, against a \(SurfaceWords.duration(goal)) goal: " + days.joined(separator: ", ")
    }
}

/// The capsule buttons widgets use.
struct PillLabel: View {
    let title: String
    let prominent: Bool
    let palette: Palette
    var height: CGFloat = 30

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(prominent ? palette.focus : palette.quiet))
    }
}
