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
    }

    let text: String
    let source: Source

    var id: String { "\(source)-\(text)" }

    /// At most two: the unfinished last goal, then the calendar event.
    static func make(lastGoal: String?, lastVerdict: GoalVerdict?, calendarTitle: String?) -> [GoalSuggestion] {
        var out: [GoalSuggestion] = []
        if let goal = clean(lastGoal), lastVerdict != .done {
            out.append(GoalSuggestion(text: goal, source: .lastGoal))
        }
        if let title = clean(calendarTitle),
           !out.contains(where: { $0.text.caseInsensitiveCompare(title) == .orderedSame }) {
            out.append(GoalSuggestion(text: title, source: .calendar))
        }
        return out
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(SessionGoal.maxLength))
    }
}

/// The title of the calendar event on now, or starting in the next 15
/// minutes, when FocusGuard already has calendar access. It never asks.
@MainActor
final class CalendarGoalSource {
    private var store: EKEventStore?

    func currentTitle(now: Date = .now) -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(15 * 60), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && !($0.title ?? "").isEmpty }
        let current = events.first { $0.startDate <= now && now < $0.endDate }
        let next = events.filter { $0.startDate > now }.min { $0.startDate < $1.startDate }
        return (current ?? next)?.title
    }
}
