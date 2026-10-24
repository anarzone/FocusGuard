import SwiftUI

// MARK: - Day bars

/// Focus, drift and (optionally) other per day, stacked, with the daily
/// goal as a dashed line. Days still to come show as a dashed outline at
/// the goal; days the plan's history doesn't reach stay empty.
struct DayBarsChart: View {
    let buckets: [ReportBucket]
    let goal: TimeInterval
    var showOther = true
    /// Week: weekday names and totals under each bar. Month: a few day numbers.
    var weekLabels = true

    /// Room for the hour labels, and for a goal like "3h 45m".
    private var axisWidth: CGFloat { Int(goal) % 3600 == 0 ? 30 : 46 }

    private var scaleMax: TimeInterval {
        let tallest = buckets.map { showOther ? $0.total : $0.focus + $0.drift }.max() ?? 0
        return max(goal * 1.25, tallest * 1.05, 3600)
    }

    var body: some View {
        GeometryReader { geo in
            let labels: CGFloat = weekLabels ? 30 : 18
            let plot = max(20, geo.size.height - labels)
            let width = geo.size.width - axisWidth
            let slot = width / CGFloat(max(1, buckets.count))
            let barWidth = weekLabels ? min(34, slot * 0.5) : min(9, slot * 0.6)
            ZStack(alignment: .topLeading) {
                axis(plot: plot, width: width)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(buckets) { bucket in
                        column(bucket, plot: plot, barWidth: barWidth)
                            .frame(width: slot, height: plot, alignment: .bottom)
                    }
                }
                .offset(x: axisWidth)
                goalLine(plot: plot, width: width)
                labelsRow(slot: slot)
                    .offset(x: axisWidth, y: plot + 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private func y(_ seconds: TimeInterval, plot: CGFloat) -> CGFloat {
        CGFloat(seconds / scaleMax) * plot
    }

    private func axis(plot: CGFloat, width: CGFloat) -> some View {
        let step: TimeInterval = scaleMax > 6 * 3600 ? 3 * 3600 : 2 * 3600
        let marks = stride(from: 0, through: scaleMax, by: step).filter { abs($0 - goal) > 1800 }
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { mark in
                let py = plot - y(mark, plot: plot)
                Rectangle().fill(mark == 0 ? Theme.hairline : Theme.track).frame(width: width, height: 0.5)
                    .offset(x: axisWidth, y: py)
                Text("\(Int(mark / 3600))h")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .offset(y: py - 7)
            }
        }
    }

    private func goalLine(plot: CGFloat, width: CGFloat) -> some View {
        let py = plot - y(goal, plot: plot)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: axisWidth, y: py))
                p.addLine(to: CGPoint(x: axisWidth + width, y: py))
            }
            .stroke(Theme.primaryText, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Text(FocusGoal.format(minutes: Int(goal / 60)))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .offset(y: py - 7)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func column(_ bucket: ReportBucket, plot: CGFloat, barWidth: CGFloat) -> some View {
        if bucket.isFuture {
            if weekLabels {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.lockedStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: barWidth, height: y(goal, plot: plot))
            } else {
                RoundedRectangle(cornerRadius: 2).fill(Theme.track).frame(width: barWidth, height: 3)
            }
        } else if bucket.isLocked {
            Color.clear.frame(width: barWidth, height: 1)
        } else {
            VStack(spacing: 1) {
                if showOther && bucket.other > 0 {
                    Rectangle().fill(Theme.other).frame(height: y(bucket.other, plot: plot))
                }
                if bucket.drift > 0 {
                    Rectangle().fill(Theme.distraction).frame(height: y(bucket.drift, plot: plot))
                }
                Rectangle().fill(Theme.focus).frame(height: max(bucket.focus > 0 ? 1 : 0, y(bucket.focus, plot: plot)))
            }
            .frame(width: barWidth)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: weekLabels ? 4 : 2, topTrailingRadius: weekLabels ? 4 : 2))
            .help(tooltip(bucket))
        }
    }

    private func labelsRow(slot: CGFloat) -> some View {
        let calendar = Calendar.current
        let todayIndex = buckets.firstIndex { calendar.isDateInToday($0.interval.start) }
        return HStack(spacing: 0) {
            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                let isToday = index == todayIndex
                VStack(spacing: 1) {
                    if weekLabels {
                        Text(isToday ? "Today" : bucket.label)
                            .font(.system(size: 11, weight: isToday ? .bold : .regular))
                            .foregroundStyle(bucket.isFuture ? Theme.tertiaryText : Theme.primaryText)
                        Text(bucket.isFuture || bucket.isLocked ? " " : WindowFormat.hm(bucket.focus))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        let day = calendar.component(.day, from: bucket.interval.start)
                        let shown = isToday || [1, 7, 14, 21, 28].contains(day)
                        Text(shown ? "\(day)" : " ")
                            .font(.system(size: 10, weight: isToday ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(isToday ? Theme.primaryText : Theme.tertiaryText)
                            .fixedSize()
                    }
                }
                .frame(width: slot)
            }
        }
    }

    private func tooltip(_ bucket: ReportBucket) -> String {
        let day = bucket.interval.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        var parts = ["\(day): \(WindowFormat.hm(bucket.focus)) focused", "\(WindowFormat.hm(bucket.drift)) drifted"]
        if bucket.focus + bucket.drift >= 60 {
            parts.append("\(Int((bucket.focusRate * 100).rounded()))% focus rate")
        }
        return parts.joined(separator: " · ")
    }

    private var summary: String {
        let shown = buckets.filter { !$0.isFuture && !$0.isLocked }
        guard !shown.isEmpty else { return "No days to show yet." }
        let list = shown.map { "\($0.interval.start.formatted(.dateTime.weekday(.wide).day())) \(WindowFormat.hm($0.focus))" }
        return "Focused time per day against a \(FocusGoal.format(minutes: Int(goal / 60))) goal: " + list.joined(separator: ", ")
    }
}

