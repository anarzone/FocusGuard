import AppKit
import Foundation
import SwiftData

/// Single owner of the SwiftData container and the long-lived runtime services
/// (tracker, session manager, opt-out cache). Created once at app launch.
@MainActor
@Observable
final class AppState {
    let container: ModelContainer
    let permissions: PermissionsCoordinator
    let optOutCache: TitleOptOutCache
    let classifier: Classifier
    let tracker: ActivityTracker
    let sessionManager: SessionManager
    let notificationPresenter: NotificationPresenter
    let escalationEngine: EscalationEngine
    /// Daily limits on sites and apps, counted all day.
    let limits: DailyLimitsEngine
    let calendarAutostart: CalendarAutostartCoordinator
    let patternDetector: PatternDetector
    let breakManager: BreakManager
    let breakOverlay: BreakOverlayController
    /// Morning plan, evening wrap-up, auto-start offers, calls.
    let habits: HabitsCoordinator
    /// The session goal and the debrief after each session (Pro).
    let debriefs: DebriefCoordinator
    /// Free "Pause the tab": the site's tab shows a calm page while it's
    /// blocked, through the browser extension where it's connected and
    /// AppleScript elsewhere.
    let tabPause: TabPauseCoordinator
    let updater: UpdaterController
    /// The browser extension's connection (see ExtensionBridge).
    let extensionBridge: ExtensionBridge
    let insights = AIInsightsViewModel()
    let music = FocusMusic()
    /// Reads the store off the main thread for everything the menu shows.
    let stats: StatsStore
    /// The menu's numbers, refreshed in the background (`refreshMenuStats`);
    /// the menu only reads these.
    private(set) var menuStats = MenuStats()
    /// Insights as last loaded, so the pane opens on them instead of empty.
    var lastTodayInsights: TodayInsights?
    var lastWeekInsights: WeekInsights?
    var lastUsageRows: [UsageRow]?
    /// The window's pages as last loaded; read once when a page opens.
    @ObservationIgnored let windowPages = WindowPageCache()
    @ObservationIgnored private var menuStatsAt: Date = .distantPast
    @ObservationIgnored private var streakAt: Date = .distantPast
    @ObservationIgnored private var refreshingMenuStats = false
    /// Summary of the session that just ended. The menu shows it until the
    /// user starts a break or another session, or it goes stale.
    var recap: SessionRecap?
    @ObservationIgnored var bestZoneCache: (at: Date, value: TimeInterval)?
    @ObservationIgnored var todaySpansCache: (at: Date, value: [DaySpan])?

