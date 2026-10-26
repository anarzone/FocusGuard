import Foundation
import SwiftData

/// One day's activity, added up once. The tracker writes an event every few
/// seconds, so a month is about 17,000 of them, and SwiftData takes about
/// 0.3 s just to read that many. Finished days don't change, so `StatsStore`
/// keeps their summaries and Reports and Apps & Sites add up a few dozen of
/// these instead of reading every event again.
///
/// Each figure is counted the way the report it feeds counts it, so a sum of
/// summaries matches reading the days' events directly.
struct DaySummary {
    let day: Date
    /// By classification, as `ReportBuilder.breakdown` counts.
    var breakdown = ClassificationTally()
    /// By classification, as the day's bar in Reports counts: each event
    /// runs a second past its end, like `ReportDataBuilder`.
    var bar = ClassificationTally()
    /// Focused seconds by hour, counted like `bar`, for the heatmap.
    var focusByHour = [TimeInterval](repeating: 0, count: 24)
    /// First and last hour with any activity.
    var hours: ClosedRange<Int>?
    var apps: [String: ReportBuilder.AppGroup] = [:]
    var distractions: [String: ReportBuilder.DistractionGroup] = [:]

    var dailyBreakdown: DailyBreakdown {
        DailyBreakdown(date: day, focus: breakdown.focus, neutral: breakdown.neutral, distraction: breakdown.distraction)
    }

    /// Summaries of `days` (each a start of day, in order) from one read of
    /// their events.
    static func make(days: [Date], context: ModelContext, calendar: Calendar = .current) -> [DaySummary] {
        guard let first = days.first, let last = days.last else { return [] }
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= first && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return make(days: days, events: Persistence.fetch(context, descriptor), calendar: calendar)
    }

    /// Summaries of `days` from their events, sorted by start.
    static func make(days: [Date], events: [ActivityEvent], calendar: Calendar = .current) -> [DaySummary] {
        let spans = days.map { day in
            DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400))
        }
        var summaries = days.map { DaySummary(day: $0) }
        var byDay = Array(repeating: [ActivityEvent](), count: days.count)
        var hourCursor = HourCursor(calendar: calendar)
        // Events come in start order, so the first day one can touch only
        // moves forward.
        var firstDay = 0

        for event in events {
            let barEnd = event.endedAt.addingTimeInterval(1)
            while firstDay < spans.count, spans[firstDay].end <= event.startedAt { firstDay += 1 }
            for index in spans.indices.dropFirst(firstDay) {
                let span = spans[index]
                guard span.start <= barEnd else { break }
                if event.endedAt >= span.start && event.startedAt < span.end { byDay[index].append(event) }

                let classification = event.classification ?? .neutral
                let seconds = max(0, min(event.endedAt, span.end).timeIntervalSince(max(event.startedAt, span.start)))
                summaries[index].breakdown.add(seconds, classification)

                // The bar and the heatmap, walked hour by hour.
                var cursor = max(event.startedAt, span.start)
                let end = min(barEnd, span.end)
                guard end > cursor else { continue }
                summaries[index].bar.add(end.timeIntervalSince(cursor), classification)
                while cursor < end {
                    let slot = hourCursor.slot(at: cursor)
                    let slice = min(slot.end, end).timeIntervalSince(cursor)
                    let hours = summaries[index].hours
                    summaries[index].hours = min(hours?.lowerBound ?? slot.hour, slot.hour)...max(hours?.upperBound ?? slot.hour, slot.hour)
                    if classification == .focus { summaries[index].focusByHour[slot.hour] += slice }
                    cursor = slot.end
                }
            }
        }

        var hosts = HostCache()
        for index in summaries.indices {
            let span = spans[index]
            summaries[index].apps = ReportBuilder.appGroups(byDay[index], from: span.start, to: span.end, hosts: &hosts)
            summaries[index].distractions = ReportBuilder.distractionGroups(byDay[index], from: span.start, to: span.end,
                                                                            hosts: &hosts)
        }
        return summaries
    }
}

