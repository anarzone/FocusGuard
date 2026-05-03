import Foundation

/// User-configurable daily focus goal. Stored in UserDefaults so the popover
/// hero, Reports view, and end-of-day summary all read from one place.
enum FocusGoal {
    /// The user's daily focus goal in minutes. Defaults to 240 (4 hours).
    static var dailyMinutes: Int {
        get {
            let raw = UserDefaults.standard.integer(forKey: SettingsKeys.Goal.dailyFocusMinutes)
            return raw > 0 ? raw : GoalDefaults.dailyFocusMinutes
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.Goal.dailyFocusMinutes) }
    }

    static var dailySeconds: TimeInterval { TimeInterval(dailyMinutes * 60) }

    /// Fraction of today's goal hit, clamped to [0, 1] for progress UIs.
    static func progress(focusSecondsToday: TimeInterval) -> Double {
        let goal = dailySeconds
        guard goal > 0 else { return 0 }
        return min(1, max(0, focusSecondsToday / goal))
    }

    /// Friendly format: "4h" or "3h 30m" — used by the goal stepper label.
    static func format(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}
