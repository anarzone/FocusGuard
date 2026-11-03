import Foundation

/// One change the coach suggests for a week. Each is something FocusGuard
/// applies by itself, and undoes when the week ends unless it's kept.
enum CoachExperiment: Codable, Hashable, Sendable {
    /// A daily limit on a site.
    case siteLimit(host: String, minutes: Int)
    /// Sessions started in these hours default to a shorter length.
    case shorterSessions(CoachHours, minutes: Int)
    /// A stricter preset while these hours last.
    case stricterPreset(CoachHours, DriftResponse)
    /// The morning plan arrives at this hour instead.
    case earlierMorningPlan(hour: Int)
    /// Every session starts at this length.
    case sessionLength(minutes: Int)
    /// The morning plan puts a session this long right before the day's
    /// first call on the calendar.
    case sessionBeforeFirstCall(minutes: Int)
    /// One weekday (1 is Sunday) gets a goal of its own.
    case weekdayGoal(weekday: Int, minutes: Int)

    /// "A 20-minute daily limit on x.com", for the "Try this week" card.
    func title(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case let .siteLimit(host, minutes):
            return String(localized: "A \(minutes)-minute daily limit on \(host)")
        case let .shorterSessions(hours, minutes):
            let when = hours.phrase(locale: locale, calendar: calendar)
            return String(localized: "\(minutes)-minute sessions \(when)", comment: "When: after 17:00")
        case let .stricterPreset(hours, preset):
            let when = hours.phrase(locale: locale, calendar: calendar)
            return String(localized: "\(preset.title) \(when)", comment: "A preset's name, then when: Strict after 17:00")
        case let .earlierMorningPlan(hour):
            let time = Self.clock(hour, locale: locale, calendar: calendar)
            return String(localized: "The morning plan at \(time)")
        case let .sessionLength(minutes):
            return String(localized: "\(minutes) minutes as your session length")
        case let .sessionBeforeFirstCall(minutes):
            return String(localized: "A \(minutes)-minute session before your first call")
        case let .weekdayGoal(weekday, minutes):
            let days = Self.weekdays(weekday, locale: locale, calendar: calendar)
            if minutes % 60 == 0 {
                let hours = minutes / 60
                return String(localized: "A \(hours)-hour goal on \(days)", comment: "Mondays")
            }
            let goal = FocusGoal.format(minutes: minutes)
            return String(localized: "A \(goal) goal on \(days)", comment: "A compact duration such as 1h 30m, then Mondays")
        }
    }

    /// "shorter evening sessions", for "Last week's experiment, …: +9 pts".
    /// A noun phrase that goes inside other sentences.
    func shortName(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case let .siteLimit(host, minutes):
            return String(localized: "a \(minutes)-minute limit on \(host)", comment: "Goes inside a sentence: The experiment was ...")
        case let .shorterSessions(hours, _):
            switch hours {
            case .morning:   return String(localized: "shorter morning sessions", comment: "Goes inside a sentence: The experiment was ...")
            case .afternoon: return String(localized: "shorter afternoon sessions", comment: "Goes inside a sentence: The experiment was ...")
            case .evening:   return String(localized: "shorter evening sessions", comment: "Goes inside a sentence: The experiment was ...")
            default:
                let when = hours.phrase(locale: locale, calendar: calendar)
                return String(localized: "shorter sessions \(when)", comment: "Goes inside a sentence: The experiment was ... When: after 17:00")
            }
        case let .stricterPreset(hours, preset):
            let when = hours.phrase(locale: locale, calendar: calendar)
            return String(localized: "\(preset.title) \(when)", comment: "A preset's name, then when: Strict after 17:00")
        case .earlierMorningPlan:
            return String(localized: "an earlier morning plan", comment: "Goes inside a sentence: The experiment was ...")
        case let .sessionLength(minutes):
            return String(localized: "\(minutes)-minute sessions", comment: "Goes inside a sentence: The experiment was ...")
        case .sessionBeforeFirstCall:
            return String(localized: "a session before the first call", comment: "Goes inside a sentence: The experiment was ...")
        case let .weekdayGoal(weekday, _):
            let days = Self.weekdays(weekday, locale: locale, calendar: calendar)
            return String(localized: "a lower goal on \(days)", comment: "Goes inside a sentence: The experiment was ... Mondays")
        }
    }

    /// What changes, once it's on: "Sessions after 17:00 start at 25 minutes."
    func effect(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case let .siteLimit(host, minutes):
            return String(localized: "\(host) is blocked after \(minutes) minutes a day.")
        case let .shorterSessions(hours, minutes):
            let when = hours.phrase(locale: locale, calendar: calendar)
            return String(localized: "Sessions \(when) start at \(minutes) minutes.", comment: "When: after 17:00")
        case let .stricterPreset(hours, preset):
            let when = hours.phrase(locale: locale, calendar: calendar)
            return String(localized: "Sessions use \(preset.title) \(when).", comment: "A preset's name, then when: Strict after 17:00")
        case let .earlierMorningPlan(hour):
            let time = Self.clock(hour, locale: locale, calendar: calendar)
            return String(localized: "The morning plan arrives at \(time).")
        case let .sessionLength(minutes):
            return String(localized: "Sessions start at \(minutes) minutes.")
        case let .sessionBeforeFirstCall(minutes):
            return String(localized: "The morning plan puts a \(minutes)-minute session before your first call.")
        case let .weekdayGoal(weekday, minutes):
            let days = Self.weekdays(weekday, locale: locale, calendar: calendar)
            let goal = FocusGoal.format(minutes: minutes)
            return String(localized: "The goal on \(days) is \(goal).", comment: "Mondays, then a compact duration")
        }
    }

    /// How the result is measured.
    var metric: CoachMetric {
        switch self {
        case let .siteLimit(host, _):         return .siteMinutes(host)
        case let .shorterSessions(hours, _):  return .sessionRate(hours)
        case let .stricterPreset(hours, _):   return .sessionRate(hours)
        case .earlierMorningPlan:             return .firstSession
        case .sessionLength:                  return .sessionRate(.allDay)
        case .sessionBeforeFirstCall:         return .callDayFocus
        case let .weekdayGoal(weekday, _):    return .weekdayFocus(weekday)
        }
    }

    /// Whether this and `other` change the same setting, so only one can be on.
    func overlaps(_ other: CoachExperiment) -> Bool {
        switch (self, other) {
        case let (.siteLimit(a, _), .siteLimit(b, _)):
            return a == b
        case let (.shorterSessions(a, _), .shorterSessions(b, _)),
             let (.stricterPreset(a, _), .stricterPreset(b, _)):
            return a.from < b.to && b.from < a.to
        case (.earlierMorningPlan, .earlierMorningPlan),
             (.sessionLength, .sessionLength), (.sessionLength, .shorterSessions), (.shorterSessions, .sessionLength),
             (.sessionBeforeFirstCall, .sessionBeforeFirstCall):
            return true
        case let (.weekdayGoal(a, _), .weekdayGoal(b, _)):
            return a == b
        default:
            return false
        }
    }

    static func clock(_ hour: Int, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 0)) ?? .now
        return HabitFormat.time(date, locale: locale, calendar: calendar)
    }

    /// "Fridays", for a `Calendar` weekday.
    static func weekdays(_ number: Int, locale: Locale = .current, calendar: Calendar = .current) -> String {
        FocusGoal.pluralWeekday(number, locale: locale, calendar: calendar)
    }
}

