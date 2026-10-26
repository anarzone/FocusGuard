import Foundation

/// The habit switches. The app window's settings show them; all default to on.
enum HabitSettings {
    /// A morning notification with today's free slots.
    static let morningPlan = "habits.morningPlan.enabled"
    /// An evening notification: focused time against the goal, and when to
    /// start tomorrow.
    static let eveningWrapUp = "habits.eveningWrapUp.enabled"
    /// "You've been in Xcode 5 minutes. Start a session?"
    static let autoStartOffer = "habits.autoStartOffer.enabled"
    /// Calls count as neutral, and nudges wait until the call ends.
    static let meetingAwareness = "habits.meetingAwareness.enabled"
    /// The hour the morning plan starts going out; missing means 09:00.
    /// The weekly coach moves it for an experiment.
    static let morningPlanHour = "habits.morningPlan.hour"

    static func isOn(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// When the habits speak up, in local hours.
enum HabitSchedule {
    /// The morning plan goes out from 09:00 (or the hour in
    /// `HabitSettings.morningPlanHour`) until noon, once a day.
    static var morningHours: Range<Int> { morningStartHour()..<12 }

    static func morningStartHour(_ defaults: UserDefaults = .standard) -> Int {
        min(11, max(5, defaults.object(forKey: HabitSettings.morningPlanHour) as? Int ?? 9))
    }
    /// Free slots are looked for until this hour.
    static let dayEndHour = 19
    /// At most this many sessions are suggested.
    static let maxSessions = 3
    /// Slots start on the hour or half hour.
    static let slotGrid: TimeInterval = 30 * 60
    /// A slot starts at least this long from now.
    static let slotLead: TimeInterval = 15 * 60
    /// A planned session is offered for this long after its time.
    static let plannedSessionGrace: TimeInterval = 10 * 60

    /// The evening wrap-up goes out after this hour, once nothing has been
    /// tracked for `wrapUpQuietMinutes`.
    static var wrapUpHour: Int { GoalDefaults.summaryHourLocal }
    static var wrapUpQuietMinutes: Int { GoalDefaults.summaryInactivityMinutes }
}

/// How the habit notifications write times and amounts.
enum HabitFormat {
    /// "10:02", or "10:02 AM", as this Mac shows times.
    static func time(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// "10:00, 14:00 and 17:30".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    /// "20 minutes" under an hour, "1h 20m" from there.
    static func amount(minutes: Int) -> String {
        minutes < 60 ? NotificationPresenter.plural(minutes, "minute") : FocusGoal.format(minutes: minutes)
    }

    /// "yyyy-MM-dd" for the day `date` falls on, to remember what was sent when.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
