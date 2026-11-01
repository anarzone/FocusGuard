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
                           focusedMinutes: focusedMinutes, fromCalendar: busy != nil, warmUp: warmUp)
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
        if warmUp != nil && slots.count == 1 { return "A session before your first call?" }
        return slots.count == 1 ? "A session today?" : "\(slots.count) sessions today?"
    }

    /// "Free slots at 10:00, 14:00 and 17:30 would cover your 4h goal."
    func body(locale: Locale = .current, calendar: Calendar = .current) -> String {
        func time(_ date: Date) -> String { HabitFormat.time(date, locale: locale, calendar: calendar) }
        let others = slots.filter { $0 != warmUp?.start }
        let times = HabitFormat.list(others.map(time))
        let goal = FocusGoal.format(minutes: goalMinutes)
        let remaining = goalMinutes - focusedMinutes
        let planned = others.count * sessionMinutes + (warmUp?.minutes ?? 0)
        let what = focusedMinutes > 0 ? "the rest of your \(goal) goal" : "your \(goal) goal"
        let ending = planned >= remaining ? "would cover \(what)."
            : "would add \(HabitFormat.amount(minutes: planned)) toward your \(goal) goal."

        if let warmUp {
            let first = "A \(warmUp.minutes)-minute session at \(time(warmUp.start)), before your \(time(warmUp.call)) call."
            guard !others.isEmpty else { return first }
            let slotWords = fromCalendar ? (others.count == 1 ? "a free slot" : "free slots")
                : (others.count == 1 ? "a session" : "sessions")
            return "\(first) Then \(slotWords) at \(times) \(ending)"
        }
        let opening: String
        switch (fromCalendar, others.count == 1) {
        case (true, true):   opening = "A free slot at \(times)"
        case (true, false):  opening = "Free slots at \(times)"
        case (false, true):  opening = "A session at \(times)"
        case (false, false): opening = "Sessions at \(times)"
        }
        return "\(opening) \(ending)"
    }
}
