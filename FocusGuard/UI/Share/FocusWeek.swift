import Foundation
import SwiftData

/// One week's numbers for the share image. Nothing in it says what the
/// user worked on unless they ask: session names are the automatic ones
/// only, and apps and sites are shown only behind their own switch.
struct FocusWeek: Equatable {
    struct Day: Equatable {
        let date: Date
        let focus: TimeInterval
        let isWeekend: Bool
    }

    struct NameCount: Equatable {
        let name: String
        let count: Int
    }

    let interval: DateInterval
    /// The seven days, in the calendar's order.
    let days: [Day]
    let focus: TimeInterval
    let drift: TimeInterval
    /// Longest unbroken focus inside sessions.
    let longestZone: TimeInterval
    let sessions: Int
    let goalMinutes: Int
    /// Automatic session names, most used first. Never the user's own
    /// labels, which could say what the work was.
    let names: [NameCount]
    /// The apps and sites with the most focused time.
    let places: [String]

    var focusPercent: Int { FocusRate.percent(focused: focus, drifted: drift) }
    var goalDays: Int { days.filter { $0.focus >= TimeInterval(goalMinutes * 60) }.count }

    static func build(weekOf date: Date, context: ModelContext, now: Date = .now,
                      calendar: Calendar = .current) -> FocusWeek {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)
        let start = interval.start, end = interval.end
        let breakdowns = ReportBuilder(context: context).dailyBreakdowns(from: start, to: end, calendar: calendar)
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= start && $0.startedAt < end }
        ))
        let sessions = Persistence.fetch(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end }
        ))
        return FocusWeek(
            interval: interval,
            days: breakdowns.map { Day(date: $0.date, focus: $0.focus, isWeekend: calendar.isDateInWeekend($0.date)) },
            focus: breakdowns.reduce(0) { $0 + $1.focus },
            drift: breakdowns.reduce(0) { $0 + $1.distraction },
            longestZone: FocusRuns.compute(FocusRuns.spans(from: events.filter { $0.session != nil }), now: now).longest,
            sessions: sessions.count,
            goalMinutes: FocusGoal.dailyMinutes,
            names: names(sessions.compactMap(\.autoName)),
            places: places(events, in: interval)
        )
    }

    /// The three most used names: "Steady Sprint ×11".
    static func names(_ names: [String], limit: Int = 3) -> [NameCount] {
        Dictionary(grouping: names, by: { $0 })
            .map { NameCount(name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }

    /// The three sites (by host) or apps with the most focused time.
    static func places(_ events: [ActivityEvent], in interval: DateInterval, limit: Int = 3) -> [String] {
        var seconds: [String: TimeInterval] = [:]
        for event in events where event.classification == .focus {
            let name = BlockRequest.displayHost(event.url) ?? event.appName
            let overlap = min(event.endedAt, interval.end).timeIntervalSince(max(event.startedAt, interval.start))
            seconds[name, default: 0] += max(0, overlap)
        }
        return seconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    // MARK: - Words

    /// "12–18 Oct", or "28 Sep – 4 Oct" across months.
    func rangeLabel(wideMonth: Bool = false, calendar: Calendar = .current) -> String {
        let last = interval.end.addingTimeInterval(-1)
        let month: (Date) -> String = { date in
            date.formatted(.dateTime.month(wideMonth ? .wide : .abbreviated))
        }
        let first = calendar.component(.day, from: interval.start), lastDay = calendar.component(.day, from: last)
        if calendar.isDate(interval.start, equalTo: last, toGranularity: .month) {
            return "\(first)–\(lastDay) \(month(last))"
        }
        return "\(first) \(month(interval.start)) – \(lastDay) \(month(last))"
    }

    /// "21h 35m", "45m".
    static func duration(_ seconds: TimeInterval) -> String {
        FocusGoal.format(minutes: Int(seconds / 60))
    }

    /// "1 day", "23 sessions".
    static func counted(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
