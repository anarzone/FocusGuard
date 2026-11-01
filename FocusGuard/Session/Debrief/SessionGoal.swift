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
        /// An open task (Pro): a reminder, a Things to-do, a Todoist task
        /// or a Linear issue, and where it's filed.
        case task(TaskSource, id: String, list: String)
        /// The branch checked out in a repo.
        case git(repo: String)
    }

    let text: String
    let source: Source
    /// At the end of the row: "today", "15:00", "partly done".
    var detail: String?

    var id: String { "\(source)-\(text)" }

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
            add(lastGoal, .lastGoal, lastVerdict == .partly ? "partly done" : (lastVerdict == .notYet ? "not yet" : nil))
        }
        return out
    }

    /// The heading over a run of suggestions from one place: "Reminders ·
    /// Work", "Todoist · Inbox", "Calendar", "Git · focusguard", "Last time".
    var group: String {
        switch source {
        case .task(let from, _, let list): return list.isEmpty ? from.name : "\(from.name) · \(list)"
        case .calendar:                    return "Calendar"
        case .git(let repo):               return "Git · \(repo)"
        case .lastGoal:                    return "Last time"
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
