import Foundation
import Observation
import OSLog
import AppKit

/// "That's not it": the person's word on a cause. It's remembered and shown,
/// and the cause stops being named. Nothing is learned from it: no time moves
/// to another cause, and what they say happened changes no numbers.
struct AnalyzerCorrection: Codable, Equatable, Sendable, Identifiable {
    let cause: AnalyzerCause
    /// What they say it was; nil if they didn't say.
    var actual: AnalyzerCause?
    /// Their own line, kept on this Mac.
    var note: String?
    let at: Date

    var id: AnalyzerCause { cause }
}

/// A test that finished, waiting for the person's choice.
struct AnalyzerFinished: Codable, Equatable, Sendable {
    let experiment: AnalyzerExperiment
    let outcome: AnalyzerOutcome
}

/// A fix kept on after its test; "Stop" restores what was there before.
struct AnalyzerKept: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let fix: AnalyzerFix
    let plan: String
    var undo: AnalyzerUndo
    var day: Date
}

/// What the Analyzer remembers between launches.
struct AnalyzerState: Codable, Equatable, Sendable {
    var experiment: AnalyzerExperiment?
    var finished: AnalyzerFinished?
    /// What's on right now for an On day, and how to take it back.
    var applied: Applied?
    var kept: [AnalyzerKept] = []
    var corrections: [AnalyzerCorrection] = []
    /// Causes whose fix showed no clear difference.
    var tested: [AnalyzerCause] = []
    /// The day the last session started, for "first session of the day".
    var lastSessionDay: Date?

    struct Applied: Codable, Equatable, Sendable {
        let day: Date
        let undo: AnalyzerUndo
    }
}

/// One experiment at a time, across the coach and the Analyzer: each stores
/// its state in the same defaults, and each checks the other before starting.
enum AnalyzerGate {
    static func analyzerRunning(_ defaults: UserDefaults) -> Bool {
        defaults.data(forKey: FocusAnalyzer.stateKey)
            .flatMap { try? JSONDecoder().decode(AnalyzerState.self, from: $0) }?.experiment != nil
    }

    static func coachRunning(_ defaults: UserDefaults) -> Bool {
        guard let state = defaults.data(forKey: WeeklyCoach.stateKey)
            .flatMap({ try? JSONDecoder().decode(CoachState.self, from: $0) }) else { return false }
        return state.running != nil || !(state.monthTrials ?? []).isEmpty
    }
}

/// Puts a fix in place on On days and takes it back.
@MainActor
protocol AnalyzerApplying: AnyObject {
    /// Nil when it can't be done, such as a limit that already exists or a
    /// day with no room on the calendar.
    func apply(_ change: AnalyzerChange, on day: Date) async -> AnalyzerUndo?
    func undo(_ undo: AnalyzerUndo) async
    func context() -> AnalyzerFixes.Context
    /// Says the plan again, as a notification.
    func remind(_ plan: String)
    /// Asks for one line for the session that just started.
    func askForGoal()
    /// A test finished.
    func experimentFinished()
}

/// The Analyzer's experiments and what the person told it. Facts come from
/// `AnalyzerReport`, worked out in `StatsStore`; this holds what happens on them.
@MainActor
@Observable
final class FocusAnalyzer {
    static let shared = FocusAnalyzer()

    private(set) var state: AnalyzerState
    /// Why something didn't happen, for a moment.
    private(set) var problem: String?

    /// Days with anything tracked, for settling an experiment's past days.
    @ObservationIgnored var days: ([Date]) async -> [AnalyzerDay] = { _ in [] }
    @ObservationIgnored var applier: AnalyzerApplying?
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored var isUnlocked: () -> Bool = { Entitlements.shared.isUnlocked(.analyzer) }
    @ObservationIgnored var startTrial: () -> Void = { Entitlements.shared.startTrialIfNeeded(for: .analyzer) }
    @ObservationIgnored var weekendsCount: () -> Bool

    private let defaults: UserDefaults
    private let calendar: Calendar
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var attached = false

