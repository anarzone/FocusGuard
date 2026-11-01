import Foundation

/// User-configurable daily focus goal. Stored in UserDefaults so the popover
/// hero, Reports view, and end-of-day summary all read from one place.
///
/// A weekday can have a goal of its own (the weekly coach sets one for a
/// weekday that keeps coming in low); every other day uses the daily goal.
enum FocusGoal {
    /// What every goal stepper allows: 15 minutes to 12 hours.
    static let range = 15...720

    /// The user's daily focus goal in minutes. Defaults to 240 (4 hours).
    static var dailyMinutes: Int {
        get { baseMinutes(.standard) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.Goal.dailyFocusMinutes) }
    }

    static var dailySeconds: TimeInterval { TimeInterval(dailyMinutes * 60) }

    /// The daily goal in `defaults`, before any weekday's own.
    static func baseMinutes(_ defaults: UserDefaults) -> Int {
        let raw = defaults.integer(forKey: SettingsKeys.Goal.dailyFocusMinutes)
        return raw > 0 ? raw : GoalDefaults.dailyFocusMinutes
    }

    // MARK: - By weekday

    /// Weekdays with a goal of their own, in minutes, by `Calendar` weekday
    /// (1 is Sunday, 7 Saturday). Empty unless one was set.
    static func weekdayMinutes(_ defaults: UserDefaults = .standard) -> [Int: Int] {
        guard let data = defaults.data(forKey: SettingsKeys.Goal.weekdayFocusMinutes),
              let stored = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        var out: [Int: Int] = [:]
        for (key, minutes) in stored {
            guard let weekday = Int(key), (1...7).contains(weekday), minutes > 0 else { continue }
            out[weekday] = min(range.upperBound, max(range.lowerBound, minutes))
        }
        return out
    }

    /// Gives `weekday` a goal of its own, or (nil) puts it back on the daily goal.
    static func setMinutes(_ minutes: Int?, forWeekday weekday: Int, _ defaults: UserDefaults = .standard) {
        guard (1...7).contains(weekday) else { return }
        var all = weekdayMinutes(defaults)
        all[weekday] = minutes.map { min(range.upperBound, max(range.lowerBound, $0)) }
        let stored = Dictionary(uniqueKeysWithValues: all.map { (String($0.key), $0.value) })
        if stored.isEmpty {
            defaults.removeObject(forKey: SettingsKeys.Goal.weekdayFocusMinutes)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: SettingsKeys.Goal.weekdayFocusMinutes)
        }
    }

    /// The goal on the day `date` falls on: its weekday's own, else the daily goal.
    static func minutes(on date: Date, _ defaults: UserDefaults = .standard, calendar: Calendar = .current) -> Int {
        weekdayMinutes(defaults)[calendar.component(.weekday, from: date)] ?? baseMinutes(defaults)
    }

    static func seconds(on date: Date, _ defaults: UserDefaults = .standard, calendar: Calendar = .current) -> TimeInterval {
        TimeInterval(minutes(on: date, defaults, calendar: calendar) * 60)
    }

    /// Today's goal.
    static var todayMinutes: Int { minutes(on: .now) }
    static var todaySeconds: TimeInterval { seconds(on: .now) }

    /// Fraction of today's goal hit, clamped to [0, 1] for progress UIs.
    static func progress(focusSecondsToday: TimeInterval, now: Date = .now) -> Double {
        let goal = seconds(on: now)
        guard goal > 0 else { return 0 }
        return min(1, max(0, focusSecondsToday / goal))
    }

    /// A weekday's own goal.
    struct WeekdayGoal: Hashable {
        let weekday: Int
        let minutes: Int
    }

    /// The weekdays with a goal of their own, in the calendar's week order.
    static func weekdayGoals(_ defaults: UserDefaults = .standard, calendar: Calendar = .current) -> [WeekdayGoal] {
        let own = weekdayMinutes(defaults)
        return (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }.compactMap { weekday in
            own[weekday].map { WeekdayGoal(weekday: weekday, minutes: $0) }
        }
    }

    /// "Fridays".
    static func pluralWeekday(_ weekday: Int, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var named = calendar
        named.locale = locale
        let symbols = named.weekdaySymbols
        guard (1...symbols.count).contains(weekday) else { return "" }
        return symbols[weekday - 1] + "s"
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