// MARK: - Heat grid

/// Focus by weekday and hour, 08–19, in five shades.
struct HeatGrid: View {
    let heat: [[TimeInterval]]
    var hours: ClosedRange<Int> = ReportsModelBuilder.hours

    static let levels: [Double] = [0.07, 0.24, 0.46, 0.72, 1]

    var body: some View {
        let peak = max(1, heat.flatMap { $0 }.max() ?? 1)
        let names = weekdayNames
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: 3) {
                    Text(names[row]).font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, alignment: .leading)
                    ForEach(Array(hours), id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.focus.opacity(Self.level(heat[row][hour], peak: peak)))
                            .frame(height: 16)
                            .frame(maxWidth: 22)
                            .help("\(names[row]) \(String(format: "%02d:00", hour)): \(WindowFormat.hm(heat[row][hour])) focused")
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 31)
                ForEach(Array(stride(from: hours.lowerBound, through: hours.upperBound, by: 2)), id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(names))
    }

    static func level(_ value: TimeInterval, peak: TimeInterval) -> Double {
        guard value > 0 else { return levels[0] }
        let ratio = value / peak
        switch ratio {
        case ..<0.15: return levels[0]
        case ..<0.4: return levels[1]
        case ..<0.65: return levels[2]
        case ..<0.9: return levels[3]
        default: return levels[4]
        }
    }

    private var weekdayNames: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private func summary(_ names: [String]) -> String {
        guard let stretch = ReportsModelBuilder.bestStretch(heat, length: 3) else { return "No focus to show yet." }
        return "Focus by hour and weekday. Strongest from \(String(format: "%02d:00", stretch.start)) to \(String(format: "%02d:00", stretch.start + 3))."
    }
}

/// Less ▢▢▢▢▢ More.
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less").padding(.trailing, 2)
            ForEach(HeatGrid.levels, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3).fill(Theme.focus.opacity(level)).frame(width: 12, height: 10)
            }
            Text("More").padding(.leading, 2)
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.secondaryText)
        .accessibilityHidden(true)
    }
}

