import Foundation
import SwiftData

/// A distraction in Reports, with its time in the period before.
struct ReportDistraction: Identifiable, Equatable {
    var id: String { host ?? bundleId }
    let name: String
    let bundleId: String
    let host: String?
    let seconds: TimeInterval
    /// Nil when it didn't show up before ("new").
    let before: TimeInterval?
    /// False when the period before is out of the plan's history.
    var comparable = true
}

/// One week's focus, for the trend.
struct WeekTotal: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let focus: TimeInterval
    let isCurrent: Bool
}

/// One day of the month calendar. `day` is nil for padding cells.
struct CalendarDay: Identifiable, Equatable {
    let id: Int
    let date: Date?
    let focus: TimeInterval
    let isToday: Bool
    let isFuture: Bool
    let isLocked: Bool

    var day: Int? { date.map { Calendar.current.component(.day, from: $0) } }
}

/// A line in "Highlights", with the colour of its dot.
struct ReportHighlight: Equatable {
    let kind: SessionTimeline.Kind
    let text: String
}

/// Everything Reports shows for a week or a month.
struct ReportsModel {
    let period: ReportPeriod
    let data: ReportData
    /// Where the plan's history starts, if the period begins before it.
    let clippedAt: Date?
    let longestZoneDay: Date?
    let distractions: [ReportDistraction]
    /// Week: focus by weekday × hour over the last four weeks.
    let heat: [[TimeInterval]]
    let heatWeeks: Int
    /// Month: average focus per hour of the day, over days with activity.
    let hourAverages: [TimeInterval]
    let trend: [WeekTotal]
    /// Month: sessions by how they went, most first.
    let patterns: [(pattern: SessionNamer.Pattern, count: Int)]
    let patternNote: String?
    let highlights: [ReportHighlight]
    let goal: GoalDays
    let calendar: [[CalendarDay]]
    /// "your best week in two months".
    let bestWeekNote: String?

    var totalSessions: Int { patterns.reduce(0) { $0 + $1.count } }

    static let empty = ReportsModel(
        period: .week, data: .empty, clippedAt: nil, longestZoneDay: nil, distractions: [],
        heat: Array(repeating: Array(repeating: 0, count: 24), count: 7), heatWeeks: 4,
        hourAverages: Array(repeating: 0, count: 24), trend: [], patterns: [], patternNote: nil,
        highlights: [], goal: GoalDays(met: 0, counted: 0, misses: []), calendar: [], bestWeekNote: nil
    )
}

/// Days the goal was met, among the days that count (weekdays unless
/// weekends count; today only once it's met).
struct GoalDays: Equatable {
    let met: Int
    let counted: Int
    let misses: [Date]
}

@MainActor
enum ReportsModelBuilder {
    /// Hours the hour charts cover.
    static let hours = 8...19

    static func build(period: ReportPeriod, offset: Int, context: ModelContext, now: Date = .now,
                      calendar: Calendar = .current, historyStart: Date? = nil,
                      weekendsCount: Bool = false, goal: TimeInterval = FocusGoal.dailySeconds) -> ReportsModel {
        let data = ReportDataBuilder.build(period: period, offset: offset, context: context, now: now,
                                           calendar: calendar, notBefore: historyStart)
        let interval = data.interval
        let start = max(interval.start, historyStart ?? .distantPast)
        let until = min(interval.end, now)
        let reports = ReportBuilder(context: context)

        // Sessions in the period: the longest run's day, and how they went.
        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < until },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let sessions = Persistence.fetch(context, sessionDescriptor).filter { $0.endedAt != nil }
        var longestDay: Date?
        var longest: TimeInterval = 0
        var tally: [SessionNamer.Pattern: Int] = [:]
        var fadingStarts: [Date] = []
        for session in sessions {
            let run = FocusRuns.compute(FocusRuns.spans(from: session.events), now: now).longest
            if run > longest { longest = run; longestDay = session.startedAt }
            let pattern = pattern(of: session)
            tally[pattern, default: 0] += 1
            if pattern == .fading { fadingStarts.append(session.startedAt) }
        }
        let patterns = SessionNamer.Pattern.allCases
            .compactMap { p in tally[p].map { (pattern: p, count: $0) } }
            .sorted { $0.count > $1.count }

