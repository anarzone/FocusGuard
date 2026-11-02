import Foundation

/// One of "Try in November": an experiment from the month's strongest
/// patterns, and the pattern behind it.
struct MonthSuggestion: Equatable, Identifiable, Sendable {
    var id: CoachExperiment { experiment }
    let experiment: CoachExperiment
    /// "Your sessions after 17:00 are where focus slips."
    let reason: String
    /// The experiment's measure over the month, to compare the next one with.
    let baseline: Double?
}

/// A month in review (Pro): a headline, what changed against the month
/// before, and two things to try. The facts come from fixed rules over
/// tracked time; the on-device model may only reword the headline.
struct MonthReview: Equatable, Sendable {
    let month: DateInterval
    let headline: String
    let changes: [CoachPoint]
    /// Only for the month that ended last.
    let suggestions: [MonthSuggestion]
    /// Whether the on-device model worded the headline.
    let onDevice: Bool
    /// False when too little was tracked to say anything.
    let hasData: Bool

    static func empty(_ month: DateInterval) -> MonthReview {
        MonthReview(month: month, headline: "", changes: [], suggestions: [], onDevice: false, hasData: false)
    }
}

/// A line under "Your experiments": a coach experiment that ran in the month.
struct MonthTrialLine: Equatable, Identifiable {
    let id: UUID
    /// "A 50-minute daily limit on youtube.com".
    let title: String
    /// "+7 pts after 17:00", "41 → 18 min a day", "Still running".
    let result: String
    let improved: Bool
    /// "Kept on", "Turned off", "On until 30 November".
    let status: String
}

/// The month's facts, by fixed rules.
struct MonthFacts: Equatable, Sendable {
    /// "October: 83h 10m focused at an 83% focus rate, 9 points up on September."
    let headline: String
    /// What changed against the month before, three at most.
    let changes: [CoachPoint]

    /// Everything the review may say, for the model and to check what it writes.
    var facts: [String] { [headline] + changes.map(\.sentence) }

    /// Nil when the month has under an hour of focus and drift.
    static func make(_ month: CoachData, before: CoachData, locale: Locale = .current,
                     calendar: Calendar = .current) -> MonthFacts? {
        let now = CoachData.tally(month.events), then = CoachData.tally(before.events)
        guard now.focus + now.drift >= 3600 else { return nil }
        let name = monthName(month.interval.start, locale: locale, calendar: calendar)
        let previous = monthName(before.interval.start, locale: locale, calendar: calendar)
        let compares = then.focus + then.drift >= 3600

        let rate = FocusRate.of(focused: now.focus, drifted: now.drift)
        let moved = compares ? Int((rate * 100).rounded()) - Int((FocusRate.of(focused: then.focus, drifted: then.drift) * 100).rounded()) : 0
        let headline = headlineSentence(month: CoachDraft.capitalized(name), focused: CoachDraft.duration(now.focus),
                                        rate: CoachDraft.percent(rate), previous: compares ? previous : nil, points: moved)

        var changes: [CoachPoint] = []
        if compares {
            changes += partChanges(month, before: before, locale: locale, calendar: calendar)
            if let sessions = sessionChange(month, before: before) { changes.append(sessions) }
            let delta = now.focus - then.focus
            if abs(delta) >= 30 * 60 {
                let current = CoachDraft.duration(now.focus), earlier = CoachDraft.duration(then.focus)
                changes.append(delta > 0
                    ? CoachPoint(String(localized: "More focus overall.| \(current), up from \(earlier).", comment: "The | ends the bold start"), tone: .focus)
                    : CoachPoint(String(localized: "Less focus overall.| \(current), down from \(earlier).", comment: "The | ends the bold start"), tone: .drift))
            }
        } else if let best = bestPart(month, locale: locale, calendar: calendar) {
            changes.append(best)
        }
        if let top = topDistraction(month, before: compares ? before : nil, previous: previous) {
            changes.append(top)
        }
        return MonthFacts(headline: headline, changes: Array(changes.prefix(3)))
    }

