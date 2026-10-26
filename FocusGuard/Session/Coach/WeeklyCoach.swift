import Foundation
import os

/// The week's numbers on the coach's tiles.
struct CoachWeekStats: Codable, Equatable, Sendable {
    let focused: TimeInterval
    /// The week before, when anything was tracked.
    let focusedBefore: TimeInterval?
    let rate: Double
    let rateBefore: Double?
    /// Days the daily goal was met, of `goalOf`.
    let goalDays: Int
    let goalOf: Int
    let weekendsCount: Bool

    static func make(_ week: CoachData, before: CoachData, goal: TimeInterval, weekendsCount: Bool,
                     calendar: Calendar = .current) -> CoachWeekStats {
        let now = CoachData.tally(week.events), then = CoachData.tally(before.events)
        let focusByDay = Dictionary(grouping: week.events.filter { $0.kind == .focus }) { calendar.startOfDay(for: $0.start) }
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
        let countable = { (day: Date) in weekendsCount || !calendar.isDateInWeekend(day) }
        return CoachWeekStats(
            focused: now.focus,
            focusedBefore: before.events.isEmpty ? nil : then.focus,
            rate: FocusRate.of(focused: now.focus, drifted: now.drift),
            rateBefore: then.focus + then.drift >= 60 ? FocusRate.of(focused: then.focus, drifted: then.drift) : nil,
            goalDays: focusByDay.filter { countable($0.key) && $0.value >= goal }.count,
            goalOf: weekendsCount ? 7 : 5,
            weekendsCount: weekendsCount
        )
    }
}

/// This week's note, made from last week.
struct CoachNote: Codable, Equatable, Sendable {
    /// The week it's for, and the one it's about.
    let week: DateInterval
    let about: DateInterval
    let headline: String
    let points: [CoachPoint]
    let experiment: CoachExperiment?
    let why: String?
    /// The experiment's measure on the week it came from.
    let baseline: Double?
    let stats: CoachWeekStats
    /// Whether the on-device model worded it.
    let onDevice: Bool
}

/// An experiment that was tried: what it changed and how it went.
struct CoachTrial: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let experiment: CoachExperiment
    /// Its measure on the week it came from, and on the week it ran.
    let before: Double?
    var after: Double?
    /// The week it ran in; it ends with it unless kept.
    let week: DateInterval
    let appliedAt: Date
    var kept: Bool
    var undo: CoachUndo

    var isMeasured: Bool { before != nil && after != nil }

    /// "+9 pts", or nil when there was too little to tell.
    var change: String? {
        guard let before, let after else { return nil }
        return experiment.metric.change(from: before, to: after)
    }

    var improved: Bool {
        guard let before, let after else { return false }
        return experiment.metric.improved(from: before, to: after)
    }
}

/// What the coach remembers between launches.
struct CoachState: Codable, Equatable, Sendable {
    enum Choice: String, Codable, Sendable {
        /// "Try it this week" and "Not now" are on offer.
        case open
        case trying
        case dismissed
    }

    /// The week last looked at; a note is made once per week.
    var week: Date?
    var note: CoachNote?
    var choice: Choice = .open
    /// This week's experiment.
    var running: CoachTrial?
    /// The last experiment to end, with its result.
    var finished: CoachTrial?
    /// Experiments the user kept on; each can be stopped.
    var kept: [CoachTrial] = []
}

/// The Pro weekly coach. Once a week it finds one pattern in last week's
/// data, words it (with the on-device model where there is one), and offers
/// one experiment the app can apply itself. The week after, it shows how
/// the experiment went and undoes it, unless the user kept it.
@MainActor
@Observable
final class WeeklyCoach {
    static let shared = WeeklyCoach()

    private(set) var state: CoachState
    /// Working out this week's note right now.
    private(set) var isMakingNote = false
    /// Why "Try it this week" didn't apply, for a moment.
    private(set) var problem: String?

