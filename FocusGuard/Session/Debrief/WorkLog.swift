import Foundation
import SwiftData

/// A session in the work log.
struct WorkLogEntry: Identifiable, Equatable {
    enum State: Equatable {
        case verdict(GoalVerdict)
        /// Still running.
        case live
        /// Finished without a goal, or with one nobody has judged yet.
        case open
    }

    let id: UUID
    let start: Date
    /// Nil while it runs.
    let end: Date?
    let name: String
    let focusRate: Double
    let hasRate: Bool
    /// The goal, or what the session was mostly in when it had none.
    let title: String
    let hasGoal: Bool
    let project: String?
    let state: State
    /// The debrief's line: the evidence, or the first thing worked on.
    let note: String?
    /// "github.com · Xcode · x.com 7m"
    let apps: String
    let focused: TimeInterval
    /// When it was focused, so a session across midnight counts on both days.
    var focusSpans: [DateInterval] = []
    /// The focus app or site it was mostly in, to ask about time without a goal.
    var mostly: String? = nil
    /// The user put this time under its project themselves.
    var movedByUser = false

    var isLive: Bool { end == nil }
}

struct WorkLogDay: Identifiable, Equatable {
    let day: Date
    let entries: [WorkLogEntry]

    var id: Date { day }
    var focused: TimeInterval { entries.reduce(0) { $0 + $1.focused } }
}

/// Focused time per project, most first, "No project" (nil) last.
struct WorkLogProject: Identifiable, Equatable {
    let name: String?
    let seconds: TimeInterval

    var id: String { name ?? "" }
    var title: String { name ?? String(localized: "No project", comment: "Focused time that belongs to no project") }
}

/// Focused hours per project and day.
struct Timesheet: Equatable {
    struct Row: Equatable {
        let project: String?
        /// Seconds for each of `days`.
        let seconds: [TimeInterval]
        var total: TimeInterval { seconds.reduce(0, +) }
        var title: String { project ?? String(localized: "No project", comment: "Focused time that belongs to no project") }
    }

    /// Monday to Friday, plus a weekend day that has time on it, in order,
    /// whichever day the calendar's week starts on.
    let days: [Date]
    let rows: [Row]

    var dayTotals: [TimeInterval] {
        days.indices.map { i in rows.reduce(0) { $0 + $1.seconds[i] } }
    }
    var total: TimeInterval { rows.reduce(0) { $0 + $1.total } }

    /// "3.17": hours with two decimals, as in the CSV. Nothing for nothing.
    static func hours(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "" : String(format: "%.2f", seconds / 3600)
    }

