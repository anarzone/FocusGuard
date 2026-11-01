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
        var headline = "\(name): \(CoachDraft.duration(now.focus)) focused at \(withArticle(CoachDraft.percent(rate))) focus rate"
        if compares {
            let points = Int((rate * 100).rounded()) - Int((FocusRate.of(focused: then.focus, drifted: then.drift) * 100).rounded())
            headline += points == 0 ? ", level with \(previous)"
                : ", \(CoachDraft.counted(abs(points), "point")) \(points > 0 ? "up" : "down") on \(previous)"
        }
        headline += "."

        var changes: [CoachPoint] = []
        if compares {
            changes += partChanges(month, before: before, locale: locale, calendar: calendar)
            if let sessions = sessionChange(month, before: before) { changes.append(sessions) }
            let delta = now.focus - then.focus
            if abs(delta) >= 30 * 60 {
                changes.append(delta > 0
                    ? CoachPoint(lead: "More focus overall.", rest: " \(CoachDraft.duration(now.focus)), up from \(CoachDraft.duration(then.focus)).", tone: .focus)
                    : CoachPoint(lead: "Less focus overall.", rest: " \(CoachDraft.duration(now.focus)), down from \(CoachDraft.duration(then.focus)).", tone: .drift))
            }
        } else if let best = bestPart(month, locale: locale, calendar: calendar) {
            changes.append(best)
        }
        if let top = topDistraction(month, before: compares ? before : nil, previous: previous) {
            changes.append(top)
        }
        return MonthFacts(headline: headline, changes: Array(changes.prefix(3)))
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
            out.append(CoachPoint(lead: "\(partsName(up.hours)) got stronger.",
                                  rest: " \(CoachDraft.capitalized(up.hours.phrase(locale: locale, calendar: calendar))) rose from \(CoachDraft.percent(up.then.rate)) to \(CoachDraft.percent(up.now.rate)).",
                                  tone: .focus))
        }
        if let down = moved.min(by: { $0.change < $1.change }), down.change <= -0.05 {
            let phrase = down.hours.phrase(locale: locale, calendar: calendar)
            let more = down.now.drift - down.then.drift
            let rest: String
            if more >= 15 * 60 {
                var line = " You drifted \(CoachDraft.duration(more)) more \(phrase)"
                if let top = down.now.driftBy.max(by: { ($0.value.seconds, $1.key) < ($1.value.seconds, $0.key) }) {
                    let share = top.value.seconds / max(1, down.now.drift)
                    if share >= 0.5 { line += ", most of it on \(top.value.name)" } else if share >= 0.3 { line += ", much of it on \(top.value.name)" }
                }
                rest = line + "."
            } else {
                rest = " \(CoachDraft.capitalized(phrase)) fell from \(CoachDraft.percent(down.then.rate)) to \(CoachDraft.percent(down.now.rate))."
            }
            out.append(CoachPoint(lead: "\(partsName(down.hours)) slipped.", rest: rest, tone: .drift))
        }
        return out
    }

    /// With nothing to compare: the part of the day that ran best.
    static func bestPart(_ month: CoachData, locale: Locale, calendar: Calendar) -> CoachPoint? {
        let rated = parts(month, calendar: calendar).filter { $0.value.rated }
        guard rated.count >= 2, let best = rated.max(by: { ($0.value.rate, $1.key.from) < ($1.value.rate, $0.key.from) }) else { return nil }
        return CoachPoint(lead: "\(partsName(best.key)) were your strongest.",
                          rest: " \(CoachDraft.capitalized(best.key.phrase(locale: locale, calendar: calendar))) ran at \(CoachDraft.percent(best.value.rate)).",
                          tone: .focus)
    }

    /// "Mornings".
    static func partsName(_ hours: CoachHours) -> String {
        hours.partOfDay.map { CoachDraft.capitalized($0) + "s" } ?? "Those hours"
    }

    // MARK: - Sessions and distractions

    /// Average session length against the month before, 3 sessions or more in each.
    static func sessionChange(_ month: CoachData, before: CoachData) -> CoachPoint? {
        guard month.sessions.count >= 3, before.sessions.count >= 3 else { return nil }
        let now = Int((Double(month.sessions.reduce(0) { $0 + $1.minutes }) / Double(month.sessions.count)).rounded())
        let then = Int((Double(before.sessions.reduce(0) { $0 + $1.minutes }) / Double(before.sessions.count)).rounded())
        if now - then >= 3 {
            return CoachPoint(lead: "Sessions got longer.", rest: " \(now) minutes on average, up from \(then).", tone: .focus)
        }
        if then - now >= 3 {
            return CoachPoint(lead: "Sessions got shorter.", rest: " \(now) minutes on average, down from \(then).", tone: .other)
        }
        return CoachPoint(lead: "Sessions held steady.", rest: " About \(now) minutes on average.", tone: .other)
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
        let against = earlier >= 60 ? ", against \(CoachDraft.duration(earlier)) in \(previous)" : ""
        return CoachPoint(lead: "\(name) was your top distraction.",
                          rest: " \(CoachDraft.duration(top.value)) this month\(against).", tone: .drift)
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

    /// "an 83%", "a 72%".
    static func withArticle(_ percent: String) -> String {
        let an = percent.hasPrefix("8") || percent.hasPrefix("11%") || percent.hasPrefix("18%")
        return (an ? "an " : "a ") + percent
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
            return "\(f.day.formatted(style)) drifted most, \(CoachDraft.duration(f.targetSeconds)) of it on \(f.name)."
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
                var result = running ? "Still running" : (trial.change ?? "Too little to tell")
                if !running, trial.isMeasured, case .sessionRate(let hours) = trial.experiment.metric, hours != .allDay {
                    result += " \(hours.phrase(locale: locale, calendar: calendar))"
                }
                let status: String
                if kept.contains(trial.id) {
                    status = "Kept on"
                } else if running {
                    var style = Date.FormatStyle().day().month(.wide)
                    style.locale = locale
                    style.calendar = calendar
                    style.timeZone = calendar.timeZone
                    status = "On until \(trial.week.end.addingTimeInterval(-1).formatted(style))"
                } else {
                    status = "Turned off"
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
    @ObservationIgnored var model: () -> (any OnDeviceModel)? = OnDeviceAI.model
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
        guard let period = trialPeriod else { return "Try next" }
        let month = MonthFacts.monthName(period.end.addingTimeInterval(-1), locale: locale, calendar: calendar)
        return calendar.isDate(period.start, equalTo: period.end.addingTimeInterval(-1), toGranularity: .month)
            ? "Try in \(month)" : "Try through \(month)"
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