extension DriftResponse: Codable {
    /// Gentle 0, Standard 1, Strict 2.
    var strictness: Int {
        switch self {
        case .gentle:   return 0
        case .standard: return 1
        case .strict:   return 2
        }
    }

    /// The next preset up, or nil on Strict.
    var stricter: DriftResponse? {
        switch self {
        case .gentle:   return .standard
        case .standard: return .strict
        case .strict:   return nil
        }
    }
}

/// What an experiment is measured by, on the week it ran against the week
/// it came from.
enum CoachMetric: Codable, Hashable, Sendable {
    /// The focus rate of sessions started in these hours (0...1).
    case sessionRate(CoachHours)
    /// Average minutes a day on a site, over days with anything tracked.
    case siteMinutes(String)
    /// The day's first session, on average, in minutes after midnight.
    case firstSession
    /// Average focused seconds a day over days with 3 hours of calls or more.
    case callDayFocus
    /// Average focused seconds on this weekday (1 is Sunday), over the ones
    /// with anything tracked.
    case weekdayFocus(Int)

    /// Nil when there's too little to tell.
    func measure(_ data: CoachData, calendar: Calendar = .current) -> Double? {
        switch self {
        case .callDayFocus:
            let focus = data.focusByDay(calendar: calendar)
            let days = data.callSecondsByDay(calendar: calendar)
                .filter { $0.value >= CoachPatternFinder.callHeavySeconds }.keys
            guard !days.isEmpty else { return nil }
            return days.reduce(0) { $0 + (focus[$1] ?? 0) } / Double(days.count)
        case .weekdayFocus(let weekday):
            let focus = data.focusByDay(calendar: calendar)
            let days = data.activeDays(calendar: calendar).filter { calendar.component(.weekday, from: $0) == weekday }
            guard !days.isEmpty else { return nil }
            return days.reduce(0) { $0 + (focus[$1] ?? 0) } / Double(days.count)
        case .sessionRate(let hours):
            let sessions = Set(data.sessions.filter { hours.contains($0.start, calendar: calendar) }.map(\.id))
            let tally = CoachData.tally(data.events.filter { $0.session.map(sessions.contains) == true })
            guard sessions.count >= 2, tally.focus + tally.drift >= 10 * 60 else { return nil }
            return FocusRate.of(focused: tally.focus, drifted: tally.drift)
        case .siteMinutes(let host):
            let days = data.activeDays(calendar: calendar).count
            guard days >= 2 else { return nil }
            let seconds = data.events.filter { $0.isSite && Classifier.host($0.target, matches: host) }
                .reduce(0) { $0 + $1.duration }
            return seconds / 60 / Double(days)
        case .firstSession:
            let firsts = Dictionary(grouping: data.sessions) { calendar.startOfDay(for: $0.start) }
                .compactMapValues { $0.map(\.start).min() }.values
            guard firsts.count >= 2 else { return nil }
            let minutes = firsts.map { first -> Double in
                let parts = calendar.dateComponents([.hour, .minute], from: first)
                return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
            return minutes.reduce(0, +) / Double(minutes.count)
        }
    }

    /// "+9 pts", "41 → 18 min a day", "22 min earlier".
    func change(from before: Double, to after: Double) -> String {
        switch self {
        case .sessionRate:
            return Self.points(from: before, to: after)
        case .siteMinutes:
            let then = Int(before.rounded()), now = Int(after.rounded())
            return String(localized: "\(then) → \(now) min a day")
        case .firstSession:
            let minutes = Int((before - after).rounded())
            if abs(minutes) < 5 { return String(localized: "about the same start") }
            let amount = HabitFormat.amount(minutes: abs(minutes))
            return minutes > 0 ? String(localized: "first session \(amount) earlier") : String(localized: "first session \(amount) later")
        case .callDayFocus:
            let then = CoachDraft.duration(before), now = CoachDraft.duration(after)
            return String(localized: "\(then) → \(now) focused on call-heavy days")
        case .weekdayFocus(let weekday):
            let then = CoachDraft.duration(before), now = CoachDraft.duration(after)
            let days = CoachExperiment.weekdays(weekday)
            return String(localized: "\(then) → \(now) focused on \(days)", comment: "Two compact durations, then Mondays")
        }
    }

    /// A change in focus rate: "+9 pts", "−3 pts", "no change".
    static func points(from before: Double, to after: Double) -> String {
        let points = Int((after * 100).rounded()) - Int((before * 100).rounded())
        if points == 0 { return String(localized: "no change") }
        let moved = abs(points)
        return points > 0 ? String(localized: "+\(moved) pts", comment: "Focus rate points, compact") : String(localized: "−\(moved) pts", comment: "Focus rate points, compact")
    }

    /// `change` says nothing moved: the same rate, about the same start, or
    /// the same figure on both sides of the arrow.
    func isUnchanged(from before: Double, to after: Double) -> Bool {
        switch self {
        case .sessionRate:  return Int((after * 100).rounded()) == Int((before * 100).rounded())
        case .firstSession: return abs(Int((before - after).rounded())) < 5
        case .siteMinutes:  return Int(before.rounded()) == Int(after.rounded())
        case .callDayFocus, .weekdayFocus: return CoachDraft.duration(before) == CoachDraft.duration(after)
        }
    }

    /// Whether `after` is better than `before`.
    func improved(from before: Double, to after: Double) -> Bool {
        switch self {
        case .sessionRate, .callDayFocus, .weekdayFocus: return after > before
        case .siteMinutes, .firstSession:                return after < before
        }
    }
}

/// What the experiment planner needs to know about the current settings,
/// so it never suggests what's already there or can't be done.
struct CoachSettings: Equatable, Sendable {
    /// Hosts that already have a daily limit.
    var limitedSites: Set<String> = []
    var preset: DriftResponse = .standard
    var morningPlanHour = 9
    /// Experiments running or kept; a new one mustn't overlap them.
    var inPlace: [CoachExperiment] = []
    /// The length a session starts at.
    var sessionMinutes = 50
    /// The daily goal, and the weekdays with one of their own (1 is Sunday).
    var dailyGoal = GoalDefaults.dailyFocusMinutes
    var weekdayGoals: [Int: Int] = [:]
    /// Whether the calendar can be read, so the morning plan knows the first call.
    var canReadCalendar = false
    var morningPlanOn = true
}

/// Turns a finding into one experiment the app can apply.
enum CoachPlanner {
    /// The shortest length the coach suggests.
    static let shortMinutes = 25
    /// The earliest morning plan the coach suggests.
    static let earliestMorningHour = 7

