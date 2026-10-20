import Foundation
import SwiftData

/// An app, or a site inside a browser, with time and category — one row in
/// the menu's Insights and Apps & sites panes.
struct UsageRow: Identifiable, Equatable {
    /// Bundle id for apps, host for sites.
    let id: String
    let name: String
    let bundleId: String
    /// Set for sites; reclassifying a site writes a host rule.
    let host: String?
    let seconds: TimeInterval
    let classification: Classification

    var isSite: Bool { host != nil }
}

/// A session from today, for the Insights list.
struct SessionSummary: Identifiable {
    let id: UUID
    /// To find the session again on the main context (rename, delete); the
    /// summary itself may come from a background context.
    let modelID: PersistentIdentifier
    let label: String
    let start: Date
    let end: Date?
    let minutes: Int
    let plannedMinutes: Int?
    /// Focused share of tracked time, 0...1.
    let focusShare: Double

    var isRunning: Bool { end == nil }
}

/// One stretch of the day timeline.
struct DaySpan: Equatable {
    let start: Date
    let end: Date
    let kind: SessionTimeline.Kind
}

struct TodayInsights {
    let focused: TimeInterval
    let goalProgress: Double
    let focusRate: Double
    /// Average focus rate over the previous seven days, if there was any activity.
    let averageFocusRate: Double?
    let sessions: [SessionSummary]
    let window: DateInterval
    let activity: [DaySpan]
    let sessionSpans: [DateInterval]
    let topApps: [UsageRow]

    static let empty = TodayInsights(
        focused: 0, goalProgress: 0, focusRate: 0, averageFocusRate: nil, sessions: [],
        window: DateInterval(start: .now, duration: 1), activity: [], sessionSpans: [], topApps: []
    )
}

struct WeekInsights {
    /// One entry per day of the current week, in order.
    let days: [DailyBreakdown]
    /// Index of today in `days`; later days haven't happened yet.
    let todayIndex: Int
    let focused: TimeInterval
    /// Focus over the same stretch of last week, for a fair comparison.
    let focusedLastWeek: TimeInterval
    let focusRate: Double
    let bestDay: Date?
    let streak: Int
    let topDistractions: [UsageRow]

    static let empty = WeekInsights(days: [], todayIndex: 0, focused: 0, focusedLastWeek: 0,
                                    focusRate: 0, bestDay: nil, streak: 0, topDistractions: [])
}

/// Builds the menu panes' data from the store. Cheap enough to run every few
/// seconds while a pane is open.
/// Plain reads of a context, so `StatsStore` can run them off the main thread.
enum MenuInsightsBuilder {
    static func today(context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> TodayInsights {
        day(now, context: context, now: now, calendar: calendar)
    }

    /// Any day's insights; today's stop at `now`.
    /// `prior`: the seven days before, if the caller has them (StatsStore
    /// keeps finished days), so they aren't re-read.
    static func day(_ date: Date, context: ModelContext, now: Date = .now, calendar: Calendar = .current,
                    prior knownPrior: [DailyBreakdown]? = nil) -> TodayInsights {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let until = min(now, dayEnd)
        let reports = ReportBuilder(context: context)
        let breakdown = reports.breakdown(from: dayStart, to: until)

        let priorStart = calendar.date(byAdding: .day, value: -7, to: dayStart) ?? dayStart
        let prior = (knownPrior ?? reports.dailyBreakdowns(from: priorStart, to: dayStart, calendar: calendar))
            .filter { $0.total > 60 }
        let average = prior.isEmpty ? nil : prior.map { $0.focus / $0.total }.reduce(0, +) / Double(prior.count)

        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= dayStart && $0.startedAt < dayEnd },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let events = Persistence.fetch(context, descriptor)
        let activity = mergedSpans(events, from: dayStart).map {
            DaySpan(start: $0.start, end: min($0.end, dayEnd), kind: $0.kind)
        }

        var sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= dayStart && $0.startedAt < dayEnd },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        sessionDescriptor.fetchLimit = 50
        let sessions = Persistence.fetch(context, sessionDescriptor).map { summary(for: $0, now: now) }

        // 8 AM–6 PM, stretched to cover whatever actually happened.
        let firstHour = activity.first.map { calendar.component(.hour, from: $0.start) } ?? 8
        let startHour = min(8, firstHour)
        let lastHour = until >= dayEnd
            ? (activity.last.map { calendar.component(.hour, from: $0.end.addingTimeInterval(-1)) } ?? 17) + 1
            : calendar.component(.hour, from: now) + 1
        let endHour = max(18, min(24, lastHour))
        let windowStart = calendar.date(byAdding: .hour, value: startHour, to: dayStart) ?? dayStart
        let windowEnd = calendar.date(byAdding: .hour, value: endHour, to: dayStart) ?? now