    /// One whole sentence per case, since "a"/"an" and the comparison both
    /// change it.
    private static func headlineSentence(month: String, focused: String, rate: String, previous: String?, points: Int) -> String {
        let an = takesAn(rate), moved = abs(points)
        guard let previous else {
            return an ? String(localized: "\(month): \(focused) focused at an \(rate) focus rate.")
                : String(localized: "\(month): \(focused) focused at a \(rate) focus rate.")
        }
        if points == 0 {
            return an ? String(localized: "\(month): \(focused) focused at an \(rate) focus rate, level with \(previous).")
                : String(localized: "\(month): \(focused) focused at a \(rate) focus rate, level with \(previous).")
        }
        if points > 0 {
            return an ? String(localized: "\(month): \(focused) focused at an \(rate) focus rate, \(moved) points up on \(previous).",
                               comment: "Plural on points: 1 point / 2 points")
                : String(localized: "\(month): \(focused) focused at a \(rate) focus rate, \(moved) points up on \(previous).",
                         comment: "Plural on points: 1 point / 2 points")
        }
        return an ? String(localized: "\(month): \(focused) focused at an \(rate) focus rate, \(moved) points down on \(previous).",
                           comment: "Plural on points: 1 point / 2 points")
            : String(localized: "\(month): \(focused) focused at a \(rate) focus rate, \(moved) points down on \(previous).",
                     comment: "Plural on points: 1 point / 2 points")
    }

    // MARK: - Parts of the day

    private struct Part {
        var focus: TimeInterval = 0
        var drift: TimeInterval = 0
        var driftBy: [String: (name: String, seconds: TimeInterval)] = [:]
        var rate: Double { FocusRate.of(focused: focus, drifted: drift) }
        var rated: Bool { focus + drift >= 2 * 3600 }
    }

    private static func parts(_ data: CoachData, calendar: Calendar) -> [CoachHours: Part] {
        var byPart: [CoachHours: Part] = [:]
        for event in data.events where event.kind != .neutral {
            guard let hours = CoachHours.parts.first(where: { $0.contains(event.start, calendar: calendar) }) else { continue }
            var part = byPart[hours] ?? Part()
            if event.kind == .focus {
                part.focus += event.duration
            } else {
                part.drift += event.duration
                let entry = part.driftBy[event.target] ?? (event.name, 0)
                part.driftBy[event.target] = (entry.name, entry.seconds + event.duration)
            }
            byPart[hours] = part
        }
        return byPart
    }

    /// The part of the day that got stronger most, and the one that slipped
    /// most, by 5 points or more, with 2 hours rated in both months.
    static func partChanges(_ month: CoachData, before: CoachData, locale: Locale, calendar: Calendar) -> [CoachPoint] {
        let now = parts(month, calendar: calendar), then = parts(before, calendar: calendar)
        let moved: [(hours: CoachHours, now: Part, then: Part, change: Double)] = CoachHours.parts.compactMap { hours in
            guard let a = now[hours], let b = then[hours], a.rated, b.rated else { return nil }
            return (hours, a, b, a.rate - b.rate)
        }
        var out: [CoachPoint] = []
        if let up = moved.max(by: { $0.change < $1.change }), up.change >= 0.05 {
            let name = partsName(up.hours), phrase = CoachDraft.capitalized(up.hours.phrase(locale: locale, calendar: calendar))
            let from = CoachDraft.percent(up.then.rate), to = CoachDraft.percent(up.now.rate)
            out.append(CoachPoint(String(localized: "\(name) got stronger.| \(phrase) rose from \(from) to \(to).",
                                         comment: "Mornings, then when: Before noon. The | ends the bold start"), tone: .focus))
        }
        if let down = moved.min(by: { $0.change < $1.change }), down.change <= -0.05 {
            let name = partsName(down.hours)
            let phrase = down.hours.phrase(locale: locale, calendar: calendar)
            let more = down.now.drift - down.then.drift
            let sentence: String
            if more >= 15 * 60 {
                let extra = CoachDraft.duration(more)
                let top = down.now.driftBy.max(by: { ($0.value.seconds, $1.key) < ($1.value.seconds, $0.key) })
                let share = top.map { $0.value.seconds / max(1, down.now.drift) } ?? 0
                if let top, share >= 0.5 {
                    sentence = String(localized: "\(name) slipped.| You drifted \(extra) more \(phrase), most of it on \(top.value.name).",
                                      comment: "Mornings, a compact duration, when (before noon), an app or site. The | ends the bold start")
                } else if let top, share >= 0.3 {
                    sentence = String(localized: "\(name) slipped.| You drifted \(extra) more \(phrase), much of it on \(top.value.name).",
                                      comment: "Mornings, a compact duration, when (before noon), an app or site. The | ends the bold start")
                } else {
                    sentence = String(localized: "\(name) slipped.| You drifted \(extra) more \(phrase).",
                                      comment: "Mornings, a compact duration, when (before noon). The | ends the bold start")
                }
            } else {
                let capital = CoachDraft.capitalized(phrase)
                let from = CoachDraft.percent(down.then.rate), to = CoachDraft.percent(down.now.rate)
                sentence = String(localized: "\(name) slipped.| \(capital) fell from \(from) to \(to).",
                                  comment: "Mornings, then when: Before noon. The | ends the bold start")
            }
            out.append(CoachPoint(sentence, tone: .drift))
        }
        return out
    }

