import Foundation
import SwiftData

/// The menu's numbers (today's focus, the day strip, the streak, the best
/// run, Insights, apps by time), computed off the main thread.
///
/// Each call reads through its own fresh `ModelContext` on this actor, so
/// SwiftData's per-object work (hundreds of milliseconds for a week of
/// events) never runs on the main thread, where it froze pane animations
/// and the 1 s tick. Results are plain values. A background context sees
/// what the main context has saved; the tracker saves every few seconds.
actor StatsStore {
    private let container: ModelContainer
    /// Totals of finished days, which don't change unless events are
    /// reclassified or erased (`.activityTotalsChanged` clears them). Saves
    /// re-reading a week of events (~200 ms) every few seconds.
    private var pastDays: [Date: DailyBreakdown] = [:]

    init(container: ModelContainer) {
        self.container = container
    }

    func forgetPastDays() {
        pastDays = [:]
    }

    /// Breakdowns of finished days in `[from, before)`, computing only the
    /// ones not kept yet.
    private func pastBreakdowns(_ context: ModelContext, from: Date, before: Date,
                                calendar: Calendar = .current) -> [DailyBreakdown] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: before)
        while cursor < end {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }
        let missing = days.filter { pastDays[$0] == nil }
        if let first = missing.first, let last = missing.last {
            let through = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)
            for day in ReportBuilder(context: context).dailyBreakdowns(from: first, to: through, calendar: calendar) {
                pastDays[day.date] = day
            }
            // Keep a couple of months; older days aren't asked for.
            let horizon = calendar.date(byAdding: .day, value: -70, to: end) ?? end
            pastDays = pastDays.filter { $0.key >= horizon }
        }
        return days.compactMap { pastDays[$0] }
    }

    private func streak(_ context: ModelContext, now: Date) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -StreakCalculator.lookbackDays, to: today) ?? today
        let totals = Dictionary(uniqueKeysWithValues: pastBreakdowns(context, from: from, before: today).map { ($0.date, $0.focus) })
        return StreakCalculator.streak(focusByDay: totals, now: now, calendar: calendar)
    }

    private func read<T>(_ body: (ModelContext) -> T) -> T {
        body(ModelContext(container))
    }

    func menuStats(now: Date, includeStreak: Bool) -> MenuStats.Update {
        read { context in
            let dayStart = Calendar.current.startOfDay(for: now)
            let descriptor = FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { $0.endedAt >= dayStart },
                sortBy: [SortDescriptor(\.startedAt)]
            )
            let events = Persistence.fetch(context, descriptor)
            var focus: TimeInterval = 0, neutral: TimeInterval = 0, distraction: TimeInterval = 0
            var sessionEvents: [ActivityEvent] = []
            for event in events {
                let duration = max(0, event.endedAt.timeIntervalSince(max(event.startedAt, dayStart)))
                switch event.classification ?? .neutral {
                case .focus:       focus += duration
                case .neutral:     neutral += duration
                case .distraction: distraction += duration
                }
                if event.session != nil { sessionEvents.append(event) }
            }
            return MenuStats.Update(
                today: BreakdownSnapshot(focus: focus, neutral: neutral, distraction: distraction),
                spans: MenuInsightsBuilder.mergedSpans(events, from: dayStart),
                bestZone: FocusRuns.compute(FocusRuns.spans(from: sessionEvents), now: now).longest,
                streak: includeStreak ? streak(context, now: now) : nil
            )
        }
    }

    func today(now: Date) -> TodayInsights {
        read { context in
            let dayStart = Calendar.current.startOfDay(for: now)
            let priorStart = Calendar.current.date(byAdding: .day, value: -7, to: dayStart) ?? dayStart
            let prior = pastBreakdowns(context, from: priorStart, before: dayStart)
            return MenuInsightsBuilder.day(now, context: context, now: now, prior: prior)
        }
    }

    func week(streak: Int, now: Date) -> WeekInsights {
        read { MenuInsightsBuilder.week(context: $0, streak: streak, now: now) }
    }

    /// An earlier week, whole, or this one so far.
    func week(streak: Int, containing date: Date, now: Date) -> WeekInsights {
        read { MenuInsightsBuilder.week(context: $0, streak: streak, containing: date, now: now) }
    }

    func usageRows(from: Date, to: Date, limit: Int) -> [UsageRow] {
        read { MenuInsightsBuilder.usageRows(context: $0, from: from, to: to, limit: limit) }
    }

    /// Apps and sites with the time inside sessions split out.
    func appUsage(from: Date, to: Date, limit: Int) -> [UsageRow] {
        read { MenuInsightsBuilder.appUsage(context: $0, from: from, to: to, limit: limit) }
    }
}

/// What the menu shows from the store, kept on `AppState` and refreshed in
/// the background, so the menu only ever reads it.
struct MenuStats: Equatable {
    var today = BreakdownSnapshot(focus: 0, neutral: 0, distraction: 0)
    var spans: [DaySpan] = []
    /// Longest unbroken focus run in today's sessions.
    var bestZone: TimeInterval = 0
    var streak = 0

    struct Update: Equatable {
        let today: BreakdownSnapshot
        let spans: [DaySpan]
        let bestZone: TimeInterval
        let streak: Int?
    }
}

extension Notification.Name {
    /// Past events were reclassified or erased, so per-day totals kept
    /// anywhere are out of date.
    static let activityTotalsChanged = Notification.Name("FocusGuard.activityTotalsChanged")
}
