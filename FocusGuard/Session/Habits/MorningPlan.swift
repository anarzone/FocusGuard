import Foundation

/// The morning notification: "3 sessions today? Free slots at 10:00, 14:00
/// and 17:30 would cover your 4h goal." The slots come from the calendar
/// when FocusGuard can read it, and are just spread over the day otherwise.
struct MorningPlan: Equatable {
    /// When each suggested session starts, earliest first.
    let slots: [Date]
    /// Each session's length.
    let sessionMinutes: Int
    let goalMinutes: Int
    /// Focused so far today.
    let focusedMinutes: Int
    /// Whether the slots were found between calendar events.
    let fromCalendar: Bool

    /// Nil when today's goal is already met or nothing fits before evening.
    /// - Parameter busy: today's calendar events; nil when the calendar can't be read.
    static func make(now: Date, focusedMinutes: Int, goalMinutes: Int, sessionMinutes: Int,
                     busy: [DateInterval]?, calendar: Calendar = .current) -> MorningPlan? {
        let remaining = goalMinutes - focusedMinutes
        guard remaining > 0, sessionMinutes > 0 else { return nil }
        let wanted = min(HabitSchedule.maxSessions, Int((Double(remaining) / Double(sessionMinutes)).rounded(.up)))
        guard let dayEnd = calendar.date(bySettingHour: HabitSchedule.dayEndHour, minute: 0, second: 0, of: now) else { return nil }
        let start = now.addingTimeInterval(HabitSchedule.slotLead)
        guard dayEnd > start else { return nil }
        let length = TimeInterval(sessionMinutes * 60)
        let breakLength = TimeInterval(AppState.suggestedBreakMinutes(forSessionMinutes: sessionMinutes) * 60)
        let slots = FreeSlots.find(busy: busy ?? [], in: DateInterval(start: start, end: dayEnd), length: length,
                                   count: wanted, breakLength: breakLength, calendar: calendar)
        guard !slots.isEmpty else { return nil }
        return MorningPlan(slots: slots, sessionMinutes: sessionMinutes, goalMinutes: goalMinutes,
                           focusedMinutes: focusedMinutes, fromCalendar: busy != nil)
    }

    /// "3 sessions today?"
    var title: String {
        slots.count == 1 ? "A session today?" : "\(slots.count) sessions today?"
    }

    /// "Free slots at 10:00, 14:00 and 17:30 would cover your 4h goal."
    func body(locale: Locale = .current, calendar: Calendar = .current) -> String {
        let times = HabitFormat.list(slots.map { HabitFormat.time($0, locale: locale, calendar: calendar) })
        let opening: String
        switch (fromCalendar, slots.count == 1) {
        case (true, true):   opening = "A free slot at \(times)"
        case (true, false):  opening = "Free slots at \(times)"
        case (false, true):  opening = "A session at \(times)"
        case (false, false): opening = "Sessions at \(times)"
        }
        let goal = FocusGoal.format(minutes: goalMinutes)
        let remaining = goalMinutes - focusedMinutes
        let planned = slots.count * sessionMinutes
        let what = focusedMinutes > 0 ? "the rest of your \(goal) goal" : "your \(goal) goal"
        if planned >= remaining { return "\(opening) would cover \(what)." }
        return "\(opening) would add \(HabitFormat.amount(minutes: planned)) toward your \(goal) goal."
    }
}
