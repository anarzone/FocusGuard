import AppKit
import WidgetKit

/// Keeps the desktop widgets and the Control Center control current: it
/// writes the snapshot they read to the shared folder, reloads them when
/// the state changes, and carries out what they ask for.
///
/// Widget reloads are rationed by macOS, so they happen on a change of
/// state (start, pause, end, a break) and otherwise every ten minutes at
/// most; between reloads the widgets count down on their own. The control
/// shows whole minutes, so it reloads when that number changes.
@MainActor
final class SurfacesCoordinator {
    private weak var appState: AppState?
    private let store: SurfaceStore
    private let stats: SurfaceStats
    private var timer: Timer?
    private var activityObserver: NSObjectProtocol?

    private var lastState: StateKey?
    private var lastMinute: Int?
    private var lastWrite: Date = .distantPast
    private var lastWidgetReload: Date = .distantPast
    /// Commands carried out, newest last, echoed in the snapshot so the
    /// extension knows when to stop waiting.
    private var handled: [UUID] = []
    private var writing = false
    private var queued: (widgets: Bool, controls: Bool)?

    static let widgetReloadInterval: TimeInterval = 10 * 60

    init(appState: AppState, store: SurfaceStore) {
        self.appState = appState
        self.store = store
        self.stats = SurfaceStats(container: appState.container)
    }

    func start() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coordinator = Unmanaged<SurfacesCoordinator>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.takeCommands() } }
            },
            SurfaceStore.commandPosted as CFString, nil, .deliverImmediately
        )
        activityObserver = NotificationCenter.default.addObserver(forName: .activityTotalsChanged, object: nil,
                                                                  queue: .main) { [stats] _ in
            Task { await stats.forgetPastDays() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let now = Date()
        lastState = stateKey(now: now)
        lastMinute = shownMinute(now: now)
        refresh(widgets: true, controls: true)
        // A tap while FocusGuard wasn't running launched it; carry it out.
        takeCommands()
    }

    // MARK: - Changes

    /// What, when it changes, makes the widgets out of date.
    private struct StateKey: Equatable {
        let phase: SurfaceSnapshot.Phase
        let session: UUID?
        let plannedMinutes: Int?
        let breakEndsAt: Date?
        let day: Date
    }

    private func stateKey(now: Date) -> StateKey? {
        guard let appState else { return nil }
        let session = appState.sessionManager.currentSession
        let onBreak = appState.breakManager.current
        let phase: SurfaceSnapshot.Phase = onBreak != nil ? .onBreak
            : session.map { $0.pausedAt == nil ? .focusing : .paused } ?? .ready
        return StateKey(phase: phase, session: onBreak == nil ? session?.id : nil,
                        plannedMinutes: session?.plannedDurationMinutes,
                        breakEndsAt: onBreak.map { $0.startedAt.addingTimeInterval($0.plannedDuration) },
                        day: Calendar.current.startOfDay(for: now))
    }

    /// The whole minutes the control shows: left in a timed session or a
    /// break, so far in an open-ended one.
    private func shownMinute(now: Date) -> Int? {
        guard let appState else { return nil }
        if let state = appState.breakManager.current { return AppState.minutesRoundedUp(state.remaining(now: now)) }
        guard let session = appState.sessionManager.currentSession else { return nil }
        let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
        if let planned = session.plannedDurationMinutes {
            return AppState.minutesRoundedUp(TimeInterval(planned * 60) - elapsed)
        }
        return Int(elapsed / 60)
    }

    private func tick(now: Date = .now) {
        let state = stateKey(now: now)
        if state != lastState {
            lastState = state
            lastMinute = shownMinute(now: now)
            refresh(widgets: true, controls: true)
            return
        }
        let minute = shownMinute(now: now)
        if minute != lastMinute {
            lastMinute = minute
            refresh(widgets: now.timeIntervalSince(lastWidgetReload) >= Self.widgetReloadInterval, controls: true)
            return
        }
        // Today's numbers grow outside sessions too.
        if now.timeIntervalSince(lastWrite) >= 5 * 60 {
            refresh(widgets: now.timeIntervalSince(lastWidgetReload) >= Self.widgetReloadInterval, controls: false)
        }
    }

    // MARK: - Writing

    func refresh(widgets: Bool, controls: Bool) {
        guard !writing else {
            queued = (widgets || (queued?.widgets ?? false), controls || (queued?.controls ?? false))
            return
        }
        guard let appState else { return }
        writing = true
        let now = Date()
        lastWrite = now
        let goal = FocusGoal.dailySeconds
        Task {
            let numbers = await stats.read(now: now, goal: goal)
            let snapshot = SurfaceSnapshotBuilder.make(
                sessions: appState.sessionManager, breaks: appState.breakManager,
                timeline: { appState.liveTimeline(for: $0, now: now) },
                numbers: numbers, goal: goal,
                usualMinutes: FocusActions.usualMinutes(),
                handled: handled, now: now
            )
            try? store.write(snapshot)
            if widgets {
                WidgetCenter.shared.reloadAllTimelines()
                lastWidgetReload = now
            }
            if controls, #available(macOS 26.0, *) {
                ControlCenter.shared.reloadAllControls()
            }
            writing = false
            if let next = queued {
                queued = nil
                refresh(widgets: next.widgets, controls: next.controls)
            }
        }
    }

    // MARK: - Commands

    /// Carries out the taps waiting in the shared folder.
    func takeCommands() {
        guard let appState else { return }
        let commands = store.takeCommands()
        guard !commands.isEmpty else { return }
        let actions = FocusActions(sessions: appState.sessionManager, breaks: appState.breakManager,
                                   startBreak: { [weak appState] in appState?.startBreak(durationMinutes: $0) })
        for command in commands {
            Self.perform(command.action, with: actions)
            handled.append(command.id)
        }
        handled = Array(handled.suffix(8))
        let now = Date()
        lastState = stateKey(now: now)
        lastMinute = shownMinute(now: now)
        refresh(widgets: true, controls: true)
    }

    static func perform(_ action: SurfaceCommand.Action, with actions: FocusActions) {
        switch action {
        case .start(let minutes):       actions.start(minutes: minutes)
        case .end:                      actions.end()
        case .togglePause:              actions.pauseOrResume(.toggle)
        case .endBreak:                 actions.endBreak()
        case .extendBreak(let minutes): actions.extendBreak(minutes: minutes)
        }
    }
}
