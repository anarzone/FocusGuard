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
    /// The weekly coach's session before the first call, when it's on and
    /// fits: one of `slots`, shorter than the rest.
    var warmUp: WarmUp?
    /// Whether the calendar has anything in it today, so the slots go around something.
    var hasMeetings = false

    struct WarmUp: Equatable {
        let start: Date
        let minutes: Int
        /// When the day's first call starts.
        let call: Date
    }

    /// Nil when today's goal is already met or nothing fits before evening.
    /// - Parameters:
    ///   - busy: today's calendar events; nil when the calendar can't be read.
    ///   - warmUpMinutes: a session this long right before the first call
    ///     (a weekly coach experiment), when there's room for it.
    static func make(now: Date, focusedMinutes: Int, goalMinutes: Int, sessionMinutes: Int,
                     busy: [DateInterval]?, warmUpMinutes: Int? = nil, calendar: Calendar = .current) -> MorningPlan? {
        let remaining = goalMinutes - focusedMinutes
        guard remaining > 0, sessionMinutes > 0 else { return nil }
        guard let dayEnd = calendar.date(bySettingHour: HabitSchedule.dayEndHour, minute: 0, second: 0, of: now) else { return nil }
        let start = now.addingTimeInterval(HabitSchedule.slotLead)
        guard dayEnd > start else { return nil }
        let warmUp = warmUpMinutes.flatMap { Self.slotBeforeFirstCall(minutes: $0, busy: busy ?? [], from: start, calendar: calendar) }

        let rest = remaining - (warmUp?.minutes ?? 0)
        let wanted = rest > 0
            ? min(HabitSchedule.maxSessions - (warmUp == nil ? 0 : 1), Int((Double(rest) / Double(sessionMinutes)).rounded(.up)))
            : 0
        let length = TimeInterval(sessionMinutes * 60)
        let breakLength = TimeInterval(AppState.suggestedBreakMinutes(forSessionMinutes: sessionMinutes) * 60)
        let taken = warmUp.map { [DateInterval(start: $0.start, end: $0.call)] } ?? []
        let others = wanted > 0
            ? FreeSlots.find(busy: (busy ?? []) + taken, in: DateInterval(start: start, end: dayEnd), length: length,
                             count: wanted, breakLength: breakLength, calendar: calendar)
            : []
        let slots = ([warmUp?.start].compactMap { $0 } + others).sorted()
        guard !slots.isEmpty else { return nil }
        return MorningPlan(slots: slots, sessionMinutes: sessionMinutes, goalMinutes: goalMinutes,
                           focusedMinutes: focusedMinutes, fromCalendar: busy != nil, warmUp: warmUp,
                           hasMeetings: busy?.isEmpty == false)
    }

    /// A session of `minutes` ending as the first call after `from` starts,
    /// on a 5-minute mark, when nothing else is in the way.
    static func slotBeforeFirstCall(minutes: Int, busy: [DateInterval], from: Date, calendar: Calendar) -> WarmUp? {
        guard let call = busy.filter({ $0.start >= from && calendar.isDate($0.start, inSameDayAs: from) })
            .min(by: { $0.start < $1.start }) else { return nil }
        let latest = call.start.addingTimeInterval(-TimeInterval(minutes * 60))
        let mark = calendar.dateComponents([.minute], from: latest).minute ?? 0
        let start = latest.addingTimeInterval(-TimeInterval((mark % 5) * 60))
            .addingTimeInterval(-TimeInterval(calendar.component(.second, from: latest)))
        guard start >= from, !busy.contains(where: { $0.start < call.start && $0.end > start }) else { return nil }
        return WarmUp(start: start, minutes: minutes, call: call.start)
    }

    /// "3 sessions today?"
    var title: String {
        if warmUp != nil && slots.count == 1 { return String(localized: "A session before your first call?") }
        return slots.count == 1 ? String(localized: "A session today?") : String(localized: "\(slots.count) sessions today?", comment: "The count is 2 or more")
    }

    /// The card's line: "Free at 9:30, 11:00 and 14:30, around your meetings."
    func shortBody(locale: Locale = .current, calendar: Calendar = .current) -> String {
        let times = HabitFormat.list(slots.map { HabitFormat.time($0, locale: locale, calendar: calendar) })
        guard fromCalendar else { return String(localized: "Try \(times).", comment: "Session times spread over the day; the calendar can't be read") }
        return hasMeetings ? String(localized: "Free at \(times), around your meetings.") : String(localized: "Free at \(times).")
    }

    /// "Free slots at 10:00, 14:00 and 17:30 would cover your 4h goal."
    func body(locale: Locale = .current, calendar: Calendar = .current) -> String {
        func time(_ date: Date) -> String { HabitFormat.time(date, locale: locale, calendar: calendar) }
        let others = slots.filter { $0 != warmUp?.start }
        let times = HabitFormat.list(others.map(time))
        let goal = FocusGoal.format(minutes: goalMinutes)
        let remaining = goalMinutes - focusedMinutes
        let planned = others.count * sessionMinutes + (warmUp?.minutes ?? 0)
        let ending: Ending = planned < remaining ? .adds(HabitFormat.amount(minutes: planned))
            : (focusedMinutes > 0 ? .coversRest : .covers)

        if let warmUp {
            let first = String(localized: "A \(warmUp.minutes)-minute session at \(time(warmUp.start)), before your \(time(warmUp.call)) call.")
            guard !others.isEmpty else { return first }
            let rest = Self.thenSentence(fromCalendar: fromCalendar, single: others.count == 1, times: times, goal: goal, ending: ending)
            return "\(first) \(rest)"
        }
        return Self.sentence(fromCalendar: fromCalendar, single: others.count == 1, times: times, goal: goal, ending: ending)
    }

    /// What the slots would do for the goal.
    private enum Ending {
        case coversRest, covers
        case adds(String)
    }

    // Every case is a whole sentence: the verb agrees with what the slots are
    // called, and in German "Then" moves it.

    /// "Free slots at 10:00 and 14:00 would cover your 4h goal."
    private static func sentence(fromCalendar: Bool, single: Bool, times: String, goal: String, ending: Ending) -> String {
        switch (fromCalendar, single, ending) {
        case (true, true, .coversRest): return String(localized: "A free slot at \(times) would cover the rest of your \(goal) goal.")
        case (true, true, .covers): return String(localized: "A free slot at \(times) would cover your \(goal) goal.")
        case (true, true, .adds(let amount)): return String(localized: "A free slot at \(times) would add \(amount) toward your \(goal) goal.")
        case (true, false, .coversRest): return String(localized: "Free slots at \(times) would cover the rest of your \(goal) goal.")
        case (true, false, .covers): return String(localized: "Free slots at \(times) would cover your \(goal) goal.")
        case (true, false, .adds(let amount)): return String(localized: "Free slots at \(times) would add \(amount) toward your \(goal) goal.")
        case (false, true, .coversRest): return String(localized: "A session at \(times) would cover the rest of your \(goal) goal.")
        case (false, true, .covers): return String(localized: "A session at \(times) would cover your \(goal) goal.")
        case (false, true, .adds(let amount)): return String(localized: "A session at \(times) would add \(amount) toward your \(goal) goal.")
        case (false, false, .coversRest): return String(localized: "Sessions at \(times) would cover the rest of your \(goal) goal.")
        case (false, false, .covers): return String(localized: "Sessions at \(times) would cover your \(goal) goal.")
        case (false, false, .adds(let amount)): return String(localized: "Sessions at \(times) would add \(amount) toward your \(goal) goal.")
        }
    }

    /// "Then free slots at 11:30 and 14:00 would cover your 4h goal."
    private static func thenSentence(fromCalendar: Bool, single: Bool, times: String, goal: String, ending: Ending) -> String {
        switch (fromCalendar, single, ending) {
        case (true, true, .coversRest): return String(localized: "Then a free slot at \(times) would cover the rest of your \(goal) goal.")
        case (true, true, .covers): return String(localized: "Then a free slot at \(times) would cover your \(goal) goal.")
        case (true, true, .adds(let amount)): return String(localized: "Then a free slot at \(times) would add \(amount) toward your \(goal) goal.")
        case (true, false, .coversRest): return String(localized: "Then free slots at \(times) would cover the rest of your \(goal) goal.")
        case (true, false, .covers): return String(localized: "Then free slots at \(times) would cover your \(goal) goal.")
        case (true, false, .adds(let amount)): return String(localized: "Then free slots at \(times) would add \(amount) toward your \(goal) goal.")
        case (false, true, .coversRest): return String(localized: "Then a session at \(times) would cover the rest of your \(goal) goal.")
        case (false, true, .covers): return String(localized: "Then a session at \(times) would cover your \(goal) goal.")
        case (false, true, .adds(let amount)): return String(localized: "Then a session at \(times) would add \(amount) toward your \(goal) goal.")
        case (false, false, .coversRest): return String(localized: "Then sessions at \(times) would cover the rest of your \(goal) goal.")
        case (false, false, .covers): return String(localized: "Then sessions at \(times) would cover your \(goal) goal.")
        case (false, false, .adds(let amount)): return String(localized: "Then sessions at \(times) would add \(amount) toward your \(goal) goal.")
        }
    }
}