        return TodayInsights(
            focused: breakdown.focus,
            goalProgress: FocusGoal.progress(focusSecondsToday: breakdown.focus),
            focusRate: breakdown.focusPercent,
            averageFocusRate: average,
            sessions: sessions,
            window: DateInterval(start: windowStart, end: max(windowEnd, windowStart.addingTimeInterval(3600))),
            activity: activity,
            sessionSpans: sessions.map { DateInterval(start: $0.start, end: max($0.start, $0.end ?? until)) },
            topApps: usageRows(context: context, from: dayStart, to: until, limit: 4)
        )
    }

    static func week(context: ModelContext, streak: Int, now: Date = .now, calendar: Calendar = .current) -> WeekInsights {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return .empty }
        let reports = ReportBuilder(context: context)
        let days = reports.dailyBreakdowns(from: week.start, to: week.end, calendar: calendar)
        let todayIndex = calendar.dateComponents([.day], from: week.start, to: calendar.startOfDay(for: now)).day ?? 0

        let soFar = reports.breakdown(from: week.start, to: now)
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: week.start) ?? week.start
        let lastWeek = reports.breakdown(from: lastWeekStart, to: lastWeekStart.addingTimeInterval(now.timeIntervalSince(week.start)))

        let best = days.prefix(todayIndex + 1).filter { $0.focus > 0 }.max { $0.focus < $1.focus }

        let distractions = usageRows(context: context, from: week.start, to: now, limit: 40)
            .filter { $0.classification == .distraction }
            .prefix(3)

        return WeekInsights(
            days: days,
            todayIndex: max(0, min(days.count - 1, todayIndex)),
            focused: soFar.focus,
            focusedLastWeek: lastWeek.focus,
            focusRate: soFar.focusPercent,
            bestDay: best?.date,
            streak: streak,
            topDistractions: Array(distractions)
        )
    }

    /// Apps and browser sites by time. Browsers are split into their sites so
    /// "Chrome" doesn't hide youtube.com.
    static func usageRows(context: ModelContext, from: Date, to: Date, limit: Int) -> [UsageRow] {
        var rows: [UsageRow] = []
        for app in ReportBuilder(context: context).topApps(from: from, to: to, limit: 40) {
            if app.tabs.isEmpty {
                rows.append(UsageRow(id: app.bundleId, name: app.name, bundleId: app.bundleId, host: nil,
                                     seconds: app.seconds, classification: app.classification))
            } else {
                for tab in app.tabs {
                    let host = tab.host.hasPrefix("www.") ? String(tab.host.dropFirst(4)) : tab.host
                    if let index = rows.firstIndex(where: { $0.host == host }) {
                        let existing = rows[index]
                        rows[index] = UsageRow(id: existing.id, name: existing.name, bundleId: existing.bundleId, host: host,
                                               seconds: existing.seconds + tab.seconds, classification: existing.classification)
                    } else {
                        rows.append(UsageRow(id: host, name: host, bundleId: app.bundleId, host: host,
                                             seconds: tab.seconds, classification: tab.classification))
                    }
                }
            }
        }
        return Array(rows.sorted { $0.seconds > $1.seconds }.prefix(limit))
    }

    static func summary(for session: Session, now: Date) -> SessionSummary {
        var focus: TimeInterval = 0, total: TimeInterval = 0
        for event in session.events {
            let seconds = max(0, event.duration) + 1
            total += seconds
            if event.classification == .focus { focus += seconds }
        }
        let end = session.endedAt
        let running = max(0, (end ?? now).timeIntervalSince(session.startedAt) - session.pausedSeconds)
        return SessionSummary(
            id: session.id,
            modelID: session.persistentModelID,
            label: session.label ?? "Focus session",
            start: session.startedAt,
            end: end,
            minutes: Int(running / 60),
            plannedMinutes: session.plannedDurationMinutes,
            focusShare: total > 0 ? focus / total : 0
        )
    }

    /// Adjacent events of the same kind merge into one span (gaps under a
    /// minute bridged) so a day draws as a few dozen shapes, not thousands.
    static func mergedSpans(_ events: [ActivityEvent], from dayStart: Date) -> [DaySpan] {
        var spans: [DaySpan] = []
        for event in events {
            let start = max(event.startedAt, dayStart)
            let end = event.endedAt.addingTimeInterval(1)
            guard end > start else { continue }
            let kind = SessionTimeline.Kind(event.classification ?? .neutral)
            if let last = spans.last, last.kind == kind, start.timeIntervalSince(last.end) < 60 {
                spans[spans.count - 1] = DaySpan(start: last.start, end: max(last.end, end), kind: kind)
            } else {
                spans.append(DaySpan(start: start, end: end, kind: kind))
            }
        }
        return spans
    }
}

// MARK: - Actions

extension AppState {
    /// Rules the user created (built-in defaults use priority 100).
    func userRules() -> [AppRule] {
        let descriptor = FetchDescriptor<AppRule>(
            predicate: #Predicate { $0.priority >= 200 },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return Persistence.fetch(container.mainContext, descriptor)
    }

    func setCategory(_ classification: Classification, for row: UsageRow) {
        if let host = row.host {
            classifier.setOverride(host: host, classification: classification)
        } else {
            classifier.setOverride(bundleId: row.bundleId, classification: classification)
        }
    }

    /// Adds a site rule from whatever the user typed: a host, or a URL.
    @discardableResult
    func addSiteRule(_ input: String, classification: Classification) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")?.host ?? trimmed
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard clean.contains("."), !clean.contains(" ") else { return false }
        classifier.setOverride(host: clean, classification: classification)
        return true
    }

    func deleteRule(_ rule: AppRule) {
        let context = container.mainContext
        context.delete(rule)
        Persistence.save(context)
        classifier.invalidate()
    }
}
