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
    var title: String { name ?? "No project" }
}

/// Focused hours per project and day.
struct Timesheet: Equatable {
    struct Row: Equatable {
        let project: String?
        /// Seconds for each of `days`.
        let seconds: [TimeInterval]
        var total: TimeInterval { seconds.reduce(0, +) }
        var title: String { project ?? "No project" }
    }

    /// Monday to Friday, plus a weekend day that has time on it.
    let days: [Date]
    let rows: [Row]

    var dayTotals: [TimeInterval] {
        days.indices.map { i in rows.reduce(0) { $0 + $1.seconds[i] } }
    }
    var total: TimeInterval { rows.reduce(0) { $0 + $1.total } }

    /// "3.1": hours with one decimal, "–" for nothing.
    static func hours(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "–" : String(format: "%.1f", seconds / 3600)
    }

    /// Hours as CSV: a header of dates, a row per project, then the totals.
    func csv(calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        func number(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds / 3600) }
        var lines = [(["Project"] + days.map { format.string(from: $0) } + ["Total"]).map(Self.field).joined(separator: ",")]
        for row in rows {
            lines.append(([Self.field(row.title)] + row.seconds.map(number) + [number(row.total)]).joined(separator: ","))
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

/// Done, next and blocked, for the next working day's standup.
struct StandupDraft: Equatable {
    /// The day it's for: the working day after the last one with sessions.
    let day: Date
    let done: [String]
    let next: [String]

    var text: String {
        [
            "Done: " + Self.list(done, empty: "nothing marked done yet"),
            "Next: " + Self.list(next, empty: "pick up from the work log"),
            "Blocked: nothing.",
        ].joined(separator: "\n")
    }

    private static func list(_ items: [String], empty: String) -> String {
        let joined = items.isEmpty ? empty : items.joined(separator: "; ")
        return joined.hasSuffix(".") ? joined : joined + "."
    }
}

/// Everything the work log shows for one week.
struct WorkLogModel: Equatable {
    let interval: DateInterval
    /// Newest day first, newest session first.
    let days: [WorkLogDay]
    let projects: [WorkLogProject]
    let timesheet: Timesheet
    let standup: StandupDraft?

    var entries: [WorkLogEntry] { days.flatMap(\.entries) }
    var goalsDone: Int { entries.filter { $0.state == .verdict(.done) }.count }
    var goalsPartly: Int { entries.filter { $0.state == .verdict(.partly) }.count }
    var focused: TimeInterval { entries.reduce(0) { $0 + $1.focused } }
    var topProject: String? { projects.first?.name }

    /// "11 goals done and 3 partly this week." and "Most of it went to
    /// FocusGuard." `offset` counts weeks back from this one.
    func headline(offset: Int) -> (lead: String, rest: String) {
        let when = offset == 0 ? "this week" : (offset == 1 ? "last week" : "that week")
        let done = goalsDone, partly = goalsPartly
        let goals = "\(done) \(done == 1 ? "goal" : "goals")"
        let lead: String
        if done > 0 && partly > 0 {
            lead = "\(goals) done and \(partly) partly \(when)."
        } else if done > 0 {
            lead = "\(goals) done \(when)."
        } else if partly > 0 {
            lead = "\(partly) \(partly == 1 ? "goal" : "goals") partly done \(when)."
        } else if !entries.isEmpty {
            let count = entries.count
            lead = "\(count) \(count == 1 ? "session" : "sessions"), \(WindowFormat.hm(focused)) focused \(when)."
        } else {
            return (offset == 0 ? "No sessions yet this week." : "No sessions \(when).",
                    offset == 0 ? "Start one, and give it a goal." : "")
        }
        if let top = topProject { return (lead, "Most of it went to \(top).") }
        return (lead, entries.contains(where: \.hasGoal) ? "" : "Give the next session a goal to see it here.")
    }

    static func empty(_ interval: DateInterval) -> WorkLogModel {
        WorkLogModel(interval: interval, days: [], projects: [], timesheet: Timesheet(days: [], rows: []), standup: nil)
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
                     now: Date = .now, calendar: Calendar = .current) -> WorkLogModel {
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
        return build(inputs, interval: interval, now: now, calendar: calendar)
    }

    static func build(_ inputs: [Input], interval: DateInterval, now: Date = .now,
                      calendar: Calendar = .current) -> WorkLogModel {
        let entries = inputs
            .filter { $0.end == nil || $0.facts.tracked >= 60 || $0.goal != nil }
            .map(entry)
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
                            timesheet: timesheet(entries, projects: projects, interval: interval, calendar: calendar),
                            standup: standup(days, calendar: calendar))
    }

    private static func entry(_ input: Input) -> WorkLogEntry {
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
        let title = input.goal ?? input.stored?.workedOn.first.map { "\($0.app) · \($0.what)" }
            ?? mostly.map { "Mostly \($0.name)" } ?? "Nothing tracked"
        let note: String?
        if input.end == nil {
            note = "Running. Its debrief is written when it ends."
        } else if let stored = input.stored {
            note = stored.evidence ?? (input.goal == nil ? nil : stored.workedOn.first.map { "\($0.app): \($0.what)" })
        } else {
            note = nil
        }
        return WorkLogEntry(
            id: input.id, start: input.start, end: input.end, name: input.name,
            focusRate: facts.focusRate, hasRate: facts.focused + facts.drifted >= 60,
            title: title, hasGoal: input.goal != nil, project: input.project,
            state: state, note: note, apps: appsLine(facts), focused: facts.focused
        )
    }

    /// The two apps used most, then the top drift with its minutes.
    static func appsLine(_ facts: DebriefFacts) -> String {
        var parts = facts.apps.filter { $0.classification != .distraction }.prefix(2).map(\.name)
        if let drift = facts.topDrift, drift.seconds >= 60 {
            parts.append("\(drift.name) \(Int((drift.seconds / 60).rounded()))m")
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
            guard let i = index[calendar.startOfDay(for: entry.start)] else { continue }
            grid[entry.project, default: Array(repeating: 0, count: days.count)][i] += entry.focused
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

    /// From the last day with sessions: its goals done, and what's still
    /// open (partly done, not yet, or running) as next.
    private static func standup(_ days: [WorkLogDay], calendar: Calendar) -> StandupDraft? {
        guard let last = days.first else { return nil }
        var done: [String] = []
        var next: [String] = []
        for entry in last.entries.reversed() where entry.hasGoal {
            switch entry.state {
            case .verdict(.done): done.append(entry.title)
            case .verdict(.partly), .verdict(.notYet), .live: next.append(entry.title)
            case .open: break
            }
        }
        if done.isEmpty && next.isEmpty {
            let focused = WindowFormat.hm(last.focused)
            done = ["\(last.entries.count) \(last.entries.count == 1 ? "session" : "sessions"), \(focused) focused"]
        }
        return StandupDraft(day: nextWorkingDay(after: last.day, calendar: calendar), done: dedupe(done), next: dedupe(next))
    }

    static func nextWorkingDay(after day: Date, calendar: Calendar) -> Date {
        var next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
        while calendar.isDateInWeekend(next) {
            next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
        }
        return next
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }
}