    static let stateKey = "analyzer.state"

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        self.weekendsCount = { defaults.bool(forKey: SettingsKeys.Goal.weekendsCount) }
        self.state = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(AnalyzerState.self, from: $0) } ?? AnalyzerState()
    }

    /// Hooks it up to the app, and brings today up to date: this is where a
    /// relaunch picks up the experiment.
    func attach(_ appState: AppState) {
        attached = true
        let stats = appState.stats
        days = { [weak appState, calendar] days in
            let busy = appState?.analyzerBusy(from: days.first ?? .now, to: days.last.map { calendar.startOfDay(1, from: $0) } ?? .now)
            return await stats.analyzerDays(days, busy: busy ?? [], calendar: calendar)
        }
        applier = LiveAnalyzerApplier(appState: appState, defaults: defaults)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAndReschedule() }
        }
        Task { await refreshAndReschedule() }
    }

    private func refreshAndReschedule() async {
        await refresh()
        timer?.invalidate()
        timer = nil
        guard state.experiment != nil || !state.kept.isEmpty else { return }
        let wait = WeeklyCoach.nextRefresh(now: now(), due: [calendar.startOfDay(1, from: now())])
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refreshAndReschedule() }
        }
    }

    var muted: Set<AnalyzerCause> { Set(state.corrections.map(\.cause)) }

    var isRunning: Bool { state.experiment != nil }

    /// Whether a new test can start now.
    var coachIsRunning: Bool { AnalyzerGate.coachRunning(defaults) }

    private var today: Date { calendar.startOfDay(for: now()) }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }

    // MARK: - Keeping today right

    /// Settles finished days, then makes today match the schedule.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await settle()
        await syncToday()
        await syncKept()
    }

    /// Past days get their values; what can't count is made up, and the last
    /// one ends the test.
    private func settle() async {
        guard let id = state.experiment?.id, let running = state.experiment else { return }
        let due = running.slots.filter { $0.state == .pending && $0.day < today }.map(\.day)
        guard !due.isEmpty else { return }
        let found = await days(due)
        guard var experiment = state.experiment, experiment.id == id else { return }
        let byDay = Dictionary(found.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let weekends = weekendsCount()
        for day in due {
            let value = byDay[day].flatMap { summary in
                summary.countsForExperiment(weekendsCount: weekends, calendar: calendar) ? experiment.fix.measure.value(summary) : nil
            }
            experiment.resolve(day: day, value: value, today: today, calendar: calendar)
        }
        state.experiment = experiment
        if experiment.isFinished {
            await takeBack()
            state.finished = AnalyzerFinished(experiment: experiment, outcome: experiment.outcome)
            state.experiment = nil
            applier?.experimentFinished()
        }
        save()
    }

    private func takeBack() async {
        guard let applied = state.applied else { return }
        state.applied = nil
        save()
        await applier?.undo(applied.undo)
    }

    /// On on On days, off otherwise. Idempotent, so a relaunch doesn't apply
    /// it twice, and a change left on from yesterday comes off.
    private func syncToday() async {
        let day = today
        let slot = state.experiment?.slot(on: day)
        let wantsOn = isUnlocked() && slot?.arm == .on && slot?.state == .pending
        if let applied = state.applied, applied.day != day || !wantsOn { await takeBack() }
        guard wantsOn, state.applied == nil, let experiment = state.experiment, let applier else { return }
        if let undo = await applier.apply(experiment.fix.change, on: day) {
            guard state.experiment?.id == experiment.id, let index = state.experiment?.slots.firstIndex(where: { $0.day == day }) else {
                await applier.undo(undo)
                return
            }
            state.applied = AnalyzerState.Applied(day: day, undo: undo)
            state.experiment?.slots[index].wasApplied = true
            save()
        }
    }

    /// A kept calendar block is one a day; everything else stays as it was left.
    private func syncKept() async {
        guard isUnlocked(), let applier else { return }
        for index in state.kept.indices {
            guard case .protectBlock = state.kept[index].fix.change, state.kept[index].day != today,
                  weekendsCount() || !calendar.isDateInWeekend(today) else { continue }
            if let undo = await applier.apply(state.kept[index].fix.change, on: today), index < state.kept.count {
                state.kept[index].undo = undo
                state.kept[index].day = today
                save()
            }
        }
    }

    // MARK: - Sessions

    /// A session started. What it does depends on today being an On day, or
    /// on a kept fix.
    func sessionStarted(hasGoal: Bool) {
        guard isUnlocked(), let applier else { return }
        let day = today
        let first = state.lastSessionDay != day
        state.lastSessionDay = day
        save()
        var inForce = state.kept.map { ($0.fix.change, $0.plan) }
        if let experiment = state.experiment, experiment.slot(on: day)?.arm == .on {
            inForce.append((experiment.fix.change, experiment.plan))
        }
        for (change, plan) in inForce {
            switch change {
            case .askForGoal where !hasGoal:
                applier.askForGoal()
            case .messageReminder:
                applier.remind(plan)
            case .hardestFirst where first:
                applier.remind(plan)
            default:
                break
            }
        }
    }

    // MARK: - Choices

    /// "Start tomorrow". False, with `problem` saying why, when it can't: the
    /// plan, another test running, or no OK for the calendar.
    @discardableResult
    func start(_ fix: AnalyzerFix, plan: String, seed: UInt64, calendarOK: Bool) -> Bool {
        problem = nil
        if !isUnlocked() { startTrial() }
        guard isUnlocked(), state.experiment == nil else { return false }
        guard !coachIsRunning else {
            problem = String(localized: "The weekly coach has an experiment on. One at a time keeps both fair.")
            return false
        }
        if case .protectBlock = fix.change, !calendarOK {
            problem = String(localized: "This test needs your OK to add blocks to your calendar.")
            return false
        }
        let typed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        state.experiment = AnalyzerExperiment(
            fix: fix, plan: typed.isEmpty ? fix.change.plan : typed, seed: seed, startedAt: now(),
            slots: AnalyzerExperiment.schedule(after: now(), seed: seed, weekendsCount: weekendsCount(), calendar: calendar))
        state.finished = nil
        save()
        if attached { Task { await refreshAndReschedule() } }
        return true
    }

    /// "Stop it": no result, and the change comes off.
    func stop() async {
        await takeBack()
        state.experiment = nil
        save()
    }

    /// "Keep it": on for good, until it's stopped. What's undone then is what
    /// was there before this.
    func keep() async {
        problem = nil
        guard let finished = state.finished, let applier else { return }
        let fix = finished.experiment.fix
        guard !state.kept.contains(where: { $0.fix.change == fix.change }) else {
            state.finished = nil
            save()
            return
        }
        guard let undo = await applier.apply(fix.change, on: today) else {
            problem = String(localized: "That's already set up, so there's nothing to keep on.")
            return
        }
        state.kept.append(AnalyzerKept(fix: fix, plan: finished.experiment.plan, undo: undo, day: today))
        state.finished = nil
        save()
        if attached { Task { await refreshAndReschedule() } }
    }

    /// "Drop it" and "Try something else": the change stays off.
    func dismissResult() {
        if let finished = state.finished, finished.outcome.verdict == .noDifference,
           !state.tested.contains(finished.experiment.fix.cause) {
            state.tested.append(finished.experiment.fix.cause)
        }
        state.finished = nil
        save()
    }

    /// "Test it again": a new shuffle, from the next working day.
    @discardableResult
    func testAgain(seed: UInt64) -> Bool {
        guard let finished = state.finished else { return false }
        var calendarOK = false
        if case .protectBlock = finished.experiment.fix.change { calendarOK = true }
        return start(finished.experiment.fix, plan: finished.experiment.plan, seed: seed, calendarOK: calendarOK)
    }

    /// Stops a fix that was kept on, restoring what was there before.
    func stopKept(_ kept: AnalyzerKept) async {
        guard state.kept.contains(where: { $0.id == kept.id }) else { return }
        state.kept.removeAll { $0.id == kept.id }
        save()
        await applier?.undo(kept.undo)
    }

    // MARK: - Corrections

    /// "That's not it" and "Tell it what really happened".
    func correct(_ cause: AnalyzerCause, actual: AnalyzerCause? = nil, note: String? = nil) {
        state.corrections.removeAll { $0.cause == cause }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.corrections.append(AnalyzerCorrection(cause: cause, actual: actual, note: trimmed?.isEmpty == true ? nil : trimmed,
                                                    at: now()))
        save()
    }

    /// Takes a correction back.
    func restore(_ cause: AnalyzerCause) {
        state.corrections.removeAll { $0.cause == cause }
        save()
    }

    /// "Erase all data": what was worked out from it goes, and a test running
    /// is undone. Kept fixes stay on, and can still be stopped.
    func erase() async {
        await takeBack()
        state = AnalyzerState(kept: state.kept)
        problem = nil
        save()
    }
}

