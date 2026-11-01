import Foundation

/// The evening notification: "Today: 3h 40m focused. 20 minutes short of
/// your 4h goal. Best stretch: Comeback Run, 14:05–14:55. Best time to start
/// tomorrow: 10:00." With a tip for tomorrow it reads "Day done: goal met",
/// "3h 12m focused at 86%." and the tip, and gets a button that plans it.
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
    /// Today's focus rate, in percent, when there was anything to rate.
    var focusPercent: Int?
    /// One thing to set up for tomorrow.
    var tip: EveningTip?

    var goalHit: Bool { focusedMinutes >= goalMinutes }

    /// "Goal hit: 4h 25m focused", "Today: 3h 40m focused"; with a tip,
    /// "Day done: goal met", "Day done: 1h 40m of 4h".
    var title: String {
        let focused = FocusGoal.format(minutes: focusedMinutes)
        if tip != nil {
            return goalHit ? "Day done: goal met" : "Day done: \(focused) of \(FocusGoal.format(minutes: goalMinutes))"
        }
        return goalHit ? "Goal hit: \(focused) focused" : "Today: \(focused) focused"
    }

    func body(locale: Locale = .current, calendar: Calendar = .current) -> String {
        func time(_ date: Date) -> String { HabitFormat.time(date, locale: locale, calendar: calendar) }
        let bestStretch = best.map { "Best stretch: \($0.name), \(time($0.start))–\(time($0.end))." }
        if let tip {
            if goalHit {
                var sentences = ["\(FocusGoal.format(minutes: focusedMinutes)) focused\(focusPercent.map { " at \($0)%" } ?? "")."]
                if streak >= 2 { sentences.append("That's \(streak) days in a row.") }
                return (sentences + [tip.text]).joined(separator: " ")
            }
            // The title has the numbers; a plain "best time" tip gets the best stretch beside it.
            return ((tip.kind == .bestStart ? [bestStretch].compactMap { $0 } : []) + [tip.text]).joined(separator: " ")
        }

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
        } else if let bestStretch {
            sentences.append(bestStretch)
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

/// The wrap-up's one thing for tomorrow, found by fixed rules over tracked
/// time (the weekly coach's, where they fit a single day), with the
/// session its button plans.
struct EveningTip: Equatable {
    enum Kind: Equatable {
        /// Most of today's drift came from one hour on: hold that hour tomorrow.
        case driftHour
        /// Days that start early focus more (the coach's late starts).
        case startEarlier
        /// Just the best time to start tomorrow.
        case bestStart
    }

    let kind: Kind
    /// "Tomorrow, start before 10:00: your early days focused 1h 10m more."
    let text: String
    /// The session the button plans, tomorrow.
    let slot: Date
    /// "Plan it for 15:00", "Plan tomorrow".
    let button: String

    /// The first rule that has something to say. A missed goal looks at
    /// today's drift first; a met one at how the day started.
    /// - Parameters:
    ///   - today: today so far.
    ///   - recent: the last two weeks, today included.
    ///   - gapMinutes: how far short of today's goal; 0 or less when met.
    ///   - tomorrowStart: the wrap-up's best time to start tomorrow.
    ///   - sessionMinutes: the length a session starts at.
    ///   - morningHour: when the morning plan starts going out; a first
    ///     session an hour after it counts as late.
    static func choose(today: CoachData, recent: CoachData, gapMinutes: Int, tomorrowStart: Date?,
                       sessionMinutes: Int, morningHour: Int, now: Date,
                       locale: Locale = .current, calendar: Calendar = .current) -> EveningTip? {
        let goalMet = gapMinutes <= 0
        if !goalMet, let tip = driftHour(today: today, gapMinutes: gapMinutes, sessionMinutes: sessionMinutes,
                                         now: now, locale: locale, calendar: calendar) {
            return tip
        }
        if let tip = startEarlier(today: today, recent: recent, goalMet: goalMet, morningHour: morningHour,
                                  tomorrowStart: tomorrowStart, now: now, locale: locale, calendar: calendar) {
            return tip
        }
        guard let tomorrowStart else { return nil }
        let clock = HabitFormat.time(tomorrowStart, locale: locale, calendar: calendar)
        return EveningTip(kind: .bestStart, text: "Best time to start tomorrow: \(clock).",
                          slot: tomorrowStart, button: "Plan it for \(clock)")
    }

    /// The hour (07:00 to 19:00) today's drift peaked in, when one
    /// distraction took 20 minutes or more from then on.
    static func driftHour(today: CoachData, gapMinutes: Int, sessionMinutes: Int, now: Date,
                          locale: Locale = .current, calendar: Calendar = .current) -> EveningTip? {
        let drift = today.events.filter { $0.kind == .distraction }
        var byHour = [TimeInterval](repeating: 0, count: 24)
        for event in drift { byHour[calendar.component(.hour, from: event.start)] += event.duration }
        guard let hour = (7..<HabitSchedule.dayEndHour).max(by: { (byHour[$0], $1) < (byHour[$1], $0) }),
              byHour[hour] >= 10 * 60,
              let from = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) else { return nil }
        let after = drift.filter { $0.start >= from }
        let byTarget = Dictionary(grouping: after, by: \.target).mapValues { $0.reduce(0) { $0 + $1.duration } }
        guard let top = byTarget.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value >= 20 * 60,
              let name = after.first(where: { $0.target == top.key })?.name,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) else { return nil }
        let clock = HabitFormat.time(slot, locale: locale, calendar: calendar)
        let lead = top.value * 2 >= TimeInterval(gapMinutes * 60)
            ? "Most of the gap was \(name) after \(clock)."
            : "\(name) took \(HabitFormat.amount(minutes: Int(top.value / 60))) after \(clock)."
        return EveningTip(kind: .driftHour,
                          text: "\(lead) Tomorrow, a \(sessionMinutes)-minute session at \(clock) holds that hour.",
                          slot: slot, button: "Plan it for \(clock)")
    }

    /// The coach's late starts over `recent`. On a missed day only when
    /// today started late too.
    static func startEarlier(today: CoachData, recent: CoachData, goalMet: Bool, morningHour: Int,
                             tomorrowStart: Date?, now: Date,
                             locale: Locale = .current, calendar: Calendar = .current) -> EveningTip? {
        let cutoff = (morningHour + 1) * 60
        func minutes(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        guard case .lateStarts(let f)? = CoachPatternFinder.lateStarts(recent, cutoff: cutoff, calendar: calendar) else {
            return nil
        }
        if !goalMet, let first = today.sessions.map(\.start).min(), minutes(first) < cutoff { return nil }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow) else { return nil }
        // The best time to start, when it's early enough; else the morning plan's hour.
        let slot = tomorrowStart.flatMap { minutes($0) < cutoff && minutes($0) >= 7 * 60 ? $0 : nil } ?? morning
        let before = CoachDraft.clock(minutes: cutoff, locale: locale, calendar: calendar)
        return EveningTip(kind: .startEarlier,
                          text: "Tomorrow, start before \(before): your early days focused \(CoachDraft.duration(f.earlyFocus - f.lateFocus)) more.",
                          slot: slot,
                          button: goalMet ? "Plan tomorrow" : "Plan it for \(HabitFormat.time(slot, locale: locale, calendar: calendar))")
    }
}
