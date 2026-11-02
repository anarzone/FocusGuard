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
    /// Summaries of finished days, which don't change unless events are
    /// reclassified or erased (`.activityTotalsChanged` clears them). The
    /// menu's streak fills the last 60 at launch; Reports and Apps & Sites
    /// then add these up instead of reading every event again.
    private var pastDays: [Date: DaySummary] = [:]
    /// Days kept at most, oldest dropped first (a few KB each).
    private let keptDays = 400

    init(container: ModelContainer) {
        self.container = container
    }

    func forgetPastDays() {
        pastDays = [:]
    }

    /// Summaries of finished `days`, making only the ones not kept yet, from
    /// one read of their events.
    private func pastSummaries(_ context: ModelContext, days: [Date], calendar: Calendar = .current) -> [DaySummary] {
        let missing = days.filter { pastDays[$0] == nil }
        if !missing.isEmpty {
            for summary in DaySummary.make(days: missing, context: context, calendar: calendar) {
                pastDays[summary.day] = summary
            }
            if pastDays.count > keptDays {
                for day in pastDays.keys.sorted().prefix(pastDays.count - keptDays) where !days.contains(day) {
                    pastDays[day] = nil
                }
            }
        }
        return days.compactMap { pastDays[$0] }
    }

    /// Breakdowns of finished days in `[from, before)`.
    private func pastBreakdowns(_ context: ModelContext, from: Date, before: Date,
                                calendar: Calendar = .current) -> [DailyBreakdown] {
        let days = days(context, now: before, calendar: calendar).days(from: from, to: calendar.startOfDay(for: before))
        return pastSummaries(context, days: days, calendar: calendar).map(\.dailyBreakdown)
    }

    /// Whole days for a report to add up: kept summaries for finished days,
    /// today's read fresh.
    private func days(_ context: ModelContext, now: Date, calendar: Calendar = .current) -> DaySummaries {
        DaySummaries(context: context, now: now, calendar: calendar) { self.pastSummaries(context, days: $0, calendar: calendar) }
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

    /// Apps and sites by time. Whole days up to now add up their summaries.
    func usageRows(from: Date, to: Date, limit: Int) -> [UsageRow] {
        read { context in
            // Today's summary runs to the latest event, so only a range up
            // to now can use it.
            guard abs(to.timeIntervalSinceNow) < 300,
                  let summaries = days(context, now: to).summaries(from: from, to: to) else {
                return MenuInsightsBuilder.usageRows(context: context, from: from, to: to, limit: limit)
            }
            var apps: [String: ReportBuilder.AppGroup] = [:]
            for day in summaries {
                for (key, group) in day.apps {
                    if apps[key] == nil { apps[key] = group } else { apps[key]?.add(group) }
                }
            }
            return MenuInsightsBuilder.usageRows(ReportBuilder.topApps(apps, limit: 40), limit: limit)
        }
    }

    /// Apps and sites with the time inside sessions split out.
    func appUsage(from: Date, to: Date, limit: Int) -> [UsageRow] {
        read { MenuInsightsBuilder.appUsage(context: $0, from: from, to: to, limit: limit) }
    }

    // MARK: - Window pages

    func todayPage(day: Date, now: Date) -> TodayPageData {
        read { context in
            TodayPageData(model: TodayModelBuilder.build(day: day, context: context, now: now),
                          hasSessions: Persistence.fetchCount(context, FetchDescriptor<Session>()) > 0,
                          streak: streak(context, now: now))
        }
    }

    /// A week or month report, added up from day summaries: finished days
    /// kept here, today's read fresh.
    func reports(period: ReportPeriod, offset: Int, now: Date, historyStart: Date?,
                 weekendsCount: Bool) -> ReportsModel {
        read { context in
            ReportsModelBuilder.build(period: period, offset: offset, context: context, now: now,
                                      historyStart: historyStart, weekendsCount: weekendsCount,
                                      summaries: days(context, now: now))
        }
    }

    // MARK: - Ask

    /// The facts behind an answer on the Ask page, added up from day
    /// summaries, plus the sessions for "how long should my sessions be".
    /// The coach's question, and ones it can't answer, don't need the
    /// store (`AskEngine`).
    func askFacts(_ question: AskQuestion, settings: AskContext, now: Date,
                  calendar: Calendar = .current, locale: Locale = .current) -> AskFacts {
        read { context in
            var builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale, context: settings)
            let summaries = days(context, now: now, calendar: calendar)
            let today = calendar.startOfDay(for: now)
            let monthStart = calendar.date(byAdding: .day, value: 1 - AskFactsBuilder.lookbackDays, to: today) ?? today
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let month = summaries.summaries(from: monthStart, to: now) ?? []
            let (narrowed, scope) = builder.narrowed(month, to: question)
            builder.scope = scope
            switch question.intent {
            case .bestHours:
                let count = sessionCount(context, from: monthStart, to: now)
                if question.weekdays.count >= 2 {
                    return builder.weekdayCompare(month, first: question.weekdays[0], second: question.weekdays[1])
                }
                if question.asksWhichDay { return builder.bestDay(month, sessionCount: count) }
                return builder.saysItCantNarrow(question, builder.bestHours(narrowed, sessionCount: count, within: question.hours, narrowed: scope != nil))
            case .pullsAway:
                return builder.saysItCantNarrow(question, builder.pullsAway(narrowed, hours: question.hours,
                                                                            sessionCount: sessionCount(context, from: monthStart, to: now),
                                                                            phrase: scope?.phrase))
            case .weekCompare:
                let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
                let sameEnd = min(weekStart, lastStart.addingTimeInterval(now.timeIntervalSince(weekStart)))
                return builder.weekCompare(thisWeek: summaries.breakdown(from: weekStart, to: now),
                                           sameDaysLast: summaries.breakdown(from: lastStart, to: sameEnd),
                                           lastWeek: summaries.breakdown(from: lastStart, to: weekStart),
                                           sessionsThisWeek: sessionCount(context, from: weekStart, to: now),
                                           sessionsLastWeek: sessionCount(context, from: lastStart, to: weekStart))
            case .driftDay:
                // Finished days only: today's part-day would look light.
                let from = calendar.date(byAdding: .day, value: -AskFactsBuilder.lookbackDays, to: today) ?? today
                return builder.driftDay(summaries.summaries(from: from, to: today) ?? [],
                                        sessionCount: sessionCount(context, from: from, to: today))
            case .sessionLength:
                let sessions = builder.narrowed(askSessions(context, from: monthStart, to: now), to: question)
                return builder.saysItCantNarrow(question, builder.sessionLength(sessions, named: question.minutes))
            case .appTime:
                let from = min(monthStart, calendar.date(byAdding: .weekOfYear, value: -3, to: weekStart) ?? monthStart)
                return builder.appTime(summaries.summaries(from: from, to: now) ?? [], question: question.text,
                                       period: question.period)
            case .coachExperiment, .unknown:
                return builder.cantAnswer(suggestion: nil)
            }
        }
    }

    private func sessionCount(_ context: ModelContext, from: Date, to: Date) -> Int {
        Persistence.fetchCount(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= from && $0.startedAt < to }
        ))
    }

    /// Finished sessions started in `[from, to)`, with their focus and
    /// drift, from one read of the events inside sessions (as Reports does).
    private func askSessions(_ context: ModelContext, from: Date, to: Date) -> [AskSession] {
        let finished = Persistence.fetch(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= from && $0.startedAt < to && $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt)]
        ))
        var tallies: [PersistentIdentifier: ClassificationTally] = [:]
        for event in ReportsModelBuilder.sessionEvents(around: finished, from: from, to: to, context: context) {
            guard let id = event.session?.persistentModelID else { continue }
            tallies[id, default: ClassificationTally()].add(event.duration, event.classification ?? .neutral)
        }
        return finished.compactMap { session in
            guard let end = session.endedAt else { return nil }
            let running = max(0, end.timeIntervalSince(session.startedAt) - session.pausedSeconds)
            let tally = tallies[session.persistentModelID] ?? ClassificationTally()
            return AskSession(start: session.startedAt, minutes: Int(running / 60), focus: tally.focus, drift: tally.distraction)
        }
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
