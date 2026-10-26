import Foundation

/// What Shortcuts, Siri, Spotlight, the widgets and the Focus filter can do
/// to a session or a break. Each action says what happened, so the caller
/// can put it in words; none of them asks anything or shows UI beyond what
/// the menu would (a break still brings up its screen).
@MainActor
struct FocusActions {
    let sessions: SessionManager
    let breaks: BreakManager
    /// Starts a break the way the menu does, with its screen.
    let startBreak: (Int) -> Void
    var defaults: UserDefaults = .standard

    /// The live app's actions. Waits a moment for launch to finish when the
    /// system started FocusGuard just to run an intent.
    static func live() async throws -> FocusActions {
        let appState = try await SurfaceHost.ready()
        return FocusActions(sessions: appState.sessionManager, breaks: appState.breakManager,
                            startBreak: { [weak appState] in appState?.startBreak(durationMinutes: $0) })
    }

    // MARK: - Lengths

    /// The length the menu would start with: the last one used, else the
    /// default from Settings.
    var usualMinutes: Int { Self.usualMinutes(defaults) }

    static func usualMinutes(_ defaults: UserDefaults = .standard) -> Int {
        // A weekly coach experiment ("25-minute sessions after 17:00") comes first.
        if let coach = CoachRules.sessionMinutes(at: .now, defaults) { return clamp(coach) }
        let last = defaults.integer(forKey: SurfaceKeys.lastSessionMinutes)
        let fallback = defaults.object(forKey: SessionDefaultsKey.durationMinutes) as? Int ?? 50
        return clamp(last > 0 ? last : fallback)
    }

    static func clamp(_ minutes: Int) -> Int {
        min(Constants.SessionDurations.customMax, max(Constants.SessionDurations.customMin, minutes))
    }

    static let breakRange = 1...60

    // MARK: - Session

    enum StartResult: Equatable {
        /// `minutes` nil: open-ended.
        case started(name: String, minutes: Int?, endsAt: Date?)
        case alreadyRunning(name: String)
        /// A strict break can't be cut short, so the session waits.
        case onStrictBreak(until: Date)
    }

    /// Starts a session. A break that can end early ends first, as if the
    /// user pressed "End break" and then started.
    /// - Parameters:
    ///   - minutes: planned length; nil means the usual one.
    ///   - openEnded: run until ended (the Focus filter's "While Work is on").
    ///   - startedAt: an earlier start, for the auto-start offer.
    @discardableResult
    func start(minutes: Int? = nil, openEnded: Bool = false, label: String? = nil, startedAt: Date? = nil,
               now: Date = .now) -> StartResult {
        if let session = sessions.currentSession { return .alreadyRunning(name: session.displayName) }
        if let state = breaks.current {
            guard breaks.canEndEarly else { return .onStrictBreak(until: state.startedAt.addingTimeInterval(state.plannedDuration)) }
            breaks.skip()
        }
        let planned = openEnded ? nil : Self.clamp(minutes ?? usualMinutes)
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultLabel = defaults.string(forKey: SessionDefaultsKey.label) ?? ""
        let chosen = (name?.isEmpty == false ? name : nil) ?? (defaultLabel.isEmpty ? nil : defaultLabel)
        sessions.startSession(label: chosen, plannedDurationMinutes: planned, startedAt: startedAt)
        let start = startedAt.map { min($0, now) } ?? now
        return .started(name: sessions.currentSession?.displayName ?? "", minutes: planned,
                        endsAt: planned.map { start.addingTimeInterval(TimeInterval($0 * 60)) })
    }

    enum EndResult: Equatable {
        case ended(name: String, minutes: Int)
        case nothingRunning
    }

    @discardableResult
    func end(now: Date = .now) -> EndResult {
        guard let session = sessions.currentSession else { return .nothingRunning }
        let minutes = Int(sessions.runningSeconds(for: session, now: now) / 60)
        sessions.stopSession()
        return .ended(name: session.displayName, minutes: minutes)
    }

