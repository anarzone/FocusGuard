import AppKit
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

    /// - Parameter goal: a day's goal, from its start (a weekday can have its own).
    static func make(_ week: CoachData, before: CoachData, goal: (Date) -> TimeInterval, weekendsCount: Bool,
                     calendar: Calendar = .current) -> CoachWeekStats {
        let now = CoachData.tally(week.events), then = CoachData.tally(before.events)
        let focusByDay = week.focusByDay(calendar: calendar)
        let countable = { (day: Date) in weekendsCount || !calendar.isDateInWeekend(day) }
        return CoachWeekStats(
            focused: now.focus,
            focusedBefore: before.events.isEmpty ? nil : then.focus,
            rate: FocusRate.of(focused: now.focus, drifted: now.drift),
            rateBefore: then.focus + then.drift >= 60 ? FocusRate.of(focused: then.focus, drifted: then.drift) : nil,
            goalDays: focusByDay.filter { countable($0.key) && $0.value >= goal($0.key) }.count,
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
    var before: Double?
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

    /// It ran, and nothing moved.
    var madeNoDifference: Bool {
        guard let before, let after else { return false }
        return experiment.metric.isUnchanged(from: before, to: after)
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
    /// Experiments that ended, newest last, for the month review.
    var history: [CoachTrial]?
    /// Experiments started from the month review; each runs to the end of
    /// its own stretch (`CoachTrial.week`).
    var monthTrials: [CoachTrial]?
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
    /// Why a month review's "Try it" didn't apply, for a moment.
    private(set) var monthProblem: String?

    /// The tracked data for a stretch of days, with the calendar's busy times.
    @ObservationIgnored var reader: (DateInterval) async -> CoachData = { CoachData.empty($0) }
    @ObservationIgnored var applier: CoachApplying?
    /// Apple's on-device model, or nil without Apple Intelligence (the note
    /// keeps its template words then).
    @ObservationIgnored var model: () -> (any OnDeviceModel)? = OnDeviceAI.writer
    @ObservationIgnored var isUnlocked: () -> Bool = { Entitlements.shared.isUnlocked(.coach) }
    /// A free user's first use: starts the 14-day trial.
    @ObservationIgnored var startTrial: () -> Void = { Entitlements.shared.startTrialIfNeeded(for: .coach) }
    /// A day's goal, from its start.
    @ObservationIgnored var goalSeconds: (Date) -> TimeInterval
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored var locale: Locale = .current

    private let defaults: UserDefaults
    private let calendar: Calendar
    /// One-shot, for when something next comes due (`nextRefresh`).
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshing = false

    static let stateKey = "coach.state"
    /// Ended experiments kept for the month review.
    static let historyLimit = 60
    /// Weeks of data the note is worked out from, last week included.
    static let historyWeeks = 3
    private static let logger = Logger(subsystem: "com.anar.focusguard", category: "coach")

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        self.goalSeconds = { FocusGoal.seconds(on: $0, defaults, calendar: calendar) }
        self.state = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(CoachState.self, from: $0) } ?? CoachState()
    }

    /// Hooks the coach up to the app: reads the store off the main thread
    /// (and the calendar's busy times, when it may), applies experiments
    /// through the daily limits and settings, and lets the drift engine
    /// follow a stricter preset by the hour.
    func attach(_ appState: AppState) {
        let container = appState.container
        let busyTimes = CalendarBusyTimes()
        reader = { interval in
            var data = await CoachDataReader.read(container, interval: interval)
            data.busy = busyTimes.busy(from: interval.start, to: interval.end) ?? []
            return data
        }
        let engine = appState.escalationEngine
        applier = LiveCoachApplier(limits: appState.limits, preset: { [weak engine] in engine?.preset ?? .standard },
                                   defaults: defaults)
        engine.presetOverride = { [defaults] now in CoachRules.preset(at: now, defaults) }
        // Something may have come due while the Mac slept.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAndReschedule() }
        }
        Task { await refreshAndReschedule() }
    }

    /// Longest wait between background looks; the coach's own views look
    /// whenever they're shown.
    nonisolated static let maxWait: TimeInterval = 30 * 60

    /// Seconds until the coach next has something to do by itself (an
    /// experiment's week ending, a rule running out, a new week), a second
    /// after it's due; at most `maxWait`.
    nonisolated static func nextRefresh(now: Date, due: [Date], maxWait: TimeInterval = maxWait) -> TimeInterval {
        let next = due.filter { $0 > now }.min().map { $0.timeIntervalSince(now) + 1 }
        return min(maxWait, next ?? maxWait)
    }

    private func refreshAndReschedule() async {
        await refresh()
        let due = [state.running?.week.end, thisWeek?.end].compactMap { $0 }
            + monthTrials.map(\.week.end) + CoachRules.all(defaults).compactMap(\.until)
        timer?.invalidate()
        let delay = Self.nextRefresh(now: now(), due: due)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refreshAndReschedule() }
        }
        timer.tolerance = min(60, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
        let offered = state.choice == .open ? [note?.experiment].compactMap { $0 } : []
        return !(inPlace + offered).contains { $0.overlaps(trial.experiment) }
    }

    /// Experiments on right now: kept ones, this week's, and the month review's.
    var inPlace: [CoachExperiment] {
        (state.kept + [state.running].compactMap { $0 } + monthTrials).map(\.experiment)
    }

    /// Experiments started from the month review that are still on.
    var monthTrials: [CoachTrial] { state.monthTrials ?? [] }

    /// Every experiment the coach knows of: ended, kept, running, and the
    /// month review's, each once.
    var allTrials: [CoachTrial] {
        var seen = Set<UUID>()
        let all = (state.history ?? []) + [state.finished].compactMap { $0 } + state.kept
            + [state.running].compactMap { $0 } + monthTrials
        // The latest copy of each: a kept one over its history entry.
        return Array(all.reversed().filter { seen.insert($0.id).inserted }.reversed())
    }

    // MARK: - The week

    /// Ends an experiment whose week is over, then makes this week's note
    /// if there isn't one. Runs every minute and when a coach view opens.
    func refresh() async {
        // The UI tests' copy shares the real app's settings, where the
        // coach's state lives: it leaves them alone.
        guard !refreshing, !UITestMode.isOn else { return }
        refreshing = true
        defer { refreshing = false }
        let at = now()
        CoachRules.pruneExpired(now: at, defaults)
        await finishTrialIfDue(at: at)
        await finishMonthTrialsIfDue(at: at)
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
        remember(trial)
        save()
    }

    /// The same for the month review's experiments.
    private func finishMonthTrialsIfDue(at now: Date) async {
        let due = monthTrials.filter { $0.week.end <= now }
        guard !due.isEmpty else { return }
        for var trial in due {
            let data = await reader(DateInterval(start: min(trial.appliedAt, trial.week.end), end: trial.week.end))
            trial.after = trial.experiment.metric.measure(data, calendar: calendar)
            if trial.kept { state.kept.append(trial) } else { applier?.undo(trial.undo, weekOver: true) }
            remember(trial)
        }
        let ended = Set(due.map(\.id))
        let left = monthTrials.filter { !ended.contains($0.id) }
        state.monthTrials = left.isEmpty ? nil : left
        save()
    }

    /// Adds an ended experiment to the history the month review reads.
    private func remember(_ trial: CoachTrial) {
        let earlier = (state.history ?? []).filter { $0.id != trial.id }
        state.history = Array((earlier + [trial]).suffix(Self.historyLimit))
    }

    private func makeNote(for week: DateInterval) async {
        guard let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start),
              let beforeStart = calendar.date(byAdding: .weekOfYear, value: -2, to: week.start),
              let historyStart = calendar.date(byAdding: .weekOfYear, value: -Self.historyWeeks, to: week.start) else { return }
        let lastWeek = DateInterval(start: lastStart, end: week.start)
        let history = await reader(DateInterval(start: historyStart, end: week.start))
        let last = history.clipped(to: lastWeek)
        let before = history.clipped(to: DateInterval(start: beforeStart, end: lastStart))

        state.week = week.start
        state.choice = .open
        state.note = nil
        let tally = CoachData.tally(last.events)
        guard last.sessions.count >= 2 || tally.focus + tally.drift >= 60 * 60 else {
            save()
            return
        }

        var settings = applier?.settings() ?? CoachSettings()
        settings.inPlace = inPlace
        let cutoff = (HabitSchedule.morningStartHour(defaults) + 1) * 60
        let weekendsCount = defaults.bool(forKey: SettingsKeys.Goal.weekendsCount)
        let weekCalendar = calendar
        // Three weeks of events: worked out off the main thread.
        let findings = await Task.detached(priority: .utility) {
            CoachPatternFinder.find(in: last, history: history, lateStartCutoff: cutoff,
                                    weekendsCount: weekendsCount, calendar: weekCalendar)
        }.value
        let plan = CoachPlanner.plan(findings, settings: settings)
        let experiment = plan?.1
        let draft = CoachDraft.make(plan?.0, experiment: experiment, locale: locale, calendar: calendar)
        let wording = await CoachWriter(model: model()).write(draft)

        var baseline = experiment.flatMap { $0.metric.measure(last, calendar: calendar) }
        if case .timeOfDay(let f)? = plan?.0, case .sessionRate(let hours)? = experiment?.metric, hours == f.weak {
            baseline = f.weakRate
        }
        let stats = CoachWeekStats.make(last, before: before, goal: goalSeconds,
                                        weekendsCount: weekendsCount, calendar: calendar)
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
            problem = String(localized: "That's already set up, so there's nothing to try.")
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

    // MARK: - From the month review

    /// The month review's "Try it": applies `experiment` until `period` ends,
    /// measured against `baseline`. False when it couldn't, with
    /// `monthProblem` saying why.
    @discardableResult
    func tryForMonth(_ experiment: CoachExperiment, baseline: Double?, until period: DateInterval) -> Bool {
        monthProblem = nil
        guard let applier else { return false }
        if !isUnlocked() { startTrial() }
        guard isUnlocked() else { return false }
        guard !inPlace.contains(where: { $0.overlaps(experiment) }) else {
            monthProblem = String(localized: "Something like this is already on.")
            return false
        }
        guard let undo = applier.apply(experiment, until: period.end) else {
            monthProblem = String(localized: "That's already set up, so there's nothing to try.")
            return false
        }
        state.monthTrials = monthTrials + [CoachTrial(experiment: experiment, before: baseline, week: period,
                                                      appliedAt: now(), kept: false, undo: undo)]
        save()
        return true
    }

    /// Takes back a month review's "Try it".
    func undoMonthTrial(_ trial: CoachTrial) {
        monthProblem = nil
        guard monthTrials.contains(where: { $0.id == trial.id }) else { return }
        applier?.undo(trial.undo, weekOver: false)
        let left = monthTrials.filter { $0.id != trial.id }
        state.monthTrials = left.isEmpty ? nil : left
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

    /// "Erase all data": forgets the notes and results worked out from the
    /// erased activity. This week's experiment is undone unless it was kept;
    /// kept changes stay on, and can still be stopped.
    func erase() {
        for trial in [state.running].compactMap({ $0 }) + monthTrials {
            if trial.kept { state.kept.append(trial) } else { applier?.undo(trial.undo, weekOver: true) }
        }
        let kept = state.kept.map { trial -> CoachTrial in
            var trial = trial
            trial.before = nil
            trial.after = nil
            return trial
        }
        state = CoachState(kept: kept)
        problem = nil
        monthProblem = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }
}
