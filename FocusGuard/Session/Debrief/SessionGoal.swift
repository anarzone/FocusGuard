import EventKit
import Foundation

/// The goal typed in before a session, for the debrief to check. It waits
/// in the defaults until a session starts, then moves onto that session.
enum SessionGoal {
    static let key = "pro.sessionGoal"
    static let maxLength = 120
}

/// A goal offered under the empty goal field.
struct GoalSuggestion: Equatable, Identifiable {
    enum Source: Equatable {
        /// The last session's goal, when it wasn't done.
        case lastGoal
        /// The calendar event on now (or starting soon).
        case calendar
        /// An open task (Pro): a reminder, a Things to-do, a Todoist task,
        /// or a Linear, GitHub or Jira issue, and where it's filed.
        case task(TaskSource, id: String, list: String)
        /// The branch checked out in a repo.
        case git(repo: String)
    }

    let text: String
    let source: Source
    /// At the end of the row: "today", "15:00", "partly done".
    var detail: String?

    var id: String { "\(source)-\(text)" }

    /// Its kind for the decision log, never its text: "lastGoal", "task.linear".
    var logKind: String {
        switch source {
        case .lastGoal:             return "lastGoal"
        case .calendar:             return "calendar"
        case .task(let from, _, _): return "task.\(from.rawValue)"
        case .git:                  return "git"
        }
    }

    /// In the field's order: up to two tasks (best first, from any
    /// source), the calendar event, the Git branch, then the unfinished
    /// last goal. A text already offered isn't offered again.
    static func make(lastGoal: String?, lastVerdict: GoalVerdict?, calendarTitle: String?, calendarStart: Date? = nil,
                     tasks: [TaskItem] = [], git: GitGoal? = nil,
                     now: Date = .now, calendar: Calendar = .current) -> [GoalSuggestion] {
        var out: [GoalSuggestion] = []
        func add(_ text: String?, _ source: Source, _ detail: String? = nil) {
            guard let text = clean(text),
                  !out.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { return }
            out.append(GoalSuggestion(text: text, source: source, detail: detail))
        }
        for item in tasks.prefix(TaskGoals.offered) {
            add(item.title, .task(item.source, id: item.id, list: item.list), TaskGoals.dueNote(item, now: now, calendar: calendar))
        }
        add(calendarTitle, .calendar, calendarStart.flatMap { $0 > now ? HabitFormat.time($0, calendar: calendar) : nil })
        if let git { add(git.branch, .git(repo: git.repo)) }
        if lastVerdict != .done {
            add(lastGoal, .lastGoal, lastVerdict == .partly ? String(localized: "partly done", comment: "How the last session's goal ended, beside it in a list")
                : (lastVerdict == .notYet ? String(localized: "not yet", comment: "How the last session's goal ended, beside it in a list") : nil))
        }
        return out
    }

    /// The menu's few: the unfinished last goal and the calendar event on now
    /// come first, as the likeliest; then the best task, then the branch. Two
    /// at most: more is a list to read before starting.
    static func shortList(_ all: [GoalSuggestion], limit: Int = 2) -> [GoalSuggestion] {
        func rank(_ suggestion: GoalSuggestion) -> Int {
            switch suggestion.source {
            case .lastGoal: return 0
            case .calendar: return 1
            case .task:     return 2
            case .git:      return 3
            }
        }
        var tookTask = false
        return all.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .filter { suggestion in
                guard case .task = suggestion.source else { return true }
                defer { tookTask = true }
                return !tookTask
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The heading over a run of suggestions from one place: "Reminders ·
    /// Work", "Todoist · Inbox", "Calendar", "Git · focusguard", "Last time".
    var group: String {
        switch source {
        case .task(let from, _, let list):
            // Reminders' own list is called "Reminders": not "Reminders · Reminders".
            return list.isEmpty || list.caseInsensitiveCompare(from.name) == .orderedSame ? from.name : "\(from.name) · \(list)"
        case .calendar:                    return String(localized: "Calendar", comment: "Heading over goals suggested from the calendar")
        case .git(let repo):               return "Git · \(repo)"
        case .lastGoal:                    return String(localized: "Last time", comment: "Heading over the last session's unfinished goal")
        }
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(SessionGoal.maxLength))
    }
}

/// The calendar event on now, or starting in the next 15 minutes, when
/// FocusGuard already has calendar access. It never asks. Only the chosen
/// calendars are read, and FocusGuard's own events are left out.
@MainActor
final class CalendarGoalSource {
    private var store: EKEventStore?

    func current(now: Date = .now) -> (title: String, start: Date)? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = self.store ?? EKEventStore()
        self.store = store
        let own = OwnEvents.ids()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(15 * 60),
                                                 calendars: IntegrationSettings.readCalendars(in: store))
        let events = store.events(matching: predicate).filter {
            !$0.isAllDay && !($0.title ?? "").isEmpty && !OwnEvents.isOwn($0, ids: own)
        }
        let current = events.first { $0.startDate <= now && now < $0.endDate }
        let next = events.filter { $0.startDate > now }.min { $0.startDate < $1.startDate }
        guard let event = current ?? next, let title = event.title, let start = event.startDate else { return nil }
        return (title, start)
    }
}
