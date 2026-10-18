import Foundation
import SwiftData

/// User-configurable data retention. Old `ActivityEvent` and `Session` rows
/// older than the cutoff are deleted on launch + once a day while the app
/// is running. Default is 365 days; user can lower in Privacy → Retention.
/// One-time cleanup of historical data that the v0.1 tracker collected
/// before we shipped the idle-process skip. We ran for several days
/// counting `loginwindow` / `ScreenSaver.Engine` time as activity, which
/// dwarfs real usage when the Mac was locked overnight. Run on launch
/// once; after that the new tracker prevents the data from being created.
enum HistoricalCleanup {
    private static let migrationKey = "historicalCleanup.idleEvents.v1"
    private static let idleBundleIds = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.WindowManager",
    ]

    @MainActor
    @discardableResult
    static func runIfNeeded(context: ModelContext) -> Int {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return 0 }

        var deleted = 0
        for bid in idleBundleIds {
            deleted += Persistence.deleteAll(ActivityEvent.self, where: #Predicate { $0.bundleIdentifier == bid }, in: context)
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
        if deleted > 0 {
            Persistence.logger.info("historical cleanup removed \(deleted, privacy: .public) idle events")
        }
        return deleted
    }
}

/// One-time removal of time FocusGuard recorded in its own windows, from
/// before it stopped tracking itself.
enum SelfTrackingCleanup {
    static let migrationKey = "historicalCleanup.selfEvents.v1"

    @MainActor
    @discardableResult
    static func runIfNeeded(context: ModelContext, defaults: UserDefaults = .standard,
                            bundleId: String = ActivityTracker.selfBundleId) -> Int {
        guard !defaults.bool(forKey: migrationKey) else { return 0 }
        let deleted = Persistence.deleteAll(ActivityEvent.self, where: #Predicate { $0.bundleIdentifier == bundleId }, in: context)
        // Only mark done once nothing is left, so a failed run retries next launch.
        let left = Persistence.fetchCount(context, FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.bundleIdentifier == bundleId }))
        if left == 0 { defaults.set(true, forKey: migrationKey) }
        return deleted
    }
}

enum RetentionPolicy {
    /// Days of history to keep. Persisted via UserDefaults; 0 means keep all.
    static var days: Int {
        get {
            let raw = UserDefaults.standard.integer(forKey: "retentionDays")
            return raw == 0 && UserDefaults.standard.object(forKey: "retentionDays") == nil
                ? 365
                : raw
        }
        set { UserDefaults.standard.set(newValue, forKey: "retentionDays") }
    }

    /// Choices we expose in the Settings → Privacy picker.
    static let choices: [(label: String, days: Int)] = [
        ("30 days", 30),
        ("90 days", 90),
        ("6 months", 180),
        ("1 year", 365),
        ("Keep all", 0),
    ]

    @MainActor
    @discardableResult
    static func prune(context: ModelContext) -> Int {
        let cutoff = days
        guard cutoff > 0 else { return 0 }
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -cutoff, to: .now) ?? .now

        var pruned = 0

        // Delete old activity events (paged; batch delete fails on rows
        // that belong to a session — see Persistence.deleteAll).
        pruned += Persistence.deleteAll(ActivityEvent.self, where: #Predicate { $0.endedAt < cutoffDate }, in: context)

        // Delete old completed sessions. Keep active sessions regardless of age.
        // SwiftData #Predicate doesn't allow `?? .distantFuture` — use a coalesced
        // explicit endedAt check instead.
        let activeRaw = SessionStatus.active.rawValue
        let sessionPredicate = #Predicate<Session> { session in
            session.statusRaw != activeRaw && session.endedAt != nil && session.endedAt! < cutoffDate
        }
        pruned += Persistence.deleteAll(Session.self, where: sessionPredicate, in: context)

        Persistence.save(context)
        if pruned > 0 {
            Persistence.logger.info("retention pruned \(pruned, privacy: .public) rows older than \(cutoff, privacy: .public) days")
        }
        return pruned
    }
}
