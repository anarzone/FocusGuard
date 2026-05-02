import Foundation
import SwiftData

/// Single owner of the SwiftData container and the long-lived runtime services
/// (tracker, session manager, opt-out cache). Created once at app launch.
@MainActor
@Observable
final class AppState {
    let container: ModelContainer
    let optOutCache: TitleOptOutCache
    let classifier: Classifier
    let tracker: ActivityTracker
    let sessionManager: SessionManager
    let notificationPresenter: NotificationPresenter
    let escalationEngine: EscalationEngine
    let calendarAutostart: CalendarAutostartCoordinator

    init() {
        let schema = Schema([
            Session.self,
            ActivityEvent.self,
            TitleOptOut.self,
            AppRule.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // SwiftData failures at launch are unrecoverable for us; surface in the log.
            fatalError("Failed to create ModelContainer: \(error)")
        }

        let context = container.mainContext
        DefaultTitleOptOut.seedIfNeeded(in: context)
        DefaultRules.seedIfNeeded(in: context)

        let cache = TitleOptOutCache(context: context)
        let classifier = Classifier(context: context)
        let tracker = ActivityTracker(context: context, optOutCache: cache, classifier: classifier)
        let manager = SessionManager(context: context, tracker: tracker)
        let presenter = NotificationPresenter()
        let engine = EscalationEngine(presenter: presenter)

        self.optOutCache = cache
        self.classifier = classifier
        self.tracker = tracker
        self.sessionManager = manager
        self.notificationPresenter = presenter
        self.escalationEngine = engine
        self.calendarAutostart = CalendarAutostartCoordinator(sessionManager: manager)

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
        tracker.onTick = { [weak manager, weak engine, weak tracker] in
            manager?.checkPlannedDuration()
            if let snap = tracker?.currentSnapshot {
                let inActiveSession = manager?.currentSession != nil
                    && manager?.currentSession?.pausedAt == nil
                engine?.observe(snapshot: snap, isInSession: inActiveSession)
            }
        }

        // Session boundaries: reset escalation, send completion notification.
        manager.onSessionEnded = { [weak engine, weak self] session in
            engine?.resetForSessionEnd()
            guard let self else { return }
            let breakdown = ReportBuilder(context: context)
                .breakdown(from: session.startedAt, to: session.endedAt ?? .now)
            let focusMin = Int(breakdown.focus / 60)
            let pct = Int((breakdown.focusPercent * 100).rounded())
            self.notificationPresenter.presentSessionComplete(
                label: session.label,
                focusMinutes: focusMin,
                focusPercent: pct
            )
        }

        tracker.start()

        // Apply retention policy on launch, then once a day while running.
        RetentionPolicy.prune(context: context)
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                RetentionPolicy.prune(context: self.container.mainContext)
            }
        }
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
            let descriptor = FetchDescriptor<ActivityEvent>(
                predicate: #Predicate {
                    $0.endedAt >= dayStart && $0.startedAt < dayEnd && $0.classificationRaw == 0
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
}