// MARK: - Trend

/// Focus per week, this week in full indigo.
struct TrendBars: View {
    let weeks: [WeekTotal]

    var body: some View {
        GeometryReader { geo in
            let plot = geo.size.height - 16
            let peak = max(3600, weeks.map(\.focus).max() ?? 1) * 1.15
            let slot = geo.size.width / CGFloat(max(1, weeks.count))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).offset(y: plot)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(weeks) { week in
                        VStack(spacing: 3) {
                            if week.isCurrent {
                                Text(String(format: "%.1fh", week.focus / 3600))
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.primaryText)
                                    .fixedSize()
                            }
                            RoundedRectangle(cornerRadius: 3)
                                .fill(week.isCurrent ? Theme.focus : Theme.focusSoft)
                                .frame(width: min(22, slot * 0.66), height: max(1, CGFloat(week.focus / peak) * plot))
                        }
                        .frame(width: slot, height: plot, alignment: .bottom)
                        .help("Week of \(week.start.formatted(.dateTime.day().month(.abbreviated))): \(WindowFormat.hm(week.focus))")
                    }
                }
                HStack {
                    if let first = weeks.first { Text(first.start.formatted(.dateTime.day().month(.abbreviated))) }
                    Spacer()
                    if weeks.count > 4 { Text(weeks[weeks.count / 2].start.formatted(.dateTime.day().month(.abbreviated))) }
                    Spacer()
                    Text("This week")
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .offset(y: plot + 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focused hours per week for the last \(weeks.count) weeks: " +
                            weeks.map { WindowFormat.hm($0.focus) }.joined(separator: ", "))
    }

    /// "Up from about 14 hours a week in early September."
    static func caption(_ weeks: [WeekTotal]) -> String? {
        guard weeks.count >= 3, let current = weeks.last else { return nil }
        let early = weeks.prefix(2)
        let before = early.map(\.focus).reduce(0, +) / Double(early.count)
        guard before >= 1800 else { return nil }
        let hours = Int((before / 3600).rounded())
        let month = early.first.map { $0.start.formatted(.dateTime.month(.wide)) } ?? ""
        let change = (current.focus - before) / before
        if change >= 0.1 { return "Up from about \(hours) hours a week in early \(month)." }
        if change <= -0.1 { return "Down from about \(hours) hours a week in early \(month)." }
        return "About the same as early \(month), around \(hours) hours a week."
    }
}

// MARK: - Hours (month)

/// Average focus per hour of the day; the strongest hours in full indigo.
struct HourBars: View {
    let averages: [TimeInterval]
    var hours: ClosedRange<Int> = ReportsModelBuilder.hours

    var body: some View {
        GeometryReader { geo in
            let plot = geo.size.height - 16
            let values = Array(hours).map { averages[$0] }
            let peak = max(60, values.max() ?? 1)
            let slot = geo.size.width / CGFloat(values.count)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).offset(y: plot)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(hours), id: \.self) { hour in
                        let value = averages[hour]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(value >= peak * 0.9 ? Theme.focus : Theme.focusSoft)
                            .frame(width: slot * 0.72, height: max(1, CGFloat(value / (peak * 1.1)) * plot))
                            .frame(width: slot, height: plot, alignment: .bottom)
                            .help("\(String(format: "%02d:00", hour)): \(Int(value / 60)) min focused on average")
                    }
                }
                HStack(spacing: 0) {
                    ForEach(Array(hours), id: \.self) { hour in
                        Text([8, 12, 16, 19].contains(hour) ? String(format: "%02d", hour) : " ")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                            .fixedSize()
                            .frame(width: slot)
                    }
                }
                .offset(y: plot + 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption(averages) ?? "No focus to show yet.")
    }

    /// "10:00 to 12:00 is your strongest stretch. Protect it."
    func caption(_ averages: [TimeInterval]) -> String? {
        Self.caption(averages)
    }

    static func caption(_ averages: [TimeInterval]) -> String? {
        guard averages.reduce(0, +) >= 600 else { return nil }
        var best = (start: 0, value: TimeInterval(0))
        for start in 0..<23 where averages[start] + averages[start + 1] > best.value {
            best = (start, averages[start] + averages[start + 1])
        }
        return "\(String(format: "%02d:00", best.start)) to \(String(format: "%02d:00", best.start + 2)) is your strongest stretch. Protect it."
    }
}