    /// Hours as CSV: a header of dates, a row per project, then the totals.
    /// Dates are written in the calendar's own time zone, the one `days`
    /// were cut in. The labels stay in English, as in the other exports.
    func csv(calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        func number(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds / 3600) }
        var lines = [(["Project"] + days.map { format.string(from: $0) } + ["Total"]).map(Self.field).joined(separator: ",")]
        for row in rows {
            lines.append(([Self.field(row.project ?? "No project")] + row.seconds.map(number) + [number(row.total)]).joined(separator: ","))
        }
        lines.append((["Total"] + dayTotals.map(number) + [number(total)]).joined(separator: ","))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quoted when it needs to be.
    static func field(_ text: String) -> String {
        guard text.contains(where: { ",\"\n\r".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Everything the work log shows for one week.
struct WorkLogModel: Equatable {
    let interval: DateInterval
    /// Newest day first, newest session first.
    let days: [WorkLogDay]
    let projects: [WorkLogProject]
    let timesheet: Timesheet

    var entries: [WorkLogEntry] { days.flatMap(\.entries) }
    var focused: TimeInterval { entries.reduce(0) { $0 + $1.focused } }

    static func empty(_ interval: DateInterval) -> WorkLogModel {
        WorkLogModel(interval: interval, days: [], projects: [], timesheet: Timesheet(days: [], rows: []))
    }
}

/// Builds the work log from the week's sessions.
enum WorkLogBuilder {
    /// One session, read from the store.
    struct Input {
        let id: UUID
        let start: Date
        let end: Date?
        let name: String
        let goal: String?
        let verdict: GoalVerdict?
        let project: String?
        let stored: StoredDebrief?
        let facts: DebriefFacts
    }

    @MainActor
    static func load(interval: DateInterval, context: ModelContext, isOptedOut: (String) -> Bool,
                     moved: [String: String] = [:], now: Date = .now, calendar: Calendar = .current) -> WorkLogModel {
        let start = interval.start, end = interval.end
        let sessions = Persistence.fetch(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))
        let inputs = sessions.map { session in
            Input(id: session.id, start: session.startedAt, end: session.endedAt, name: session.displayName,
                  goal: session.goal, verdict: session.goalVerdict, project: session.project,
                  stored: session.storedDebrief,
                  facts: DebriefFacts(session: session, isOptedOut: isOptedOut))
        }
        return build(inputs, interval: interval, moved: moved, now: now, calendar: calendar)
    }

    /// - Parameter moved: project by app or site, lowercased, for time with
    ///   neither a goal nor a project of its own.
    static func build(_ inputs: [Input], interval: DateInterval, moved: [String: String] = [:], now: Date = .now,
                      calendar: Calendar = .current) -> WorkLogModel {
        let entries = inputs
            .filter { $0.end == nil || $0.facts.tracked >= 60 || $0.goal != nil }
            .map { entry($0, moved: moved) }
            .sorted { $0.start > $1.start }
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.start) }
        let days = grouped.keys.sorted(by: >).map { WorkLogDay(day: $0, entries: grouped[$0] ?? []) }

        var byProject: [String?: TimeInterval] = [:]
        for entry in entries { byProject[entry.project, default: 0] += entry.focused }
        let projects = byProject
            .filter { $0.value >= 60 }
            .map { WorkLogProject(name: $0.key, seconds: $0.value) }
            .sorted { a, b in
                if (a.name == nil) != (b.name == nil) { return b.name == nil }
                return a.seconds != b.seconds ? a.seconds > b.seconds : a.title < b.title
            }

        return WorkLogModel(interval: interval, days: days, projects: projects,
                            timesheet: timesheet(entries, projects: projects, interval: interval, calendar: calendar))
    }

    private static func entry(_ input: Input, moved: [String: String]) -> WorkLogEntry {
        let facts = input.facts
        let state: WorkLogEntry.State
        if input.end == nil {
            state = .live
        } else if input.goal != nil, let verdict = input.verdict {
            state = .verdict(verdict)
        } else {
            state = .open
        }
        let mostly = facts.apps.first { $0.classification == .focus } ?? facts.apps.first
        let movedTo = input.goal == nil && input.project == nil ? mostly.flatMap { moved[$0.name.lowercased()] } : nil
        let fallback = mostly.map { String(localized: "Mostly \($0.name)") } ?? String(localized: "Nothing tracked")
        let stored = input.stored.map { DebriefCheck(facts: facts).clean($0) }
        let firstWork = stored?.workedOn.first { !$0.what.isEmpty }
        let title = input.goal ?? firstWork.map { "\($0.app) · \($0.what)" } ?? fallback
        let note: String?
        if input.end == nil {
            note = String(localized: "Running. Its debrief is written when it ends.")
        } else if let stored {
            note = stored.evidence ?? (input.goal == nil ? nil : firstWork.map { "\($0.app): \($0.what)" })
        } else {
            note = nil
        }
        return WorkLogEntry(
            id: input.id, start: input.start, end: input.end, name: input.name,
            focusRate: facts.focusRate, hasRate: facts.focused + facts.drifted >= 60,
            title: title, hasGoal: input.goal != nil, project: input.project ?? movedTo,
            state: state, note: note, apps: appsLine(facts), focused: facts.focused, focusSpans: facts.focusSpans,
            mostly: mostly?.name, movedByUser: movedTo != nil
        )
    }

    /// The two apps used most, then the top drift with its minutes.
    static func appsLine(_ facts: DebriefFacts) -> String {
        var parts = facts.apps.filter { $0.classification != .distraction }.prefix(2).map(\.name)
        if let drift = facts.topDrift, drift.seconds >= 60 {
            let minutes = Int((drift.seconds / 60).rounded())
            parts.append("\(drift.name) " + String(localized: "\(minutes)m", comment: "Compact duration"))
        }
        return parts.joined(separator: " · ")
    }

    private static func timesheet(_ entries: [WorkLogEntry], projects: [WorkLogProject],
                                  interval: DateInterval, calendar: Calendar) -> Timesheet {
        var days: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? interval.end
        }
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })
        var grid: [String?: [TimeInterval]] = [:]
        for entry in entries {
            guard index[calendar.startOfDay(for: entry.start)] != nil else { continue }
            var row = grid[entry.project] ?? Array(repeating: 0, count: days.count)
            for span in entry.focusSpans {
                // Past the week's end it stays on its last day, in the week it started.
                var cursor = span.start
                while cursor < span.end {
                    let day = calendar.startOfDay(for: cursor)
                    let next = calendar.date(byAdding: .day, value: 1, to: day) ?? span.end
                    let end = min(span.end, next)
                    row[index[day] ?? days.count - 1] += end.timeIntervalSince(cursor)
                    cursor = end
                }
            }
            grid[entry.project] = row
        }
        let kept = days.indices.filter { i in
            !calendar.isDateInWeekend(days[i]) || grid.values.contains { $0[i] >= 60 }
        }
        let rows = projects.map { project in
            let seconds = grid[project.name] ?? Array(repeating: 0, count: days.count)
            return Timesheet.Row(project: project.name, seconds: kept.map { seconds[$0] })
        }
        return Timesheet(days: kept.map { days[$0] }, rows: rows)
    }
}