        // Distractions against the same stretch of the period before.
        let previous = period.interval(offset: offset + 1, now: now, calendar: calendar)
        let previousStart = previous.start.addingTimeInterval(start.timeIntervalSince(interval.start))
        let previousUntil = min(previous.end, previous.start.addingTimeInterval(until.timeIntervalSince(interval.start)))
        let canCompare = previousStart >= (historyStart ?? .distantPast)
        let before: [String: TimeInterval] = canCompare
            ? Dictionary(reports.topDistractions(from: previousStart, to: previousUntil, limit: 60)
                .map { ($0.host ?? $0.bundleId, $0.seconds) }, uniquingKeysWith: +)
            : [:]
        let distractions = data.distractions.map { entry in
            ReportDistraction(name: entry.name, bundleId: entry.bundleId, host: entry.host, seconds: entry.seconds,
                              before: canCompare ? before[entry.host ?? entry.bundleId] : nil,
                              comparable: canCompare)
        }

        let days = data.buckets.filter { !$0.isLocked }
        let goalDays = goalDays(days, now: now, calendar: calendar, weekendsCount: weekendsCount, goal: goal)

        var heat = data.heat
        var heatWeeks = 1
        var hourAverages = Array(repeating: TimeInterval(0), count: 24)
        var trend: [WeekTotal] = []
        var bestNote: String?
        var calendarGrid: [[CalendarDay]] = []

        switch period {
        case .week:
            let heatStart = max(calendar.date(byAdding: .day, value: -21, to: interval.start) ?? interval.start,
                                historyStart ?? .distantPast)
            heat = focusHeat(context: context, from: heatStart, to: until, calendar: calendar)
            heatWeeks = max(1, Int((until.timeIntervalSince(heatStart) / (7 * 86_400)).rounded(.up)))
            trend = weekTrend(reports: reports, endingWith: interval, weeks: 8, now: now,
                              calendar: calendar, historyStart: historyStart)
            bestNote = bestWeekNote(trend)
        case .month:
            let active = days.filter { $0.focus + $0.drift + $0.other > 60 }.count
            if active > 0 {
                hourAverages = (0..<24).map { hour in
                    data.heat.reduce(0) { $0 + $1[hour] } / Double(active)
                }
            }
            calendarGrid = monthGrid(interval: interval, buckets: data.buckets, now: now, calendar: calendar)
        default:
            break
        }