/// The real settings: limits and the morning plan through the coach's applier,
/// so they undo the same way, and the calendar through its writer.
@MainActor
final class LiveAnalyzerApplier: AnalyzerApplying {
    private weak var appState: AppState?
    private let defaults: UserDefaults
    private let coach: LiveCoachApplier

    init(appState: AppState, defaults: UserDefaults) {
        self.appState = appState
        self.defaults = defaults
        let engine = appState.escalationEngine
        self.coach = LiveCoachApplier(limits: appState.limits, preset: { [weak engine] in engine?.preset ?? .standard }, defaults: defaults)
    }

    func apply(_ change: AnalyzerChange, on day: Date) async -> AnalyzerUndo? {
        guard let appState else { return nil }
        switch change {
        case .askForGoal, .messageReminder:
            return .nothing
        case let .dailyLimit(target, true, _, minutes):
            return coach.apply(.siteLimit(host: target, minutes: minutes), until: nil).map { .coach($0) }
        case let .dailyLimit(target, false, _, minutes):
            guard !appState.limits.statuses.contains(where: { !$0.isSite && $0.target == target }),
                  let limit = appState.limits.addLimit(target: target, isSite: false, minutes: minutes) else { return nil }
            return .coach(.limit(limit.id))
        case let .protectBlock(minutes):
            let next = Calendar.current.startOfDay(1, from: day)
            let busy = appState.analyzerBusy(from: day, to: next)
            guard let slot = AnalyzerFixes.freeSlot(on: day, busy: busy, minutes: minutes, now: .now),
                  await appState.integrations.calendarWriter.protect(slot, minutes: minutes) else { return nil }
            return .calendar(slot: slot)
        case let .hardestFirst(hour?):
            return coach.apply(.earlierMorningPlan(hour: hour), until: nil).map { .coach($0) }
        case .hardestFirst(nil):
            return .nothing
        }
    }