    /// With nothing to compare: the part of the day that ran best.
    static func bestPart(_ month: CoachData, locale: Locale, calendar: Calendar) -> CoachPoint? {
        let rated = parts(month, calendar: calendar).filter { $0.value.rated }
        guard rated.count >= 2, let best = rated.max(by: { ($0.value.rate, $1.key.from) < ($1.value.rate, $0.key.from) }) else { return nil }
        let name = partsName(best.key), phrase = CoachDraft.capitalized(best.key.phrase(locale: locale, calendar: calendar))
        let rate = CoachDraft.percent(best.value.rate)
        return CoachPoint(String(localized: "\(name) were your strongest.| \(phrase) ran at \(rate).",
                                 comment: "Mornings, then when: Before noon. The | ends the bold start"), tone: .focus)
    }

    /// "Mornings".
    static func partsName(_ hours: CoachHours) -> String {
        switch hours {
        case .morning:   return String(localized: "Mornings")
        case .afternoon: return String(localized: "Afternoons")
        case .evening:   return String(localized: "Evenings")
        default:         return String(localized: "Those hours")
        }
    }

    // MARK: - Sessions and distractions

    /// Average session length against the month before, 3 sessions or more in each.
    static func sessionChange(_ month: CoachData, before: CoachData) -> CoachPoint? {
        guard month.sessions.count >= 3, before.sessions.count >= 3 else { return nil }
        let now = Int((Double(month.sessions.reduce(0) { $0 + $1.minutes }) / Double(month.sessions.count)).rounded())
        let then = Int((Double(before.sessions.reduce(0) { $0 + $1.minutes }) / Double(before.sessions.count)).rounded())
        if now - then >= 3 {
            return CoachPoint(String(localized: "Sessions got longer.| \(now) minutes on average, up from \(then).", comment: "The | ends the bold start"), tone: .focus)
        }
        if then - now >= 3 {
            return CoachPoint(String(localized: "Sessions got shorter.| \(now) minutes on average, down from \(then).", comment: "The | ends the bold start"), tone: .other)
        }
        return CoachPoint(String(localized: "Sessions held steady.| About \(now) minutes on average.", comment: "The | ends the bold start"), tone: .other)
    }

    /// The month's top distraction, with its time the month before.
    static func topDistraction(_ month: CoachData, before: CoachData?, previous: String) -> CoachPoint? {
        let drift = month.events.filter { $0.kind == .distraction }
        let byTarget = Dictionary(grouping: drift, by: \.target).mapValues { $0.reduce(0) { $0 + $1.duration } }
        guard let top = byTarget.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value >= 30 * 60,
              let name = drift.first(where: { $0.target == top.key })?.name else { return nil }
        let earlier = before.map { data in
            data.events.filter { $0.kind == .distraction && $0.target == top.key }.reduce(0) { $0 + $1.duration }
        } ?? 0
        let time = CoachDraft.duration(top.value)
        if earlier >= 60 {
            let then = CoachDraft.duration(earlier)
            return CoachPoint(String(localized: "\(name) was your top distraction.| \(time) this month, against \(then) in \(previous).",
                                     comment: "An app or site, two compact durations, then a month: September. The | ends the bold start"), tone: .drift)
        }
        return CoachPoint(String(localized: "\(name) was your top distraction.| \(time) this month.",
                                 comment: "An app or site, then a compact duration. The | ends the bold start"), tone: .drift)
    }

    // MARK: - Words