/// Days a report adds up, as summaries: kept ones for finished days, and
/// today's, read fresh once per report.
final class DaySummaries {
    let context: ModelContext
    let now: Date
    let calendar: Calendar
    private let finished: ([Date]) -> [DaySummary]
    private var today: DaySummary?

    /// `finished` gives the kept summaries of whole days before today.
    init(context: ModelContext, now: Date, calendar: Calendar = .current, finished: @escaping ([Date]) -> [DaySummary]) {
        self.context = context
        self.now = now
        self.calendar = calendar
        self.finished = finished
    }

    var startOfToday: Date { calendar.startOfDay(for: now) }

    /// Starts of the days in `[from, to)`.
    func days(from: Date, to: Date) -> [Date] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: from)
        while cursor < to {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }
        return days
    }

    /// Summaries for `[from, to)`, or nil when that isn't whole days
    /// (today counts as whole up to now): those are read from events.
    func summaries(from: Date, to: Date) -> [DaySummary]? {
        guard calendar.startOfDay(for: from) == from, to > from else { return nil }
        let endsWithToday = to >= now && calendar.startOfDay(for: to.addingTimeInterval(-1)) == startOfToday
        guard endsWithToday || calendar.startOfDay(for: to) == to else { return nil }
        let past = days(from: from, to: min(to, startOfToday))
        var result = past.isEmpty ? [] : finished(past)
        if endsWithToday && from <= startOfToday {
            if today == nil { today = DaySummary.make(days: [startOfToday], context: context, calendar: calendar).first }
            if let today { result.append(today) }
        }
        return result
    }

    /// Totals of `[from, to)`: whole days from the summaries, the rest read
    /// from the store.
    func breakdown(from: Date, to: Date) -> BreakdownSnapshot {
        let reports = ReportBuilder(context: context)
        let firstWhole = calendar.startOfDay(for: from) == from ? from : (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from)) ?? from)
        let lastWhole = to >= now ? max(firstWhole, to) : calendar.startOfDay(for: to)
        guard firstWhole < lastWhole, let days = summaries(from: firstWhole, to: lastWhole) else {
            return reports.breakdown(from: from, to: to)
        }
        var tally = ClassificationTally()
        for day in days { tally.add(day.breakdown) }
        if from < firstWhole { tally.add(snapshot: reports.breakdown(from: from, to: firstWhole)) }
        if lastWhole < to { tally.add(snapshot: reports.breakdown(from: lastWhole, to: to)) }
        return BreakdownSnapshot(focus: tally.focus, neutral: tally.neutral, distraction: tally.distraction)
    }

    /// Distraction groups for `[from, to)`, whole days from the summaries.
    func distractions(from: Date, to: Date, limit: Int) -> [DistractionEntry] {
        let firstWhole = calendar.startOfDay(for: from) == from ? from : (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from)) ?? from)
        let lastWhole = to >= now ? max(firstWhole, to) : calendar.startOfDay(for: to)
        guard firstWhole < lastWhole, let days = summaries(from: firstWhole, to: lastWhole) else {
            return ReportBuilder(context: context).topDistractions(from: from, to: to, limit: limit)
        }
        var groups: [String: ReportBuilder.DistractionGroup] = [:]
        for day in days { merge(day.distractions, into: &groups) }
        var hosts = HostCache()
        for (start, end) in [(from, firstWhole), (lastWhole, to)] where start < end {
            merge(ReportBuilder.distractionGroups(events(from: start, to: end), from: start, to: end, hosts: &hosts),
                  into: &groups)
        }
        return ReportBuilder.topDistractions(groups, limit: limit)
    }

    private func events(from: Date, to: Date) -> [ActivityEvent] {
        Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to }
        ))
    }

    private func merge(_ new: [String: ReportBuilder.DistractionGroup], into groups: inout [String: ReportBuilder.DistractionGroup]) {
        for (key, group) in new {
            if groups[key] == nil { groups[key] = group } else { groups[key]?.seconds += group.seconds }
        }
    }
}

extension ClassificationTally {
    mutating func add(snapshot: BreakdownSnapshot) {
        focus += snapshot.focus
        neutral += snapshot.neutral
        distraction += snapshot.distraction
    }
}
