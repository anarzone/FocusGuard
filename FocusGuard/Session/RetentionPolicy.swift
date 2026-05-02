import Foundation
import SwiftData

/// User-configurable data retention. Old `ActivityEvent` and `Session` rows
/// older than the cutoff are deleted on launch + once a day while the app
/// is running. Default is 365 days; user can lower in Privacy → Retention.
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

        // Delete old activity events. Use a predicate-driven batch delete so
        // SwiftData doesn't load every row into memory.
        let eventCount = Persistence.fetchCount(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt < cutoffDate }
        ))
        if eventCount > 0 {
            do {
                try context.delete(model: ActivityEvent.self,
                                  where: #Predicate { $0.endedAt < cutoffDate })
                pruned += eventCount
            } catch {
                Persistence.logger.error("retention prune failed (events): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Delete old completed sessions. Keep active sessions regardless of age.
        // SwiftData #Predicate doesn't allow `?? .distantFuture` — use a coalesced
        // explicit endedAt check instead.
        let activeRaw = SessionStatus.active.rawValue
        let sessionPredicate = #Predicate<Session> { session in
            session.statusRaw != activeRaw && session.endedAt != nil && session.endedAt! < cutoffDate
        }
        let sessionCount = Persistence.fetchCount(context, FetchDescriptor<Session>(predicate: sessionPredicate))
        if sessionCount > 0 {
            do {
                try context.delete(model: Session.self, where: sessionPredicate)
                pruned += sessionCount
            } catch {
                Persistence.logger.error("retention prune failed (sessions): \(error.localizedDescription, privacy: .public)")
            }
        }

        Persistence.save(context)
        if pruned > 0 {
            Persistence.logger.info("retention pruned \(pruned, privacy: .public) rows older than \(cutoff, privacy: .public) days")
        }
        return pruned
    }
}
