import Foundation
import SwiftData

/// Computes the user's current "goal streak" — number of consecutive days
/// hitting `FocusGoal.dailyMinutes`, walking back from yesterday.
///
/// Why yesterday and not today? Today isn't done yet — counting it would make
/// the streak flicker (3 → 4 → 4 → 3 if user falls behind by evening). We
/// surface today's progress separately via the goal bar.
///
/// Weekend grace: by default Sat/Sun are skipped during the walk-back so a
/// weekend off doesn't reset a weekday streak. User can opt out in Settings.
struct StreakCalculator {
    let context: ModelContext

    static let lookbackDays = 60

    func currentStreak(now: Date = .now, calendar: Calendar = .current) -> Int {
        // Pull last 60 days of daily totals at most. ReportBuilder handles
        // the per-day bucketing including events that span midnight.
        let lookbackStart = calendar.date(byAdding: .day, value: -Self.lookbackDays, to: calendar.startOfDay(for: now)) ?? now
        let endOfYesterday = calendar.startOfDay(for: now)
        let totals = ReportBuilder(context: context).dailyTotals(
            from: lookbackStart,
            to: endOfYesterday,
            classification: .focus
        )
        return Self.streak(focusByDay: Dictionary(uniqueKeysWithValues: totals.map { ($0.date, $0.seconds) }),
                           now: now, calendar: calendar)
    }

    /// The streak from focus seconds per day-start, walking back from
    /// yesterday (StatsStore passes the days it already has).
    static func streak(focusByDay byDay: [Date: TimeInterval], now: Date = .now, calendar: Calendar = .current) -> Int {
        let weekendsCount = UserDefaults.standard.bool(forKey: SettingsKeys.Goal.weekendsCount)
        let goalSeconds = FocusGoal.dailySeconds
        let lookbackStart = calendar.date(byAdding: .day, value: -lookbackDays, to: calendar.startOfDay(for: now)) ?? now

        var streak = 0
        var cursor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)

        while cursor >= lookbackStart {
            let weekday = calendar.component(.weekday, from: cursor)
            let isWeekend = (weekday == 1 || weekday == 7) // Sun=1, Sat=7
            if isWeekend && !weekendsCount {
                cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
                continue
            }
            let secs = byDay[cursor] ?? 0
            if secs >= goalSeconds {
                streak += 1
                cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            } else {
                break
            }
        }
        return streak
    }
}
