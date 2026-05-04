import SwiftUI
import Charts

/// 7 daily bars where each bar is a focus/neutral/distraction stack. Used in
/// the popover and Home view in place of the previous "two charts stacked"
/// design that was easy to misread as one chart.
///
/// Day labels are derived from each row's date so the rightmost bar is
/// always today, no matter what weekday today is. Today's segment label
/// is bolded.
struct WeekStackedChart: View {
    let breakdowns: [DailyBreakdown]

    private struct Slice: Identifiable {
        let id = UUID()
        /// Date string used as the categorical x value so Charts allocates
        /// one slot per day and stacks slices that share a date.
        let dayKey: String
        let day: String        // single-letter weekday for the axis label
        let category: String   // "Focus" / "Neutral" / "Distraction"
        let seconds: Double
        let isToday: Bool
    }

    private static let weekdayLetters: [Int: String] = [
        1: "S", 2: "M", 3: "T", 4: "W", 5: "T", 6: "F", 7: "S",
    ]

    private var slices: [Slice] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var out: [Slice] = []
        for b in breakdowns {
            let weekday = calendar.component(.weekday, from: b.date)
            let letter = Self.weekdayLetters[weekday] ?? ""
            let key = String(format: "%.0f", b.date.timeIntervalSince1970)
            let isToday = calendar.isDate(b.date, inSameDayAs: today)
            // Order = bottom-to-top stack order.
            if b.focus > 0       { out.append(Slice(dayKey: key, day: letter, category: "Focus",       seconds: b.focus,       isToday: isToday)) }
            if b.neutral > 0     { out.append(Slice(dayKey: key, day: letter, category: "Neutral",     seconds: b.neutral,     isToday: isToday)) }
            if b.distraction > 0 { out.append(Slice(dayKey: key, day: letter, category: "Distraction", seconds: b.distraction, isToday: isToday)) }
        }
        return out
    }

    /// All day keys in order — used as the X domain so empty days still take
    /// a slot.
    private var allDayKeys: [String] {
        breakdowns.map { String(format: "%.0f", $0.date.timeIntervalSince1970) }
    }

    /// Map dayKey → display label so AxisValueLabel can resolve back.
    private var labelFor: [String: (text: String, isToday: Bool)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return Dictionary(uniqueKeysWithValues: breakdowns.map { b in
            let weekday = calendar.component(.weekday, from: b.date)
            let letter = Self.weekdayLetters[weekday] ?? ""
            let key = String(format: "%.0f", b.date.timeIntervalSince1970)
            let isToday = calendar.isDate(b.date, inSameDayAs: today)
            return (key, (letter, isToday))
        })
    }

    /// dayKey of today, if today is in the rendered window. Used to position
    /// the "Today" highlight band.
    private var todayKey: String? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let row = breakdowns.first(where: { calendar.isDate($0.date, inSameDayAs: today) }) else {
            return nil
        }
        return String(format: "%.0f", row.date.timeIntervalSince1970)
    }

    var body: some View {
        Chart(slices) { s in
            BarMark(
                x: .value("Day", s.dayKey),
                y: .value("Seconds", s.seconds),
                width: .ratio(0.62)
            )
            .foregroundStyle(by: .value("Category", s.category))
            .cornerRadius(2)
        }
        .chartForegroundStyleScale([
            "Focus":       Theme.focus,
            "Neutral":     Theme.neutral.opacity(0.55),
            "Distraction": Theme.distraction,
        ])
        .chartXScale(domain: allDayKeys)
        .chartBackground { proxy in
            // Soft band behind today's column — separates "today" from the
            // last-six-days history without changing the bar colors.
            GeometryReader { geo in
                if let key = todayKey,
                   let plot = proxy.plotFrame.map({ geo[$0] }),
                   let xPos: CGFloat = proxy.position(forX: key) {
                    let bandWidth: CGFloat = max(20, plot.width / CGFloat(max(1, allDayKeys.count)) - 4)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.focus.opacity(0.10))
                        .frame(width: bandWidth, height: plot.height)
                        .position(x: plot.minX + xPos, y: plot.midY)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: allDayKeys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self),
                       let entry = labelFor[key] {
                        VStack(spacing: 1) {
                            Text(entry.text)
                                .font(.system(size: 9.5, weight: entry.isToday ? .semibold : .regular))
                                .foregroundStyle(entry.isToday ? Color.primary : .secondary)
                            if entry.isToday {
                                Text("Today")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(Theme.focus)
                            }
                        }
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}