    init() {
        let schema = Schema([
            Session.self,
            ActivityEvent.self,
            TitleOptOut.self,
            AppRule.self,
            DailyLimit.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // SwiftData failures at launch are unrecoverable for us; surface in the log.
            fatalError("Failed to create ModelContainer: \(error)")
        }

        let context = container.mainContext
        let stats = StatsStore(container: container)
        self.stats = stats
        // Reclassified or erased events: the stats store's past-day totals are stale.
        NotificationCenter.default.addObserver(forName: .activityTotalsChanged, object: nil, queue: .main) { _ in
            Task { await stats.forgetPastDays() }
        }
        DefaultTitleOptOut.seedIfNeeded(in: context)
        DefaultRules.seedIfNeeded(in: context)

        let cache = TitleOptOutCache(context: context)
        let classifier = Classifier(context: context)
        let tracker = ActivityTracker(context: context, optOutCache: cache, classifier: classifier)
        let manager = SessionManager(context: context, tracker: tracker)
        let presenter = NotificationPresenter()
        let blockOverlay = BlockOverlayController()
        let engine = EscalationEngine(presenter: presenter, overlay: blockOverlay)
        let limits = DailyLimitsEngine(context: context, notifier: presenter, overlay: blockOverlay,
                                       policy: { [weak engine] in engine?.policy ?? .standard })
        let bridge = ExtensionBridge()

        self.permissions = PermissionsCoordinator()
        self.optOutCache = cache
        self.classifier = classifier
        self.tracker = tracker
        self.sessionManager = manager
        self.notificationPresenter = presenter
        self.escalationEngine = engine
        self.limits = limits
        self.calendarAutostart = CalendarAutostartCoordinator(sessionManager: manager)
        self.patternDetector = PatternDetector(presenter: presenter)
        let breaks = BreakManager()
        self.breakManager = breaks
        self.breakOverlay = BreakOverlayController()
        self.habits = HabitsCoordinator(sessions: manager, breaks: breaks, tracker: tracker,
                                        presenter: presenter, context: context)
        self.debriefs = DebriefCoordinator(context: context, isOptedOut: { [weak cache] in cache?.isOptedOut($0) ?? true })
        // Starts Sparkle's updater + scheduled background checks.
        self.updater = UpdaterController()
        self.extensionBridge = bridge
        self.tabPause = TabPauseCoordinator(pauser: PreferringTabPauser(
            primary: ExtensionTabPauser(bridge: bridge), fallback: AppleScriptTabPauser()))

        // Hydrate engine config from persisted prefs.
        let defaults = UserDefaults.standard
        engine.silenceThreshold = TimeInterval(
            defaults.object(forKey: SettingsKeys.Escalation.silenceThreshold) as? Int
                ?? Constants.Escalation.defaultSilenceSeconds
        )
        engine.notifyThreshold = TimeInterval(
            defaults.object(forKey: SettingsKeys.Escalation.notifyThreshold) as? Int
                ?? Constants.Escalation.defaultNotifySeconds
        )
        engine.blockThreshold = TimeInterval(
            defaults.object(forKey: SettingsKeys.Escalation.blockThreshold) as? Int
                ?? Constants.Escalation.defaultBlockSeconds
        )
        engine.notifyCooldown = TimeInterval(
            defaults.object(forKey: SettingsKeys.Escalation.cooldown) as? Int
                ?? Constants.Escalation.defaultCooldownSeconds
        )
        engine.strictMode = defaults.bool(forKey: SettingsKeys.Escalation.strictMode)

        // Wire per-tick hooks: planned-duration auto-stop and escalation feed.
        // Escalation must NOT fire while paused — `currentSession` is non-nil
        // during a pause but the user has explicitly opted out of being nagged.
        tracker.onTick = { [weak manager, weak engine, weak tracker, weak self] in
            manager?.checkPlannedDuration()
            // Drive break expiration off the same tick.
            self?.breakManager.checkExpiration()
            // Daily limits count all day, sessions and breaks included, and
            // go first so a used-up limit can't be passed as a drift.
            self?.limits.observe(snapshot: tracker?.currentSnapshot,
                                 counting: tracker?.isFrontmostSelf == false && tracker?.isAway == false)
            if let snap = tracker?.currentSnapshot {
                let inActiveSession = manager?.currentSession != nil
                    && manager?.currentSession?.pausedAt == nil
                let onBreak = self?.breakManager.isOnBreak ?? false
                // EscalationEngine + PatternDetector stay silent during a
                // break — interruptions defeat the point.
                // Time in FocusGuard's own windows never counts as drift:
                // the engine sees a neutral moment, which resets any streak.
                let observed = tracker?.isFrontmostSelf == true ? snap.asNeutral(at: .now) : snap
                if !onBreak {
                    engine?.observe(snapshot: observed, isInSession: inActiveSession)
                    self?.patternDetector.observe(snapshot: observed, isInSession: inActiveSession)
                }
            }
            self?.habits.tick()
            self?.maybeAutoPauseOrResume()
        }

        // Session boundaries: reset escalation, prompt for break, send notif.
        manager.onSessionStarted = { [weak self, weak manager] in
            self?.recap = nil
            self?.debriefs.sessionStarted(manager?.currentSession)
            SystemFocusBridge.onSessionStarted()
            self?.music.sessionStarted()
        }
        manager.onSessionPauseChanged = { [weak self] paused in
            if paused { self?.music.sessionPaused() } else { self?.music.sessionResumed() }
        }
        manager.onSessionEnded = { [weak engine, weak self] session in
            engine?.resetForSessionEnd()
            self?.tabPause.sessionEnded()
            SystemFocusBridge.onSessionEnded()
            guard let self else { return }
            self.music.sessionEnded()
            self.recap = SessionRecap(session: session, bestZoneToday: self.bestZoneToday(fresh: true))
            self.debriefs.sessionEnded(session)
            self.presentSessionComplete(for: session)
        }

        // Wire break overlay buttons → BreakManager actions.
        self.breakOverlay.onSkip = { [weak self] in
            self?.breakManager.skip()
        }
        self.breakOverlay.onExtend = { [weak self] minutes in
            self?.breakManager.extend(byMinutes: minutes)
        }
        self.breakOverlay.onClose = {
            // Closing the overlay just hides it — the timer keeps running
            // and the menu bar shows the countdown.
        }
        self.breakManager.onBreakCompleted = { [weak self] in
            self?.notificationPresenter.presentBreakOver()
        }
        self.breakManager.onBreakEnded = { [weak self] in
            self?.breakOverlay.dismiss()
        }

        // The block screen reads the live session and acts on it.
        blockOverlay.contextProvider = { [weak self] in self?.blockContext() }
        blockOverlay.backToAppProvider = { [weak self] in self?.backToAppName() }
        classifier.isBlockListLocked = { [weak self] in self?.isStrictLocked ?? false }
        smartCategories.attach(tracker: tracker)
        blockOverlay.onBackToWork = { [weak self] in self?.backToWork() }
        blockOverlay.onAllowForSession = { [weak self] in self?.allowCurrentDriftForSession() }
        blockOverlay.onPresent = { [weak self] request in self?.pauseTab(behind: request) }
        blockOverlay.onLetThrough = { [weak self] in self?.tabPause.letThrough() }
        wireMoments(blockOverlay: blockOverlay)

        // Browser extension: its tab reports replace AppleScript while it's
        // connected; its block pages follow the preset, the daily limits and
        // the escalation engine's passes.
        tracker.extensionTab = { [weak bridge] id in bridge?.tab(forBrowser: id) }
        bridge.presetProvider = { [weak engine] in engine?.presetInForce() ?? .standard }
        bridge.limitsProvider = { [weak limits] in limits?.statuses ?? [] }
        bridge.extraTimeHandler = { [weak limits] id in limits?.takeExtraTime(for: id) ?? false }
        bridge.grantEnginePass = { [weak engine] snapshot in engine?.takePass(for: snapshot) }

        wireNotifications()
        tabPause.isEnabled = defaults.object(forKey: SettingsWindowKey.pauseTab) as? Bool ?? true
        tracker.start()
        bridge.start(appState: self)
        setupAutoPauseObservers()

        // One-time cleanup of pre-fix idle events (loginwindow / screensaver)
        // that the old tracker counted as activity.
        HistoricalCleanup.runIfNeeded(context: context)
        SelfTrackingCleanup.runIfNeeded(context: context)

        // Apply retention policy on launch, then once a day while running.
        RetentionPolicy.prune(context: context)
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                RetentionPolicy.prune(context: self.container.mainContext)
            }
        }