    /// The first experiment that fits a finding, or nil.
    static func experiment(for finding: CoachFinding, settings: CoachSettings) -> CoachExperiment? {
        candidates(for: finding, settings: settings).first { candidate in
            !settings.inPlace.contains { $0.overlaps(candidate) }
        }
    }

    /// The strongest finding with an experiment, and that experiment. When
    /// none has one, the strongest finding alone.
    static func plan(_ findings: [CoachFinding], settings: CoachSettings) -> (CoachFinding, CoachExperiment?)? {
        for finding in findings {
            if let experiment = Self.experiment(for: finding, settings: settings) { return (finding, experiment) }
        }
        return findings.first.map { ($0, nil) }
    }

    static func candidates(for finding: CoachFinding, settings: CoachSettings) -> [CoachExperiment] {
        switch finding {
        case .timeOfDay(let f):
            let shorter = CoachExperiment.shorterSessions(f.weak, minutes: shortMinutes)
            let longSessions = f.weakMinutes >= shortMinutes + 10
            let stricter = settings.preset.stricter.map { CoachExperiment.stricterPreset(f.weak, $0) }
            // Drift that comes late in long sessions is a length problem;
            // drift all through them is one for the preset.
            if longSessions && f.lateDriftShare >= 0.5 { return [shorter] + [stricter].compactMap { $0 } }
            return [stricter].compactMap { $0 } + (longSessions ? [shorter] : [])
        case .afterSessions(let f):
            return f.isSite ? limit(on: f.target, dailySeconds: f.dailySeconds, settings: settings) : []
        case .driftDay(let f):
            return f.isSite ? limit(on: f.target, dailySeconds: f.dailySeconds, settings: settings) : []
        case .lateStarts:
            guard settings.morningPlanHour > earliestMorningHour else { return [] }
            return [.earlierMorningPlan(hour: settings.morningPlanHour - 1)]
        case .switching(let f):
            return [settings.preset.stricter.map { CoachExperiment.stricterPreset(f.hours, $0) }].compactMap { $0 }
        case .sessionLength(let f):
            return settings.sessionMinutes > f.minutes ? [.sessionLength(minutes: f.minutes)] : []
        case .meetingDays:
            // The first call comes from the calendar, and the morning plan places the session.
            guard settings.canReadCalendar, settings.morningPlanOn else { return [] }
            return [.sessionBeforeFirstCall(minutes: shortMinutes)]
        case .appChain(let f):
            return f.isSite ? limit(on: f.target, dailySeconds: f.dailySeconds, settings: settings) : []
        case .weeklyRhythm(let f):
            let goal = settings.weekdayGoals[f.weekday] ?? settings.dailyGoal
            let minutes = Self.weekdayGoal(focus: f.focus)
            return minutes <= goal - 30 ? [.weekdayGoal(weekday: f.weekday, minutes: minutes)] : []
        }
    }

    /// A goal around what the weekday usually manages: its average focus to
    /// the nearest 15 minutes, half an hour at least.
    static func weekdayGoal(focus: TimeInterval) -> Int {
        max(30, Int((focus / 60 / 15).rounded()) * 15)
    }

    /// A limit around 60% of the site's usual daily time, in 5-minute
    /// steps from 10 to 60 minutes. Nothing for a site that already has one
    /// or gets under 15 minutes a day.
    static func limit(on host: String, dailySeconds: TimeInterval, settings: CoachSettings) -> [CoachExperiment] {
        guard dailySeconds >= 15 * 60,
              !settings.limitedSites.contains(where: { Classifier.host(host, matches: $0) }) else { return [] }
        let minutes = Int((dailySeconds / 60 * 0.6 / 5).rounded()) * 5
        return [.siteLimit(host: host, minutes: min(60, max(10, minutes)))]
    }
}