        let model = ReportsModel(
            period: period,
            data: data,
            clippedAt: historyStart.flatMap { $0 > interval.start ? $0 : nil },
            longestZoneDay: longestDay,
            distractions: distractions,
            heat: heat,
            heatWeeks: heatWeeks,
            hourAverages: hourAverages,
            trend: trend,
            patterns: patterns,
            patternNote: patternNote(patterns: patterns, fadingStarts: fadingStarts, calendar: calendar),
            highlights: [],
            goal: goalDays,
            calendar: calendarGrid,
            bestWeekNote: bestNote
        )
        return model.with(highlights: highlights(model, goal: goal, calendar: calendar))
    }

    /// The session's pattern: from the name it earned, else worked out again.
    static func pattern(of session: Session) -> SessionNamer.Pattern {
        if let name = session.autoName,
           let match = SessionNamer.Pattern.allCases.first(where: { name.hasPrefix($0.rawValue + " ") }) {
            return match
        }
        return SessionNamer.pattern(of: SessionTimeline.segments(from: session.events))
    }

    /// Focus by weekday (row 0 = the calendar's first weekday) and hour.
    static func focusHeat(context: ModelContext, from: Date, to: Date, calendar: Calendar) -> [[TimeInterval]] {
        var heat = Array(repeating: Array(repeating: TimeInterval(0), count: 24), count: 7)
        guard to > from else { return heat }
        let focusRaw = Classification.focus.rawValue
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to && $0.classificationRaw == focusRaw }
        )
        for event in Persistence.fetch(context, descriptor) {
            var cursor = max(event.startedAt, from)
            let end = min(event.endedAt.addingTimeInterval(1), to)
            while cursor < end {
                let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
                let slice = min(hourStart.addingTimeInterval(3600), end).timeIntervalSince(cursor)
                let row = (calendar.component(.weekday, from: cursor) - calendar.firstWeekday + 7) % 7
                heat[row][calendar.component(.hour, from: cursor)] += slice
                cursor = hourStart.addingTimeInterval(3600)
            }
        }
        return heat
    }

    /// Focus per week for `weeks` weeks ending with `interval`. Weeks the
    /// plan's history doesn't reach are left out.
    static func weekTrend(reports: ReportBuilder, endingWith interval: DateInterval, weeks: Int, now: Date,
                          calendar: Calendar, historyStart: Date?) -> [WeekTotal] {
        (0..<weeks).reversed().compactMap { back -> WeekTotal? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: interval.start),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            if let historyStart, end <= historyStart { return nil }
            let from = max(start, historyStart ?? .distantPast)
            return WeekTotal(start: start, focus: reports.breakdown(from: from, to: min(end, now)).focus, isCurrent: back == 0)
        }
    }

    /// "your best week in two months" when this week tops at least the
    /// three before it.
    static func bestWeekNote(_ trend: [WeekTotal]) -> String? {
        guard let current = trend.last, current.focus >= 3600 else { return nil }
        let earlier = trend.dropLast()
        var beaten = 0
        for week in earlier.reversed() {
            guard current.focus > week.focus else { break }
            beaten += 1
        }
        guard beaten >= 3 else { return nil }
        if beaten == earlier.count && beaten >= 7 { return "your best week in two months" }
        return "your best week in \(beaten + 1) weeks"
    }

    static func goalDays(_ days: [ReportBucket], now: Date, calendar: Calendar, weekendsCount: Bool,
                         goal: TimeInterval) -> GoalDays {
        var met = 0, counted = 0
        var misses: [Date] = []
        let today = calendar.startOfDay(for: now)
        for day in days where !day.isFuture {
            let date = day.interval.start
            let weekday = calendar.component(.weekday, from: date)
            if !weekendsCount && (weekday == 1 || weekday == 7) { continue }
            let isToday = calendar.isDate(date, inSameDayAs: today)
            if day.focus >= goal {
                met += 1
                counted += 1
            } else if !isToday {
                counted += 1
                misses.append(date)
            }
        }
        return GoalDays(met: met, counted: counted, misses: misses)
    }

    /// Weeks of the month, the calendar's first weekday first; padding
    /// cells have no date.
    static func monthGrid(interval: DateInterval, buckets: [ReportBucket], now: Date, calendar: Calendar) -> [[CalendarDay]] {
        let lead = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var cells: [CalendarDay] = (0..<lead).map {
            CalendarDay(id: -1 - $0, date: nil, focus: 0, isToday: false, isFuture: false, isLocked: false)
        }
        for (index, bucket) in buckets.enumerated() {
            cells.append(CalendarDay(id: index, date: bucket.interval.start, focus: bucket.focus,
                                     isToday: calendar.isDate(bucket.interval.start, inSameDayAs: now),
                                     isFuture: bucket.isFuture, isLocked: bucket.isLocked))
        }
        while cells.count % 7 != 0 {
            cells.append(CalendarDay(id: 1000 + cells.count, date: nil, focus: 0, isToday: false, isFuture: false, isLocked: false))
        }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    /// "Fading sessions mostly start after 16:00." when that's so.
    static func patternNote(patterns: [(pattern: SessionNamer.Pattern, count: Int)], fadingStarts: [Date],
                            calendar: Calendar) -> String? {
        if fadingStarts.count >= 2 {
            let late = fadingStarts.filter { calendar.component(.hour, from: $0) >= 16 }.count
            if late * 2 > fadingStarts.count { return "Fading sessions mostly start after 16:00." }
        }
        guard let top = patterns.first, top.count >= 2 else { return nil }
        return "Most sessions went \(top.pattern.rawValue.lowercased())."
    }

    // MARK: - Highlights

    static func highlights(_ model: ReportsModel, goal: TimeInterval, calendar: Calendar) -> [ReportHighlight] {
        var out: [ReportHighlight] = []
        let data = model.data
        guard data.breakdown.focus >= 600 else { return out }

        if let stretch = bestStretch(data.heat, length: 3) {
            let share = Int((stretch.share * 100).rounded())
            let part = stretch.start < 12 ? "Mornings" : (stretch.start < 17 ? "Afternoons" : "Evenings")
            out.append(ReportHighlight(kind: .focus, text: "\(part) carried the \(model.period == .week ? "week" : "month"): \(clock(stretch.start)) to \(clock(stretch.start + 3)) holds \(share)% of your focus."))
        }

        if let top = model.distractions.first {
            let text: String
            if let before = top.before, top.seconds - before >= 300 {
                text = "\(top.name) is up \(WindowFormat.hm(top.seconds - before)) on the \(model.period == .week ? "week" : "month") before."
            } else if let before = top.before, before - top.seconds >= 300 {
                text = "\(top.name) is down \(WindowFormat.hm(before - top.seconds)), and still your top distraction."
            } else {
                text = "\(top.name) took the most drift time: \(WindowFormat.hm(top.seconds))."
            }
            out.append(ReportHighlight(kind: .drift, text: text))
        }

        let past = data.buckets.filter { !$0.isFuture && !$0.isLocked }
        if let worst = past.max(by: { $0.drift < $1.drift }), worst.drift >= 300 {
            let day = worst.interval.start.formatted(.dateTime.weekday(.wide))
            let goalPart = worst.focus >= goal ? "and still met the goal" : "and missed the goal"
            out.append(ReportHighlight(kind: .other, text: "\(day) drifted most, \(WindowFormat.minutes(worst.drift)), \(goalPart)."))
        }
        return out
    }

    /// The `length`-hour stretch with the most focus, and its share of all focus.
    static func bestStretch(_ heat: [[TimeInterval]], length: Int) -> (start: Int, share: Double)? {
        let byHour = (0..<24).map { hour in heat.reduce(0) { $0 + $1[hour] } }
        let total = byHour.reduce(0, +)
        guard total > 0 else { return nil }
        var best = (start: 0, seconds: TimeInterval(0))
        for start in 0...(24 - length) {
            let seconds = byHour[start..<(start + length)].reduce(0, +)
            if seconds > best.seconds { best = (start, seconds) }
        }
        return (best.start, best.seconds / total)
    }

    private static func clock(_ hour: Int) -> String { String(format: "%02d:00", hour % 24) }
}