    enum PauseMode: Equatable { case toggle, pause, resume }

    enum PauseResult: Equatable {
        /// `left`: seconds left in a timed session.
        case paused(name: String, left: TimeInterval?)
        case resumed(name: String, endsAt: Date?)
        case alreadyPaused(name: String)
        case alreadyRunning(name: String)
        case nothingRunning
    }

    @discardableResult
    func pauseOrResume(_ mode: PauseMode = .toggle, now: Date = .now) -> PauseResult {
        guard let session = sessions.currentSession else { return .nothingRunning }
        let name = session.displayName
        let isPaused = session.pausedAt != nil
        switch (mode, isPaused) {
        case (.pause, true):    return .alreadyPaused(name: name)
        case (.resume, false):  return .alreadyRunning(name: name)
        case (.toggle, false), (.pause, false):
            sessions.pauseSession(at: now)
            return .paused(name: name, left: timeLeft(session, now: now))
        case (.toggle, true), (.resume, true):
            sessions.resumeSession()
            return .resumed(name: name, endsAt: timeLeft(session, now: now).map { now.addingTimeInterval($0) })
        }
    }

    private func timeLeft(_ session: Session, now: Date) -> TimeInterval? {
        session.plannedDurationMinutes.map { max(0, TimeInterval($0 * 60) - sessions.runningSeconds(for: session, now: now)) }
    }

    // MARK: - Break

    enum BreakResult: Equatable {
        /// `endedSession`: the session that was running and ended for it.
        case started(minutes: Int, until: Date, endedSession: String?)
        case alreadyOnBreak(until: Date)
    }

    /// A break ends any running session first, like finishing it and
    /// taking the break the menu offers.
    @discardableResult
    func takeBreak(minutes: Int, now: Date = .now) -> BreakResult {
        if let state = breaks.current {
            return .alreadyOnBreak(until: state.startedAt.addingTimeInterval(state.plannedDuration))
        }
        let length = min(Self.breakRange.upperBound, max(Self.breakRange.lowerBound, minutes))
        var ended: String?
        if case .ended(let name, _) = end(now: now) { ended = name }
        startBreak(length)
        let until = breaks.current.map { $0.startedAt.addingTimeInterval($0.plannedDuration) }
            ?? now.addingTimeInterval(TimeInterval(length * 60))
        return .started(minutes: length, until: until, endedSession: ended)
    }

    enum EndBreakResult: Equatable {
        case ended
        case strict(until: Date)
        case notOnBreak
    }

    @discardableResult
    func endBreak() -> EndBreakResult {
        guard let state = breaks.current else { return .notOnBreak }
        guard breaks.canEndEarly else { return .strict(until: state.startedAt.addingTimeInterval(state.plannedDuration)) }
        breaks.skip()
        return .ended
    }

    func extendBreak(minutes: Int = 5) {
        breaks.extend(byMinutes: minutes)
    }
}

/// Where intents find the running app, and what keeps the widgets current.
@MainActor
enum SurfaceHost {
    static weak var appState: AppState?
    private static var coordinator: SurfacesCoordinator?

    /// Called once the app state is up.
    static func attach(_ appState: AppState) {
        self.appState = appState
        guard coordinator == nil, let store = SurfaceStore.shared else { return }
        coordinator = SurfacesCoordinator(appState: appState, store: store)
        coordinator?.start()
    }

    /// The app state, waiting up to five seconds for launch to finish.
    static func ready() async throws -> AppState {
        for _ in 0..<50 {
            if let appState { return appState }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FocusIntentError.notReady
    }
}

enum SurfaceKeys {
    /// The menu's remembered length (see MenuBarView).
    static let lastSessionMinutes = "menu.lastSessionMinutes"
}

enum FocusIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "FocusGuard is still starting. Try again in a moment."
        }
    }
}
