import Foundation

/// The evening notification: "Today: 3h 40m focused. 20 minutes short of
/// your 4h goal. Best stretch: Comeback Run, 14:05–14:55. Best time to start
/// tomorrow: 10:00."
struct EveningWrapUp: Equatable {
    struct Stretch: Equatable {
        /// The session's name.
        let name: String
        let start: Date
        let end: Date
    }

    let focusedMinutes: Int
    let goalMinutes: Int
    /// Days in a row the goal was met, today included; 0 when today missed it.
    let streak: Int
    /// Today's session with the most focused time.
    let best: Stretch?
    /// When to start tomorrow, if there's enough history to say.
    let tomorrowStart: Date?

    var goalHit: Bool { focusedMinutes >= goalMinutes }

    /// "Goal hit: 4h 25m focused", "Today: 3h 40m focused".
    var title: String {
        let focused = FocusGoal.format(minutes: focusedMinutes)
        return goalHit ? "Goal hit: \(focused) focused" : "Today: \(focused) focused"
    }

    func body(locale: Locale = .current, calendar: Calendar = .current) -> String {
        func time(_ date: Date) -> String { HabitFormat.time(date, locale: locale, calendar: calendar) }
        let goal = FocusGoal.format(minutes: goalMinutes)
        var sentences: [String] = []
        let difference = abs(focusedMinutes - goalMinutes)
        if difference == 0 {
            sentences.append("Right on your \(goal) goal.")
        } else {
            let side = goalHit ? "over" : "short of"
            sentences.append("\(HabitFormat.amount(minutes: difference)) \(side) your \(goal) goal.")
        }
        if goalHit, streak >= 2 {
            sentences.append("That's \(streak) days in a row.")
        } else if let best {
            sentences.append("Best stretch: \(best.name), \(time(best.start))–\(time(best.end)).")
        }
        if let tomorrowStart {
            sentences.append("Best time to start tomorrow: \(time(tomorrowStart)).")
        }
        return sentences.joined(separator: " ")
    }

    /// Tomorrow's free slot nearest the hour this Mac usually focuses best,
    /// or that hour itself when the calendar can't be read.
    /// - Parameters:
    ///   - peakHour: the hour with the most focused time lately; nil without history.
    ///   - tomorrowBusy: tomorrow's calendar events; nil when the calendar can't be read.
    static func bestStart(peakHour: Int?, tomorrowBusy: [DateInterval]?, sessionMinutes: Int,
                          now: Date, calendar: Calendar = .current) -> Date? {
        guard let peakHour,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let peak = calendar.date(bySettingHour: peakHour, minute: 0, second: 0, of: tomorrow) else { return nil }
        guard let busy = tomorrowBusy else { return peak }
        guard let from = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow),
              let to = calendar.date(bySettingHour: HabitSchedule.dayEndHour, minute: 0, second: 0, of: tomorrow),
              to > from else { return peak }
        let starts = FreeSlots.candidates(busy: busy, in: DateInterval(start: from, end: to),
                                          length: TimeInterval(sessionMinutes * 60),
                                          grid: HabitSchedule.slotGrid, calendar: calendar)
        // Nearest the peak; on a tie, the earlier one.
        return starts.min { abs($0.timeIntervalSince(peak)) < abs($1.timeIntervalSince(peak)) }
    }
}
