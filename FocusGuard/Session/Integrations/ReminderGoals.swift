import Foundation

/// Open reminders offered as session goals (Pro): the ones due today
/// first, then overdue ones, then ones due later, then the rest, oldest
/// first.
enum ReminderGoals {
    /// At most this many are offered under the goal field.
    static let offered = 2

    static func ordered(_ items: [ReminderItem], now: Date, calendar: Calendar = .current) -> [ReminderItem] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        func rank(_ item: ReminderItem) -> Int {
            guard let due = item.due else { return 3 }
            if due < today { return 1 }
            return due < tomorrow ? 0 : 2
        }
        return items.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if let da = a.due, let db = b.due, da != db { return da < db }
            if let ca = a.created, let cb = b.created, ca != cb { return ca < cb }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// "today", "overdue", or nothing.
    static func dueNote(_ item: ReminderItem, now: Date, calendar: Calendar = .current) -> String? {
        guard let due = item.due else { return nil }
        if calendar.isDate(due, inSameDayAs: now) { return "today" }
        return due < calendar.startOfDay(for: now) ? "overdue" : nil
    }

    /// The first open reminder that isn't the one just done.
    static func next(after id: String, in items: [ReminderItem], now: Date, calendar: Calendar = .current) -> ReminderItem? {
        ordered(items.filter { $0.id != id }, now: now, calendar: calendar).first
    }
}

/// A session whose goal came from a reminder, and whether it was ticked off.
struct TaskLink: Codable, Equatable {
    let reminder: ReminderItem
    /// When the session started, to keep only recent links.
    let linkedAt: Date
    var ticked = false
    /// The user took the tick back. Only their own "Done" ticks it again,
    /// not the debrief's.
    var undone = false

    /// What to do with the reminder after the verdict changed.
    enum Change: Equatable {
        case tick, untick, none
    }

    /// Done ticks it off; anything else takes back a tick FocusGuard made.
    func change(for verdict: GoalVerdict?, byUser: Bool) -> Change {
        if verdict == .done {
            return !ticked && (byUser || !undone) ? .tick : .none
        }
        return ticked ? .untick : .none
    }
}
