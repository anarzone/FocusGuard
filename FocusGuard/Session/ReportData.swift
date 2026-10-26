import Foundation
import SwiftData

/// Reports' time span: a day, week, month or year, stepped back with an offset.
enum ReportPeriod: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year"

    var id: String { rawValue }

    var component: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        case .year:  return .year
        }
    }

    /// The span `offset` periods back from now (0 = the current one).
    func interval(offset: Int, now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let anchor = calendar.date(byAdding: component, value: -offset, to: now) ?? now
        return calendar.dateInterval(of: component, for: anchor) ?? DateInterval(start: anchor, duration: 86_400)
    }

    func title(for interval: DateInterval, calendar: Calendar = .current) -> String {
        let last = interval.end.addingTimeInterval(-1)
        switch self {
        case .day:
            return interval.start.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .week:
            let sameMonth = calendar.isDate(interval.start, equalTo: last, toGranularity: .month)
            let start = sameMonth
                ? interval.start.formatted(.dateTime.day())
                : interval.start.formatted(.dateTime.day().month(.wide))
            return "\(start) – \(last.formatted(.dateTime.day().month(.wide).year()))"
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        }
    }

    /// "vs last week", for comparisons.
    var previousLabel: String {
        switch self {
        case .day:   return "vs the day before"
        case .week:  return "vs last week"
        case .month: return "vs last month"
        case .year:  return "vs last year"
        }
    }
}

/// One bar of the Reports chart.
struct ReportBucket: Identifiable, Equatable {
    let id: Date
    let interval: DateInterval
    let label: String
    var focus: TimeInterval = 0
    var drift: TimeInterval = 0
    var other: TimeInterval = 0
    let isFuture: Bool
    /// Before the first day the plan's history reaches (Free keeps 30 days).
    var isLocked = false

    var total: TimeInterval { focus + drift + other }
}

struct ReportData {
    let interval: DateInterval
    let breakdown: BreakdownSnapshot
    let previous: BreakdownSnapshot
    /// Longest unbroken focus run inside sessions during the period.
    let longestZone: TimeInterval
    let sessionCount: Int
    let buckets: [ReportBucket]
    /// Daily goal line, when each bar is one day.
    let goalPerBucket: TimeInterval?
    /// Focused seconds by weekday (row 0 = the calendar's first weekday) and hour.
    let heat: [[TimeInterval]]
    let heatHours: ClosedRange<Int>
    let apps: [UsageRow]
    let distractions: [DistractionEntry]

    static let empty = ReportData(
        interval: DateInterval(start: .now, duration: 1), breakdown: .init(focus: 0, neutral: 0, distraction: 0),
        previous: .init(focus: 0, neutral: 0, distraction: 0), longestZone: 0, sessionCount: 0, buckets: [],
        goalPerBucket: nil, heat: Array(repeating: Array(repeating: 0, count: 24), count: 7), heatHours: 7...19,
        apps: [], distractions: []
    )
}