// MARK: - Month calendar

/// The month as small goal rings, one per day.
struct MonthCalendarGrid: View {
    let weeks: [[CalendarDay]]
    let goal: TimeInterval

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[(calendar.firstWeekday - 1 + i) % 7])
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 4) {
                    ForEach(week) { cell in
                        dayCell(cell)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    @ViewBuilder
    private func dayCell(_ cell: CalendarDay) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let day = cell.day {
            HStack(spacing: 4) {
                Text("\(day)")
                    .font(.system(size: 10, weight: cell.isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(Theme.bodyText)
                    .frame(width: 14, alignment: .trailing)
                ZStack {
                    Circle().inset(by: 1.25).stroke(Theme.track, lineWidth: 2.5)
                    if cell.focus > 0 && !cell.isLocked {
                        WindowArc(start: 0, end: min(0.9999, cell.focus / max(1, goal)))
                            .inset(1.25)
                            .stroke(Theme.focus, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                }
                .frame(width: 14, height: 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(shape.fill(cell.isToday ? Theme.focus.opacity(0.06) : Theme.inset))
            .overlay(shape.strokeBorder(cell.isToday ? Theme.focus : .clear, lineWidth: 1.5))
            .opacity(cell.isFuture || cell.isLocked ? 0.45 : 1)
            .help(cell.isFuture ? "" : "\(cell.date?.formatted(.dateTime.weekday(.wide).day()) ?? ""): \(WindowFormat.hm(cell.focus)) focused")
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 28)
        }
    }

    private var summary: String {
        let days = weeks.flatMap { $0 }.filter { $0.day != nil && !$0.isFuture && !$0.isLocked }
        let met = days.filter { $0.focus >= goal }.count
        return "Calendar: goal met on \(met) of \(days.count) days so far."
    }
}

// MARK: - Lists

/// A distraction row: icon, name over an orange bar, time and change.
struct WindowDistractionRow: View {
    let item: ReportDistraction
    let fraction: Double
    var timeWidth: CGFloat = 34

    var body: some View {
        HStack(spacing: 8) {
            WindowItemIcon(name: item.name, bundleId: item.bundleId, host: item.host, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                WindowBar(fraction: fraction, color: Theme.distraction, height: 4)
            }
            Text(WindowFormat.hm(item.seconds))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .fixedSize()
                .frame(minWidth: timeWidth, alignment: .trailing)
            if item.comparable {
                Text(WindowFormat.minutesChange(item.seconds, item.before))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                    .frame(minWidth: 38, alignment: .trailing)
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }
}

/// "How sessions went": how many sessions earned each pattern.
struct PatternBars: View {
    let patterns: [(pattern: SessionNamer.Pattern, count: Int)]

    var body: some View {
        let peak = max(1, patterns.map(\.count).max() ?? 1)
        VStack(spacing: 6) {
            ForEach(patterns, id: \.pattern) { item in
                HStack(spacing: 8) {
                    Text(item.pattern.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .frame(width: 74, alignment: .leading)
                    WindowBar(fraction: Double(item.count) / Double(peak), color: Self.color(item.pattern), height: 8)
                    Text("\(item.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 22, alignment: .trailing)
                }
                .frame(height: 20)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Strong patterns in full indigo, mixed ones lighter, weak ones lightest.
    static func color(_ pattern: SessionNamer.Pattern) -> Color {
        switch pattern {
        case .lockedIn, .steady: return Theme.focus
        case .comeback, .bumpy, .slowStart: return Theme.focus.opacity(0.68)
        case .fading, .wandering, .quiet: return Theme.focusSoft
        }
    }
}
