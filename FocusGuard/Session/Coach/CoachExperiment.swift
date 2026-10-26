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

    /// "A 20-minute daily limit on x.com", for the "Try this week" card.
    func title(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case let .siteLimit(host, minutes):
            return "A \(minutes)-minute daily limit on \(host)"
        case let .shorterSessions(hours, minutes):
            return "\(minutes)-minute sessions \(hours.phrase(locale: locale, calendar: calendar))"
        case let .stricterPreset(hours, preset):
            return "\(preset.title) \(hours.phrase(locale: locale, calendar: calendar))"
        case let .earlierMorningPlan(hour):
            return "The morning plan at \(Self.clock(hour, locale: locale, calendar: calendar))"
        }
    }

    /// "shorter evening sessions", for "Last week's experiment, …: +9 pts".
    func shortName(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case let .siteLimit(host, minutes):
            return "a \(minutes)-minute limit on \(host)"
        case let .shorterSessions(hours, _):
            return hours.partOfDay.map { "shorter \($0) sessions" }
                ?? "shorter sessions \(hours.phrase(locale: locale, calendar: calendar))"
        case let .stricterPreset(hours, preset):
            return "\(preset.title) \(hours.phrase(locale: locale, calendar: calendar))"
        case .earlierMorningPlan:
            return "an earlier morning plan"
        }
    }

    /// What changes, once it's on: "Sessions after 17:00 start at 25 minutes."
    func effect(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case let .siteLimit(host, minutes):
            return "\(host) is blocked after \(minutes) minutes a day."
        case let .shorterSessions(hours, minutes):
            return "Sessions \(hours.phrase(locale: locale, calendar: calendar)) start at \(minutes) minutes."
        case let .stricterPreset(hours, preset):
            return "Sessions use \(preset.title) \(hours.phrase(locale: locale, calendar: calendar))."
        case let .earlierMorningPlan(hour):
            return "The morning plan arrives at \(Self.clock(hour, locale: locale, calendar: calendar))."
        }
    }

    /// How the result is measured.
    var metric: CoachMetric {
        switch self {
        case let .siteLimit(host, _):         return .siteMinutes(host)
        case let .shorterSessions(hours, _):  return .sessionRate(hours)
        case let .stricterPreset(hours, _):   return .sessionRate(hours)
        case .earlierMorningPlan:             return .firstSession
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
        case (.earlierMorningPlan, .earlierMorningPlan):
            return true
        default:
            return false
        }
    }

    static func clock(_ hour: Int, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 0)) ?? .now
        return HabitFormat.time(date, locale: locale, calendar: calendar)
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

    /// Nil when there's too little to tell.
    func measure(_ data: CoachData, calendar: Calendar = .current) -> Double? {
        switch self {
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
            return "\(Int(before.rounded())) → \(Int(after.rounded())) min a day"
        case .firstSession:
            let minutes = Int((before - after).rounded())
            if abs(minutes) < 5 { return "about the same start" }
            let amount = HabitFormat.amount(minutes: abs(minutes))
            return minutes > 0 ? "first session \(amount) earlier" : "first session \(amount) later"
        }
    }

    /// A change in focus rate: "+9 pts", "−3 pts", "no change".
    static func points(from before: Double, to after: Double) -> String {
        let points = Int((after * 100).rounded()) - Int((before * 100).rounded())
        if points == 0 { return "no change" }
        return points > 0 ? "+\(points) pts" : "−\(-points) pts"
    }

    /// Whether `after` is better than `before`.
    func improved(from before: Double, to after: Double) -> Bool {
        switch self {
        case .sessionRate:               return after > before
        case .siteMinutes, .firstSession: return after < before
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
        }
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