enum ReportDataBuilder {
    /// - Parameter notBefore: the first moment the plan's history reaches
    ///   (`Entitlements.historyStart`); nothing earlier is read or compared.
    /// `breakdown` gives the totals between two times, for the period
    /// before; `StatsStore` passes one that reads finished days from its
    /// kept totals.
    static func build(period: ReportPeriod, offset: Int, context: ModelContext,
                      now: Date = .now, calendar: Calendar = .current, notBefore: Date? = nil,
                      breakdown totals: ((Date, Date) -> BreakdownSnapshot)? = nil) -> ReportData {
        let interval = period.interval(offset: offset, now: now, calendar: calendar)
        let until = min(interval.end, now)
        let previousInterval = period.interval(offset: offset + 1, now: now, calendar: calendar)
        let floor = notBefore ?? .distantPast
        let start = min(max(interval.start, floor), interval.end)
        // Compare like with like: the same stretch of the previous period.
        let previousStart = previousInterval.start.addingTimeInterval(start.timeIntervalSince(interval.start))
        let previousUntil = min(previousInterval.start.addingTimeInterval(until.timeIntervalSince(interval.start)),
                                previousInterval.end)

        let reports = ReportBuilder(context: context)
        let previous = previousStart >= floor
            ? (totals ?? reports.breakdown)(previousStart, previousUntil)
            : BreakdownSnapshot(focus: 0, neutral: 0, distraction: 0)

        // One read of the period's events; the totals, apps and
        // distractions below all come from it.
        let end = interval.end
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let events = Persistence.fetch(context, descriptor)
        let breakdown = ReportBuilder.breakdown(events, from: start, to: until)

        var buckets = bucketIntervals(period: period, interval: interval, events: events, now: now, calendar: calendar)
        for index in buckets.indices where buckets[index].interval.end <= start {
            buckets[index].isLocked = true
        }
        var heat = Array(repeating: Array(repeating: TimeInterval(0), count: 24), count: 7)
        var firstHour = 7, lastHour = 19
        var hours = HourCursor(calendar: calendar)
        // Events come in start order, so the first bucket an event can touch
        // only moves forward.
        var firstBucket = 0

        for event in events {
            let kind = SessionTimeline.Kind(event.classification ?? .neutral)
            let s = max(event.startedAt, start)
            let e = min(event.endedAt.addingTimeInterval(1), end)
            guard e > s else { continue }

            while firstBucket < buckets.count, buckets[firstBucket].interval.end <= s { firstBucket += 1 }
            for index in buckets.indices.dropFirst(firstBucket) {
                let b = buckets[index].interval
                guard b.start < e else { break }
                let seconds = min(b.end, e).timeIntervalSince(max(b.start, s))
                switch kind {
                case .focus: buckets[index].focus += seconds
                case .drift: buckets[index].drift += seconds
                case .other: buckets[index].other += seconds
                }
            }

            // Heatmap: walk the event hour by hour.
            var cursor = s
            while cursor < e {
                let slot = hours.slot(at: cursor)
                let slice = min(slot.end, e).timeIntervalSince(cursor)
                firstHour = min(firstHour, slot.hour)
                lastHour = max(lastHour, slot.hour)
                if kind == .focus { heat[slot.row][slot.hour] += slice }
                cursor = slot.end
            }
        }

        let lo = firstHour
        let hi = lastHour

        let sessionEvents = events.filter { $0.session != nil }
        let longest = FocusRuns.compute(FocusRuns.spans(from: sessionEvents), now: now).longest
        let sessionStart = start
        let sessionCount = Persistence.fetchCount(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= sessionStart && $0.startedAt < end }
        ))

        let goal: TimeInterval? = (period == .week || period == .month) ? FocusGoal.dailySeconds : nil

        return ReportData(
            interval: interval,
            breakdown: breakdown,
            previous: previous,
            longestZone: longest,
            sessionCount: sessionCount,
            buckets: buckets,
            goalPerBucket: goal,
            heat: heat,
            heatHours: lo...hi,
            apps: MenuInsightsBuilder.usageRows(events: events, from: start, to: until, limit: 8),
            distractions: ReportBuilder.topDistractions(events, from: start, to: until, limit: 5)
        )
    }

    /// The same report added up from day summaries instead of read event by
    /// event: a few dozen sums rather than thousands of events. Nil where it
    /// can't be (not a week or a month, or not starting on a whole day);
    /// `build(period:offset:context:…)` reads the events then.
    /// `sessionEvents`, when the caller has them, covers every event inside
    /// a session in the period.
    static func build(period: ReportPeriod, offset: Int, days: DaySummaries, notBefore: Date? = nil,
                      sessionEvents known: [ActivityEvent]? = nil) -> ReportData? {
        guard period == .week || period == .month else { return nil }
        let context = days.context, now = days.now, calendar = days.calendar
        let interval = period.interval(offset: offset, now: now, calendar: calendar)
        let until = min(interval.end, now)
        let previousInterval = period.interval(offset: offset + 1, now: now, calendar: calendar)
        let floor = notBefore ?? .distantPast
        let start = min(max(interval.start, floor), interval.end)
        let previousStart = previousInterval.start.addingTimeInterval(start.timeIntervalSince(interval.start))
        let previousUntil = min(previousInterval.start.addingTimeInterval(until.timeIntervalSince(interval.start)),
                                previousInterval.end)
        guard let summaries = days.summaries(from: start, to: until) else { return nil }

        let previous = previousStart >= floor
            ? days.breakdown(from: previousStart, to: previousUntil)
            : BreakdownSnapshot(focus: 0, neutral: 0, distraction: 0)

        var buckets = bucketIntervals(period: period, interval: interval, events: [], now: now, calendar: calendar)
        for index in buckets.indices where buckets[index].interval.end <= start {
            buckets[index].isLocked = true
        }
        let byDay = Dictionary(summaries.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        for index in buckets.indices {
            guard let day = byDay[buckets[index].interval.start] else { continue }
            buckets[index].focus = day.bar.focus
            buckets[index].drift = day.bar.distraction
            buckets[index].other = day.bar.neutral
        }

        var total = ClassificationTally()
        var heat = Array(repeating: Array(repeating: TimeInterval(0), count: 24), count: 7)
        var firstHour = 7, lastHour = 19
        var apps: [String: ReportBuilder.AppGroup] = [:]
        var distractions: [String: ReportBuilder.DistractionGroup] = [:]
        for day in summaries {
            total.add(day.breakdown)
            let row = (calendar.component(.weekday, from: day.day) - calendar.firstWeekday + 7) % 7
            for hour in 0..<24 { heat[row][hour] += day.focusByHour[hour] }
            if let hours = day.hours {
                firstHour = min(firstHour, hours.lowerBound)
                lastHour = max(lastHour, hours.upperBound)
            }
            for (key, group) in day.apps {
                if apps[key] == nil { apps[key] = group } else { apps[key]?.add(group) }
            }
            for (key, group) in day.distractions {
                if distractions[key] == nil { distractions[key] = group } else { distractions[key]?.seconds += group.seconds }
            }
        }

        // The longest run needs the events themselves, but only the few
        // inside sessions.
        let end = interval.end
        let sessionEvents = known?.filter { $0.endedAt >= start && $0.startedAt < end }
            ?? Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { $0.endedAt >= start && $0.startedAt < end && $0.session != nil },
                sortBy: [SortDescriptor(\.startedAt)]
            ))
        let sessionCount = Persistence.fetchCount(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end }
        ))

        return ReportData(
            interval: interval,
            breakdown: BreakdownSnapshot(focus: total.focus, neutral: total.neutral, distraction: total.distraction),
            previous: previous,
            longestZone: FocusRuns.compute(FocusRuns.spans(from: sessionEvents), now: now).longest,
            sessionCount: sessionCount,
            buckets: buckets,
            goalPerBucket: FocusGoal.dailySeconds,
            heat: heat,
            heatHours: firstHour...lastHour,
            apps: MenuInsightsBuilder.usageRows(ReportBuilder.topApps(apps, limit: 40), limit: 8),
            distractions: ReportBuilder.topDistractions(distractions, limit: 5)
        )
    }

    /// Hours for a day (trimmed to when there was activity, at least 7–19),
    /// days for a week or month, months for a year.
    static func bucketIntervals(period: ReportPeriod, interval: DateInterval, events: [ActivityEvent],
                                now: Date, calendar: Calendar) -> [ReportBucket] {
        let unit: Calendar.Component
        var start = interval.start
        var end = interval.end
        switch period {
        case .day:
            unit = .hour
            let hours = events.map { calendar.component(.hour, from: max($0.startedAt, interval.start)) }
            let first = min(7, hours.min() ?? 7)
            let last = max(19, (hours.max() ?? 18) + 1)
            start = calendar.date(byAdding: .hour, value: first, to: interval.start) ?? start
            end = calendar.date(byAdding: .hour, value: min(24, last), to: interval.start) ?? end
        case .week, .month:
            unit = .day
        case .year:
            unit = .month
        }

        var out: [ReportBucket] = []
        var cursor = start
        while cursor < end {
            let next = calendar.date(byAdding: unit, value: 1, to: cursor) ?? end
            let label: String
            switch period {
            case .day:   label = cursor.formatted(.dateTime.hour())
            case .week:  label = cursor.formatted(.dateTime.weekday(.abbreviated))
            case .month: label = cursor.formatted(.dateTime.day())
            case .year:  label = cursor.formatted(.dateTime.month(.narrow))
            }
            out.append(ReportBucket(id: cursor, interval: DateInterval(start: cursor, end: next),
                                    label: label, isFuture: cursor > now))
            cursor = next
        }
        return out
    }
}

/// The calendar hour a moment falls in, with its heatmap row and column.
/// Remembers the last hour: events come in order and most fall in the same
/// hour as the one before, so the calendar maths runs once per hour rather
/// than once per event.
struct HourCursor {
    struct Slot {
        let start: Date
        let end: Date
        /// 0–23.
        let hour: Int
        /// Weekday, 0 = the calendar's first weekday.
        let row: Int
    }

    let calendar: Calendar
    private var last: Slot?

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    mutating func slot(at date: Date) -> Slot {
        if let last, date >= last.start, date < last.end { return last }
        let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        let slot = Slot(start: start, end: start.addingTimeInterval(3600),
                        hour: calendar.component(.hour, from: date),
                        row: (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7)
        last = slot
        return slot
    }
}