    /// "October".
    static func monthName(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        var style = Date.FormatStyle().month(.wide)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// English only: whether a percentage is said "an 83%" rather than "a 72%".
    static func takesAn(_ percent: String) -> Bool {
        percent.hasPrefix("8") || percent.hasPrefix("11%") || percent.hasPrefix("18%")
    }
}

/// Turns a month into suggestions and its experiments into lines.
enum MonthReviewBuilder {
    /// Up to `count` experiments from the month's strongest patterns that
    /// don't overlap each other or anything already on.
    static func suggestions(_ month: CoachData, settings: CoachSettings, weekendsCount: Bool, morningHour: Int,
                            count: Int = 2, locale: Locale = .current, calendar: Calendar = .current) -> [MonthSuggestion] {
        let findings = CoachPatternFinder.find(in: month, history: month, lateStartCutoff: (morningHour + 1) * 60,
                                               weekendsCount: weekendsCount, calendar: calendar)
        var planned = settings
        var out: [MonthSuggestion] = []
        for finding in findings where out.count < count {
            guard let experiment = CoachPlanner.experiment(for: finding, settings: planned) else { continue }
            planned.inPlace.append(experiment)
            out.append(MonthSuggestion(experiment: experiment, reason: reason(for: finding, locale: locale, calendar: calendar),
                                       baseline: experiment.metric.measure(month, calendar: calendar)))
        }
        return out
    }

    /// The pattern in one sentence. A day that drifted is named in full,
    /// since a month has several of each weekday.
    static func reason(for finding: CoachFinding, locale: Locale, calendar: Calendar) -> String {
        if case .driftDay(let f) = finding {
            var style = Date.FormatStyle().weekday(.wide).day().month(.wide)
            style.locale = locale
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            let day = CoachDraft.capitalized(f.day.formatted(style)), time = CoachDraft.duration(f.targetSeconds)
            return String(localized: "\(day) drifted most, \(time) of it on \(f.name).", comment: "A full date with its weekday, a compact duration, an app or site")
        }
        return CoachDraft.headline(for: finding, locale: locale, calendar: calendar)
    }

    /// The coach's experiments that ran during `month`, oldest first.
    static func trials(_ all: [CoachTrial], in month: DateInterval, kept: Set<UUID>, now: Date,
                       locale: Locale = .current, calendar: Calendar = .current) -> [MonthTrialLine] {
        all.filter { $0.week.start < month.end && $0.week.end > month.start }
            .sorted { $0.appliedAt < $1.appliedAt }
            .map { trial in
                let running = trial.week.end > now
                var result = running ? String(localized: "Still running") : (trial.change ?? String(localized: "Too little to tell"))
                if !running, trial.isMeasured, case .sessionRate(let hours) = trial.experiment.metric, hours != .allDay {
                    let when = hours.phrase(locale: locale, calendar: calendar)
                    result = String(localized: "\(result) \(when)", comment: "A change in focus rate, then when: +7 pts after 17:00")
                }
                let status: String
                if kept.contains(trial.id) {
                    status = String(localized: "Kept on")
                } else if running {
                    var style = Date.FormatStyle().day().month(.wide)
                    style.locale = locale
                    style.calendar = calendar
                    style.timeZone = calendar.timeZone
                    let last = trial.week.end.addingTimeInterval(-1).formatted(style)
                    status = String(localized: "On until \(last)", comment: "A date: 30 November")
                } else {
                    status = String(localized: "Turned off")
                }
                return MonthTrialLine(id: trial.id, title: trial.experiment.title(locale: locale, calendar: calendar),
                                      result: result, improved: !running && trial.improved, status: status)
            }
    }
}

/// Works out month reviews and keeps them while the app runs. Reads go
/// through the weekly coach's reader, off the main thread.
@MainActor
@Observable
final class MonthReviewer {
    static let shared = MonthReviewer()

    private(set) var reviews: [Date: MonthReview] = [:]
    /// Months being worked out right now, by their start.
    private(set) var loading: Set<Date> = []

    let coach: WeeklyCoach
    /// The tracked data for a stretch of days; the coach's by default.
    @ObservationIgnored var reader: (DateInterval) async -> CoachData
    @ObservationIgnored var model: () -> (any OnDeviceModel)? = OnDeviceAI.writer
    @ObservationIgnored var isUnlocked: () -> Bool = { Entitlements.shared.isUnlocked(.monthlyReview) }
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored var locale: Locale = .current

    private let defaults: UserDefaults
    let calendar: Calendar

    init(coach: WeeklyCoach = .shared, defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.coach = coach
        self.defaults = defaults
        self.calendar = calendar
        self.reader = { await coach.reader($0) }
    }