        // Shortcuts, Siri, Spotlight, the Focus filter, the widgets and the
        // Control Center control act on this state.
        SurfaceHost.attach(self)
        // "Share week" posts .openShareComposer.
        ShareComposerWindow.shared.observe(self)
        // The weekly coach's experiments act through the limits and settings.
        WeeklyCoach.shared.attach(self)
    }

    /// Refreshes `menuStats` in the background, at most every 5 s (the
    /// streak every 5 min). The menu calls this every tick; it never waits.
    func refreshMenuStats(force: Bool = false) {
        let now = Date()
        if force { prefetchPanes(now: now) }
        guard !refreshingMenuStats, force || now.timeIntervalSince(menuStatsAt) >= 5 else { return }
        refreshingMenuStats = true
        let includeStreak = force || now.timeIntervalSince(streakAt) >= 300
        Task {
            let update = await stats.menuStats(now: now, includeStreak: includeStreak)
            var next = menuStats
            next.today = update.today
            next.spans = update.spans
            next.bestZone = update.bestZone
            if let streak = update.streak {
                next.streak = streak
                streakAt = now
            }
            if next != menuStats { menuStats = next }
            menuStatsAt = now
            refreshingMenuStats = false
        }
    }

    /// Loads Insights and Apps & sites in the background the first time the
    /// menu opens, so even their first opening slides in with data.
    private func prefetchPanes(now: Date) {
        guard lastTodayInsights == nil || lastUsageRows == nil else { return }
        Task {
            if lastTodayInsights == nil { lastTodayInsights = await stats.today(now: now) }
            if lastUsageRows == nil {
                lastUsageRows = await stats.usageRows(from: Calendar.current.startOfDay(for: now), to: now, limit: 40)
            }
        }
    }

    /// A session from a summary built off the main thread.
    func session(_ id: PersistentIdentifier) -> Session? {
        container.mainContext.model(for: id) as? Session
    }

    /// Computed: total seconds tracked today across all events.
    var todayTrackedSeconds: TimeInterval {
        todayBreakdown.total
    }

    var todayEventCount: Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= startOfDay }
        )
        return (try? container.mainContext.fetchCount(descriptor)) ?? 0
    }

    /// (focus, neutral, distraction) seconds today, plus their total.
    /// Cached for 5s to keep popover redraws cheap.
    private var cachedBreakdown: BreakdownSnapshot?
    private var lastBreakdownAt: Date?

    var todayBreakdown: BreakdownSnapshot {
        if let last = lastBreakdownAt, let cached = cachedBreakdown,
           Date().timeIntervalSince(last) < 5 {
            return cached
        }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= startOfDay }
        )
        let events = (try? container.mainContext.fetch(descriptor)) ?? []
        var focus: TimeInterval = 0, neutral: TimeInterval = 0, distraction: TimeInterval = 0
        for e in events {
            let start = max(e.startedAt, startOfDay)
            let dur = max(0, e.endedAt.timeIntervalSince(start))
            switch e.classification ?? .neutral {
            case .focus:       focus += dur
            case .neutral:     neutral += dur
            case .distraction: distraction += dur
            }
        }
        let snap = BreakdownSnapshot(focus: focus, neutral: neutral, distraction: distraction)
        cachedBreakdown = snap
        lastBreakdownAt = .now
        return snap
    }

    /// Tracked seconds for each of the last 7 days, oldest first.
    /// Cached for 30s to keep the menu bar tick cheap.
    private var cachedWeek: [TimeInterval] = Array(repeating: 0, count: 7)
    private var lastWeekFetchAt: Date?
    private var cachedWeekBreakdowns: [DailyBreakdown] = []
    private var lastWeekBreakdownsAt: Date?

    /// Last 7 days as classification-split breakdowns, oldest first. Used by
    /// the popover/Home week chart that stacks focus/neutral/distraction.
    var weekDailyBreakdowns: [DailyBreakdown] {
        if let last = lastWeekBreakdownsAt, Date().timeIntervalSince(last) < Constants.Cache.weekStatsTTL,
           !cachedWeekBreakdowns.isEmpty {
            return cachedWeekBreakdowns
        }
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        let from = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now)) ?? .now
        let result = ReportBuilder(context: container.mainContext)
            .dailyBreakdowns(from: from, to: endOfToday)
        cachedWeekBreakdowns = result
        lastWeekBreakdownsAt = .now
        return result
    }

    var weekTrackedSeconds: [TimeInterval] {
        if let last = lastWeekFetchAt, Date().timeIntervalSince(last) < 30 {
            return cachedWeek
        }
        let calendar = Calendar.current
        let context = container.mainContext
        var out: [TimeInterval] = []
        for offset in (0..<7).reversed() {
            let day = calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let descriptor = FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { $0.endedAt >= dayStart && $0.startedAt < dayEnd }
            )
            let events = (try? context.fetch(descriptor)) ?? []
            let total = events.reduce(0.0) {
                let start = max($1.startedAt, dayStart)
                let end = min($1.endedAt, dayEnd)
                return $0 + max(0, end.timeIntervalSince(start))
            }
            out.append(total)
        }
        cachedWeek = out
        lastWeekFetchAt = .now
        return out
    }

    /// Average tracked seconds across the last 7 days excluding today.
    var weeklyAverageSeconds: TimeInterval {
        let week = weekTrackedSeconds
        let prior = week.dropLast()  // exclude today
        guard !prior.isEmpty else { return 0 }
        return prior.reduce(0, +) / Double(prior.count)
    }

    /// Average FOCUS seconds across the last 7 days excluding today.
    /// Used by the popover hero's "vs avg" delta so the comparison matches
    /// the metric we're displaying (focus minutes, not total tracked).
    /// Cached for `Constants.Cache.weekStatsTTL` to keep the popover tick cheap.
    private var cachedWeeklyAvgFocus: TimeInterval = 0
    private var lastWeeklyAvgFocusAt: Date?

    var weeklyAverageFocusSeconds: TimeInterval {
        if let last = lastWeeklyAvgFocusAt,
           Date().timeIntervalSince(last) < Constants.Cache.weekStatsTTL {
            return cachedWeeklyAvgFocus
        }
        let calendar = Calendar.current
        let context = container.mainContext
        var perDayFocus: [TimeInterval] = []
        for offset in 1...6 {  // exclude today
            let day = calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let focusRaw = Classification.focus.rawValue
            let descriptor = FetchDescriptor<ActivityEvent>(
                predicate: #Predicate {
                    $0.endedAt >= dayStart && $0.startedAt < dayEnd && $0.classificationRaw == focusRaw
                }
            )
            let events = Persistence.fetch(context, descriptor)
            let total = events.reduce(0.0) {
                let s = max($1.startedAt, dayStart)
                let e = min($1.endedAt, dayEnd)
                return $0 + max(0, e.timeIntervalSince(s))
            }
            perDayFocus.append(total)
        }
        let avg = perDayFocus.isEmpty ? 0 : perDayFocus.reduce(0, +) / Double(perDayFocus.count)
        cachedWeeklyAvgFocus = avg
        lastWeeklyAvgFocusAt = .now
        return avg
    }

    // MARK: - Break helpers

    /// Pomodoro-style scale: 25→5, 50→10, 90→20. Falls back to 5 for tiny
    /// custom sessions, 20 for anything > 90.
    nonisolated static func suggestedBreakMinutes(forSessionMinutes mins: Int) -> Int {
        switch mins {
        case ..<35:  return 5
        case ..<70:  return 10
        case ..<105: return 15
        default:     return 20
        }
    }

    /// Public so menu-bar/popover code can also start a break manually later.
    func startBreak(durationMinutes: Int) {
        recap = nil
        breakManager.startBreak(durationMinutes: durationMinutes)
        breakOverlay.present(breakManager: breakManager)
    }

    // MARK: - Auto-pause

    /// Set when WE auto-paused — distinguishes from a user-initiated pause so
    /// we know when it's safe to auto-resume. Cleared on stop / user resume.
    private var autoPausedAt: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let autoPauseIdleSeconds: TimeInterval = 300  // 5 min

    private func setupAutoPauseObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let lock = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoPauseIfActive(reason: "screens slept") }
        }
        let unlock = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoResumeIfWePaused() }
        }
        let sessionLock = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoPauseIfActive(reason: "screen locked") }
        }
        let sessionUnlock = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoResumeIfWePaused() }
        }
        workspaceObservers = [lock, unlock, sessionLock, sessionUnlock]
    }

    /// Called from the tracker tick — auto-pause when no event has ended in
    /// `autoPauseIdleSeconds`, auto-resume when activity resumes.
    func maybeAutoPauseOrResume() {
        guard let session = sessionManager.currentSession else { return }
        // Don't touch a user-initiated pause.
        if session.pausedAt != nil && autoPausedAt == nil { return }

        // Recent activity? Use the tracker's last snapshot timestamp.
        let lastObserved = tracker.lastActiveAt ?? tracker.currentSnapshot?.observedAt ?? .distantPast
        let idle = Date().timeIntervalSince(lastObserved)

        if session.pausedAt == nil, idle >= autoPauseIdleSeconds {
            autoPauseIfActive(reason: "idle \(Int(idle))s", since: lastObserved)
        } else if let _ = session.pausedAt, autoPausedAt != nil, idle < 30 {
            autoResumeIfWePaused()
        }
    }

    private func autoPauseIfActive(reason: String, since: Date = .now) {
        guard let session = sessionManager.currentSession,
              session.pausedAt == nil else { return }
        sessionManager.pauseSession(at: since)
        autoPausedAt = .now
    }

    private func autoResumeIfWePaused() {
        guard autoPausedAt != nil,
              let session = sessionManager.currentSession,
              session.pausedAt != nil else { return }
        sessionManager.resumeSession()
        autoPausedAt = nil
    }

    // MARK: - Streak

    private var cachedStreak: Int = 0
    private var lastStreakAt: Date?

    /// Consecutive days hitting the focus goal, walking back from yesterday.
    /// Cached for 5 min — popover redraws on every tick, this query touches
    /// 60 days of events.
    var currentStreak: Int {
        if let last = lastStreakAt, Date().timeIntervalSince(last) < 300 {
            return cachedStreak
        }
        let value = StreakCalculator(context: container.mainContext).currentStreak()
        cachedStreak = value
        lastStreakAt = .now
        return value
    }
}