    func undo(_ undo: AnalyzerUndo) async {
        switch undo {
        case .nothing:
            break
        case .coach(let change):
            coach.undo(change, weekOver: true)
        case .calendar(let slot):
            await appState?.integrations.calendarWriter.skipPlanned(slot)
        }
    }

    func context() -> AnalyzerFixes.Context {
        let settings = coach.settings()
        let kept = WeeklyCoach.shared.state.kept.map(\.experiment)
        let morningTaken = kept.contains { if case .earlierMorningPlan = $0 { return true } else { return false } }
        return AnalyzerFixes.Context(canUseCalendar: settings.canReadCalendar, morningPlanHour: settings.morningPlanHour,
                                     morningPlanTaken: morningTaken,
                                     limited: Set(appState?.limits.statuses.map(\.target) ?? []))
    }

    func remind(_ plan: String) {
        appState?.notificationPresenter.deliver(
            NotificationPresenter.request(title: String(localized: "Your plan", comment: "Notification title: the if-then plan of an Analyzer experiment"), body: plan),
            as: .general)
    }

    func askForGoal() {
        appState?.askForAnalyzerGoal()
    }

    func experimentFinished() {
        appState?.notificationPresenter.deliver(
            NotificationPresenter.request(title: String(localized: "Your experiment is done"),
                                          body: String(localized: "The result is on the Analyzer page.")),
            as: .general)
    }
}

extension AppState {
    /// The calendar's busy times, without the events FocusGuard made itself: a
    /// Focus block isn't a meeting.
    func analyzerBusy(from start: Date, to end: Date) -> [DateInterval] {
        CalendarBusyTimes().busy(from: start, to: end, excluding: Set(integrations.calendarWriter.ownIDs)) ?? []
    }

    /// The page's facts, off the main thread.
    func analyzerReport(now: Date = .now, weekendsCount: Bool) async -> AnalyzerReport {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let from = calendar.startOfDay(-2 * AnalyzerRules.periodDays, from: today)
        return await stats.analyzerReport(now: now, weekendsCount: weekendsCount, muted: FocusAnalyzer.shared.muted,
                                          busy: analyzerBusy(from: from, to: today), calendar: calendar)
    }

    /// On an On day, a session with no goal asks for one line in the window.
    func askForAnalyzerGoal() {
        (NSApp.delegate as? AppDelegate)?.openMainWindow()
        // A window that was closed needs a moment to be there to show it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .presentWindowSheet, object: WindowSheet.analyzerGoal)
        }
    }

    /// What's asked of the Analyzer when a session starts.
    func analyzerSessionStarted(_ session: Session?) {
        guard FeatureFlags.analyzer, !UITestMode.isOn, let session else { return }
        let goal = session.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        FocusAnalyzer.shared.sessionStarted(hasGoal: !goal.isEmpty)
    }
}