    /// The month that ended last.
    var lastFinishedMonth: DateInterval? {
        guard let current = calendar.dateInterval(of: .month, for: now()) else { return nil }
        return calendar.dateInterval(of: .month, for: current.start.addingTimeInterval(-1))
    }

    /// How long "Try it" runs: to the end of this month, or of the next one
    /// when less than two weeks are left.
    var trialPeriod: DateInterval? {
        let at = now()
        guard let current = calendar.dateInterval(of: .month, for: at) else { return nil }
        guard current.end.timeIntervalSince(at) < 14 * 86_400,
              let next = calendar.dateInterval(of: .month, for: current.end) else { return DateInterval(start: at, end: current.end) }
        return DateInterval(start: at, end: next.end)
    }

    /// "Try in November", or "Try through December" late in a month.
    var tryHeading: String {
        guard let period = trialPeriod else { return String(localized: "Try next") }
        let month = MonthFacts.monthName(period.end.addingTimeInterval(-1), locale: locale, calendar: calendar)
        return calendar.isDate(period.start, equalTo: period.end.addingTimeInterval(-1), toGranularity: .month)
            ? String(localized: "Try in \(month)", comment: "A month: November") : String(localized: "Try through \(month)", comment: "A month: December")
    }

    func review(for month: DateInterval) -> MonthReview? { reviews[month.start] }

    func isLoading(_ month: DateInterval) -> Bool { loading.contains(month.start) }

    /// Works out a finished month's review, once.
    func load(_ month: DateInterval) async {
        guard FeatureFlags.monthlyReview, isUnlocked(), month.end <= now(), reviews[month.start] == nil,
              !loading.contains(month.start),
              let beforeStart = calendar.date(byAdding: .month, value: -1, to: month.start) else { return }
        loading.insert(month.start)
        defer { loading.remove(month.start) }

        let both = await reader(DateInterval(start: beforeStart, end: month.end))
        let monthData = both.clipped(to: month)
        let before = both.clipped(to: DateInterval(start: beforeStart, end: month.start))
        var current = coach.applier?.settings() ?? CoachSettings()
        current.inPlace = coach.inPlace
        let settings = current
        let latest = month.start == lastFinishedMonth?.start
        let weekendsCount = defaults.bool(forKey: SettingsKeys.Goal.weekendsCount)
        let morningHour = HabitSchedule.morningStartHour(defaults)
        let wordsLocale = locale, monthCalendar = calendar
        // Two months of events: worked out off the main thread.
        let (found, ideas) = await Task.detached(priority: .utility) {
            (MonthFacts.make(monthData, before: before, locale: wordsLocale, calendar: monthCalendar),
             latest ? MonthReviewBuilder.suggestions(monthData, settings: settings, weekendsCount: weekendsCount,
                                                     morningHour: morningHour, locale: wordsLocale, calendar: monthCalendar) : [])
        }.value
        guard let found else {
            reviews[month.start] = .empty(month)
            return
        }
        let draft = CoachDraft(headline: found.headline, points: found.changes, why: nil, facts: found.facts)
        let wording = await CoachWriter(model: model(), brief: CoachWriter.monthInstructions).write(draft)
        reviews[month.start] = MonthReview(month: month, headline: wording.headline, changes: found.changes,
                                           suggestions: ideas, onDevice: wording.onDevice, hasData: true)
    }

    // MARK: - Experiments

    /// The coach's experiments that ran in `month`.
    func trials(in month: DateInterval) -> [MonthTrialLine] {
        MonthReviewBuilder.trials(coach.allTrials, in: month, kept: Set(coach.state.kept.map(\.id)), now: now(),
                                  locale: locale, calendar: calendar)
    }

    /// The month trial running a suggestion, once "Try it" was pressed.
    func trial(for suggestion: MonthSuggestion) -> CoachTrial? {
        coach.monthTrials.first { $0.experiment == suggestion.experiment }
    }

    /// "Try it": puts the suggestion in place until `trialPeriod` ends.
    func tryIt(_ suggestion: MonthSuggestion) {
        guard let period = trialPeriod else { return }
        coach.tryForMonth(suggestion.experiment, baseline: suggestion.baseline, until: period)
    }

    func undo(_ suggestion: MonthSuggestion) {
        if let trial = trial(for: suggestion) { coach.undoMonthTrial(trial) }
    }

    /// "Erase all data": the reviews were worked out from it.
    func erase() {
        reviews = [:]
    }
}