extension ReportsModel {
    func with(highlights: [ReportHighlight]) -> ReportsModel {
        ReportsModel(period: period, data: data, clippedAt: clippedAt, longestZoneDay: longestZoneDay,
                     distractions: distractions, heat: heat, heatWeeks: heatWeeks, hourAverages: hourAverages,
                     trend: trend, patterns: patterns, patternNote: patternNote, highlights: highlights,
                     goal: goal, calendar: calendar, bestWeekNote: bestWeekNote)
    }
}

// MARK: - Words

enum ReportWords {
    /// "Goal met on 13 of 16 weekdays so far." and what the misses share.
    static func monthHeadline(_ goal: GoalDays, weekendsCount: Bool, isCurrent: Bool,
                              calendar: Calendar = .current) -> (lead: String, rest: String) {
        let noun = weekendsCount ? "days" : "weekdays"
        guard goal.counted > 0 else { return ("No goal days yet this month.", "") }
        let lead = "Goal met on \(goal.met) of \(goal.counted) \(noun)\(isCurrent ? " so far" : "")."
        guard !goal.misses.isEmpty else { return (lead, goal.met > 0 ? "Not one missed." : "") }
        let weekdays = goal.misses.map { calendar.component(.weekday, from: $0) }
        let counts = Dictionary(grouping: weekdays, by: { $0 }).mapValues(\.count)
        guard let common = counts.max(by: { $0.value < $1.value }) else { return (lead, "") }
        let name = calendar.weekdaySymbols[(common.key - 1 + 7) % 7]
        if goal.misses.count == 1 {
            return (lead, "The one miss was a \(name).")
        }
        if common.value == goal.misses.count {
            let number = goal.misses.count == 2 ? "Both" : "All \(spelled(goal.misses.count))"
            return (lead, "\(number) misses were \(name)s.")
        }
        if common.value * 2 > goal.misses.count {
            return (lead, "Most misses were \(name)s.")
        }
        return (lead, "")
    }

    static func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n < words.count ? words[n] : "\(n)"
    }

    /// "26 min less than last week", "1h 05m more than September".
    static func driftChange(_ now: TimeInterval, _ before: TimeInterval, against: String) -> String {
        guard before >= 60 else { return now >= 60 ? "nothing to compare yet" : "no drift" }
        let delta = now - before
        if abs(delta) < 60 { return "about the same as \(against)" }
        let amount = abs(delta) >= 3600 ? WindowFormat.hm(abs(delta)) : WindowFormat.minutes(abs(delta))
        return "\(amount) \(delta < 0 ? "less" : "more") than \(against)"
    }
}