    @ObservationIgnored var reader: (DateInterval) async -> CoachData = { CoachData.empty($0) }
    @ObservationIgnored var applier: CoachApplying?
    /// Apple's on-device model, or nil without Apple Intelligence (the note
    /// keeps its template words then).
    @ObservationIgnored var model: () -> (any OnDeviceModel)? = OnDeviceAI.model
    @ObservationIgnored var isUnlocked: () -> Bool = { Entitlements.shared.isUnlocked(.coach) }
    /// A free user's first use: starts the 14-day trial.
    @ObservationIgnored var startTrial: () -> Void = { Entitlements.shared.startTrialIfNeeded(for: .coach) }
    @ObservationIgnored var goalSeconds: () -> TimeInterval = { FocusGoal.dailySeconds }
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored var locale: Locale = .current

    private let defaults: UserDefaults
    private let calendar: Calendar
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false

    static let stateKey = "coach.state"
    private static let logger = Logger(subsystem: "com.anar.focusguard", category: "coach")

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        self.state = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(CoachState.self, from: $0) } ?? CoachState()
    }

    /// Hooks the coach up to the app: reads the store off the main thread,
    /// applies experiments through the daily limits and settings, and lets
    /// the drift engine follow a stricter preset by the hour.
    func attach(_ appState: AppState) {
        let container = appState.container
        reader = { await CoachDataReader.read(container, interval: $0) }
        let engine = appState.escalationEngine
        applier = LiveCoachApplier(limits: appState.limits, preset: { [weak engine] in engine?.preset ?? .standard },
                                   defaults: defaults)
        engine.presetOverride = { [defaults] now in CoachRules.preset(at: now, defaults) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    // MARK: - Reading

    /// The current calendar week.
    var thisWeek: DateInterval? { calendar.dateInterval(of: .weekOfYear, for: now()) }

    /// The note for this week, if one was made.
    var note: CoachNote? {
        guard let note = state.note, let week = thisWeek, note.week.start == week.start else { return nil }
        return note
    }

    /// The experiment that ran in the week the note is about.
    var lastResult: CoachTrial? {
        guard let finished = state.finished, let note else { return nil }
        return finished.week.start == note.about.start ? finished : nil
    }

    /// Whether last week's experiment can be kept on now.
    var canKeepLastResult: Bool {
        guard let trial = lastResult, !trial.kept else { return false }
        let inPlace = state.kept.map(\.experiment) + [state.running?.experiment].compactMap { $0 }
            + (state.choice == .open ? [note?.experiment].compactMap { $0 } : [])
        return !inPlace.contains { $0.overlaps(trial.experiment) }
    }

    // MARK: - The week

    /// Ends an experiment whose week is over, then makes this week's note
    /// if there isn't one. Runs every minute and when a coach view opens.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let at = now()
        CoachRules.pruneExpired(now: at, defaults)
        await finishTrialIfDue(at: at)
        guard FeatureFlags.coach, isUnlocked(), let week = calendar.dateInterval(of: .weekOfYear, for: at),
              state.week != week.start else { return }
        isMakingNote = true
        await makeNote(for: week)
        isMakingNote = false
    }

    /// Measures an experiment once its week is over and undoes it, unless kept.
    /// Runs on any plan, so nothing the coach changed outlasts a trial.
    private func finishTrialIfDue(at now: Date) async {
        guard var trial = state.running, trial.week.end <= now else { return }
        let data = await reader(DateInterval(start: min(trial.appliedAt, trial.week.end), end: trial.week.end))
        trial.after = trial.experiment.metric.measure(data, calendar: calendar)
        if trial.kept {
            state.kept.append(trial)
        } else {
            applier?.undo(trial.undo, weekOver: true)
        }
        state.finished = trial
        state.running = nil
        save()
    }

    private func makeNote(for week: DateInterval) async {
        guard let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start),
              let beforeStart = calendar.date(byAdding: .weekOfYear, value: -2, to: week.start) else { return }
        let lastWeek = DateInterval(start: lastStart, end: week.start)
        let data = await reader(DateInterval(start: beforeStart, end: week.start))
        let last = data.clipped(to: lastWeek)
        let before = data.clipped(to: DateInterval(start: beforeStart, end: lastStart))

        state.week = week.start
        state.choice = .open
        state.note = nil
        let tally = CoachData.tally(last.events)
        guard last.sessions.count >= 2 || tally.focus + tally.drift >= 60 * 60 else {
            save()
            return
        }

        var settings = applier?.settings() ?? CoachSettings()
        settings.inPlace = state.kept.map(\.experiment) + [state.running?.experiment].compactMap { $0 }
        let cutoff = (HabitSchedule.morningStartHour(defaults) + 1) * 60
        let findings = CoachPatternFinder.find(in: last, lateStartCutoff: cutoff, calendar: calendar)
        let plan = CoachPlanner.plan(findings, settings: settings)
        let experiment = plan?.1
        let draft = CoachDraft.make(plan?.0, experiment: experiment, locale: locale, calendar: calendar)
        let wording = await CoachWriter(model: model()).write(draft)

        var baseline = experiment.flatMap { $0.metric.measure(last, calendar: calendar) }
        if case .timeOfDay(let f)? = plan?.0, case .sessionRate(let hours)? = experiment?.metric, hours == f.weak {
            baseline = f.weakRate
        }
        let stats = CoachWeekStats.make(last, before: before, goal: goalSeconds(),
                                        weekendsCount: defaults.bool(forKey: SettingsKeys.Goal.weekendsCount),
                                        calendar: calendar)
        state.note = CoachNote(week: week, about: lastWeek, headline: wording.headline, points: draft.points,
                               experiment: experiment, why: wording.why, baseline: baseline, stats: stats,
                               onDevice: wording.onDevice)
        save()
        Self.logger.info("Coach note for the week of \(week.start, privacy: .public): \(String(describing: plan?.0), privacy: .private)")
    }

    // MARK: - Choices

    /// "Try it this week": applies the experiment until the week ends.
    func tryIt() {
        problem = nil
        guard let note, let experiment = note.experiment, state.choice != .trying, let applier else { return }
        if !isUnlocked() { startTrial() }
        guard isUnlocked() else { return }
        guard let undo = applier.apply(experiment, until: note.week.end) else {
            problem = "That's already set up, so there's nothing to try."
            return
        }
        state.running = CoachTrial(experiment: experiment, before: note.baseline, week: note.week,
                                   appliedAt: now(), kept: false, undo: undo)
        state.choice = .trying
        save()
    }

    /// "Not now": nothing changes this week.
    func notNow() {
        problem = nil
        guard state.choice == .open else { return }
        state.choice = .dismissed
        save()
    }

    /// Takes back "Try it this week" or "Not now".
    func reconsider() {
        problem = nil
        if state.choice == .trying, let trial = state.running {
            applier?.undo(trial.undo, weekOver: false)
            state.running = nil
        }
        state.choice = .open
        save()
    }

    /// Keeps this week's experiment on after the week ends.
    func keepRunning() {
        guard var trial = state.running, !trial.kept else { return }
        trial.kept = true
        applier?.keep(trial.undo)
        state.running = trial
        save()
    }

    /// Turns last week's experiment back on, for good.
    func keepLastResult() {
        guard canKeepLastResult, var trial = lastResult,
              let undo = applier?.apply(trial.experiment, until: nil) else { return }
        trial.kept = true
        trial.undo = undo
        state.kept.append(trial)
        state.finished = trial
        save()
    }

    /// Stops an experiment that was kept on.
    func stop(_ trial: CoachTrial) {
        guard state.kept.contains(where: { $0.id == trial.id }) else { return }
        applier?.undo(trial.undo, weekOver: false)
        state.kept.removeAll { $0.id == trial.id }
        if state.finished?.id == trial.id { state.finished?.kept = false }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }
}
