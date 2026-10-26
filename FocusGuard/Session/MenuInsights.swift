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
    /// Of `seconds`, the time inside sessions.
    var inSession: TimeInterval = 0

    var isSite: Bool { host != nil }
    var outsideSession: TimeInterval { max(0, seconds - inSession) }
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
    /// The session's focus rate, 0...1 (see `FocusRate`).
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
    /// The day split into time inside sessions and between them.
    var inSessions = BreakdownSnapshot.zero
    var betweenSessions = BreakdownSnapshot.zero
    /// One plain sentence about the day, when there's something to say.
    var takeaway: String?

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
    /// The week's first day; earlier weeks can be shown too.
    var weekStart: Date = .distantPast
    /// The best day's focus rate, 0...1.
    var bestDayRate: Double?
    /// One plain sentence about the week, when there's something to say.
    var takeaway: String?

    static let empty = WeekInsights(days: [], todayIndex: 0, focused: 0, focusedLastWeek: 0,
                                    focusRate: 0, bestDay: nil, streak: 0, topDistractions: [])
}

extension BreakdownSnapshot {
    static let zero = BreakdownSnapshot(focus: 0, neutral: 0, distraction: 0)
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
            .filter { $0.focus + $0.distraction > 60 }
        let average = prior.isEmpty ? nil : prior.map(\.focusRate).reduce(0, +) / Double(prior.count)

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

        let split = split(events, from: dayStart, to: until)
        let goalProgress = FocusGoal.progress(focusSecondsToday: breakdown.focus)
        return TodayInsights(
            focused: breakdown.focus,
            goalProgress: goalProgress,
            focusRate: breakdown.focusRate,
            averageFocusRate: average,
            sessions: sessions,
            window: DateInterval(start: windowStart, end: max(windowEnd, windowStart.addingTimeInterval(3600))),
            activity: activity,
            sessionSpans: sessions.map { DateInterval(start: $0.start, end: max($0.start, $0.end ?? until)) },
            topApps: usageRows(context: context, from: dayStart, to: until, limit: 5),
            inSessions: split.inSessions,
            betweenSessions: split.between,
            takeaway: todayTakeaway(focused: breakdown.focus, goalProgress: goalProgress,
                                    inSessions: split.inSessions, between: split.between)
        )
    }

    /// Time inside sessions and between them, clipped to the range.
    static func split(_ events: [ActivityEvent], from: Date, to: Date)
        -> (inSessions: BreakdownSnapshot, between: BreakdownSnapshot) {
        var inside = ClassificationTally(), between = ClassificationTally()
        for event in events {
            let seconds = max(0, min(event.endedAt, to).timeIntervalSince(max(event.startedAt, from)))
            guard seconds > 0 else { continue }
            if event.session != nil {
                inside.add(seconds, event.classification ?? .neutral)
            } else {
                between.add(seconds, event.classification ?? .neutral)
            }
        }
        func snapshot(_ t: ClassificationTally) -> BreakdownSnapshot {
            BreakdownSnapshot(focus: t.focus, neutral: t.neutral, distraction: t.distraction)
        }
        return (snapshot(inside), snapshot(between))
    }

    /// The one thing worth saying about today, in a sentence.
    static func todayTakeaway(focused: TimeInterval, goalProgress: Double,
                              inSessions: BreakdownSnapshot, between: BreakdownSnapshot) -> String? {
        let drift = inSessions.distraction + between.distraction
        if drift >= 10 * 60 {
            let share = between.distraction / drift
            if share >= 0.6 {
                return "Most of today's drift came between sessions: \(formatDuration(between.distraction)) of \(formatDuration(drift))."
            }
            if share <= 0.4 {
                return "Most of today's drift came in sessions: \(formatDuration(inSessions.distraction)) of \(formatDuration(drift))."
            }
        }
        let rated: (BreakdownSnapshot) -> Bool = { $0.focus + $0.distraction >= 10 * 60 }
        if rated(inSessions), rated(between), inSessions.focusRate - between.focusRate >= 0.15 {
            return "Sessions help: a \(FocusRate.percent(focused: inSessions.focus, drifted: inSessions.distraction))% "
                + "focus rate in them, \(FocusRate.percent(focused: between.focus, drifted: between.distraction))% between."
        }
        if goalProgress >= 1 {
            return "Goal met: \(formatDuration(focused)) focused today."
        }
        if focused >= 60 {
            return "\(formatDuration(focused)) focused so far, \(Int((goalProgress * 100).rounded()))% of your goal."
        }
        return nil
    }

    static func week(context: ModelContext, streak: Int, now: Date = .now, calendar: Calendar = .current) -> WeekInsights {
        week(context: context, streak: streak, containing: now, now: now, calendar: calendar)
    }

    /// The week holding `date`: this week up to now, or a whole earlier week.
    static func week(context: ModelContext, streak: Int, containing date: Date, now: Date = .now,
                     calendar: Calendar = .current) -> WeekInsights {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: min(date, now)) else { return .empty }
        let until = min(now, week.end)
        let reports = ReportBuilder(context: context)
        let days = reports.dailyBreakdowns(from: week.start, to: week.end, calendar: calendar)
        let todayIndex = calendar.dateComponents([.day], from: week.start,
                                                 to: calendar.startOfDay(for: until.addingTimeInterval(-1))).day ?? 0

        let soFar = reports.breakdown(from: week.start, to: until)
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: week.start) ?? week.start
        let lastWeek = reports.breakdown(from: lastWeekStart, to: lastWeekStart.addingTimeInterval(until.timeIntervalSince(week.start)))

        let best = days.prefix(todayIndex + 1).filter { $0.focus > 0 }.max { $0.focus < $1.focus }

        let distractions = usageRows(context: context, from: week.start, to: until, limit: 40)
            .filter { $0.classification == .distraction }
            .prefix(3)

        let weekStart = week.start
        let driftEvents = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= weekStart && $0.startedAt < until }
        )).filter { $0.classification == .distraction }
        var driftByHour = [TimeInterval](repeating: 0, count: 24)
        for event in driftEvents {
            let seconds = max(0, min(event.endedAt, until).timeIntervalSince(max(event.startedAt, week.start)))
            driftByHour[calendar.component(.hour, from: event.startedAt)] += seconds
        }
        let activeDays = days.prefix(todayIndex + 1).filter { $0.focus > 0 }.count

        return WeekInsights(
            days: days,
            todayIndex: max(0, min(days.count - 1, todayIndex)),
            focused: soFar.focus,
            focusedLastWeek: lastWeek.focus,
            focusRate: soFar.focusRate,
            bestDay: best?.date,
            streak: streak,
            topDistractions: Array(distractions),
            weekStart: week.start,
            bestDayRate: best?.focusRate,
            takeaway: weekTakeaway(bestDay: activeDays >= 2 ? best?.date : nil, driftByHour: driftByHour,
                                   topDistraction: distractions.first, calendar: calendar)
        )
    }

    /// The best day, when the drift lands, and what most of it is.
    static func weekTakeaway(bestDay: Date?, driftByHour: [TimeInterval], topDistraction: UsageRow?,
                             calendar: Calendar = .current) -> String? {
        var parts: [String] = []
        if let bestDay {
            parts.append("\(bestDay.formatted(.dateTime.weekday(.wide))) was your best day.")
        }
        let drift = driftByHour.reduce(0, +)
        guard drift >= 10 * 60 else { return parts.isEmpty ? nil : parts.joined(separator: " ") }

        let lateHour = [17, 15, 12].first { hour in driftByHour[hour...].reduce(0, +) / drift >= 0.6 }
        let share = topDistraction.map { $0.seconds / drift } ?? 0
        let portion: String? = switch share {
        case 0.9...:      "nearly all"
        case 0.6..<0.9:   "most"
        case 0.45..<0.6:  "half"
        case 0.3..<0.45:  "a third"
        default:          nil
        }
        let at = lateHour.flatMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: .now) }
            .map { $0.formatted(date: .omitted, time: .shortened) }
        switch (at, portion, topDistraction?.name) {
        case let (at?, portion?, name?):
            parts.append("Most drift lands after \(at), and \(name) is \(portion) of it.")
        case let (at?, _, _):
            parts.append("Most drift lands after \(at).")
        case let (nil, portion?, name?):
            parts.append("\(name) is \(portion) of your drift.")
        default:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Apps and sites used in a stretch, most time first, with the time
    /// inside sessions split out. Browsers are split into their sites.
    static func appUsage(context: ModelContext, from: Date, to: Date, limit: Int) -> [UsageRow] {
        struct Entry {
            var name: String
            var bundleId: String
            var host: String?
            var tally = ClassificationTally()
            var inSession: TimeInterval = 0
        }
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to }
        ))
        var entries: [String: Entry] = [:]
        for event in events {
            let seconds = max(0, min(event.endedAt, to).timeIntervalSince(max(event.startedAt, from)))
            guard seconds > 0 else { continue }
            var host = BrowserTabReader.isBrowser(bundleIdentifier: event.bundleIdentifier)
                ? event.url.flatMap { URL(string: $0)?.host?.lowercased() } : nil
            if let h = host, h.hasPrefix("www.") { host = String(h.dropFirst(4)) }
            let key = host ?? event.bundleIdentifier
            var entry = entries[key] ?? Entry(name: host ?? event.appName, bundleId: event.bundleIdentifier, host: host)
            entry.tally.add(seconds, event.classification ?? .neutral)
            if event.session != nil { entry.inSession += seconds }
            entries[key] = entry
        }
        return entries
            .map { key, e in
                UsageRow(id: key, name: e.name, bundleId: e.bundleId, host: e.host, seconds: e.tally.total,
                         classification: e.tally.dominant, inSession: e.inSession)
            }
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit)
            .map { $0 }
    }

    /// Apps and browser sites by time. Browsers are split into their sites so
    /// "Chrome" doesn't hide youtube.com.
    static func usageRows(context: ModelContext, from: Date, to: Date, limit: Int) -> [UsageRow] {
        usageRows(ReportBuilder(context: context).topApps(from: from, to: to, limit: 40), limit: limit)
    }

    /// The same from events already read; a wider read works too.
    static func usageRows(events: [ActivityEvent], from: Date, to: Date, limit: Int) -> [UsageRow] {
        usageRows(ReportBuilder.topApps(events, from: from, to: to, limit: 40), limit: limit)
    }

    private static func usageRows(_ apps: [AppUsageEntry], limit: Int) -> [UsageRow] {
        var rows: [UsageRow] = []
        for app in apps {
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
        var focus: TimeInterval = 0, drift: TimeInterval = 0
        for event in session.events {
            let seconds = max(0, event.duration) + 1
            switch event.classification {
            case .focus: focus += seconds
            case .distraction: drift += seconds
            default: break
            }
        }
        let end = session.endedAt
        let running = max(0, (end ?? now).timeIntervalSince(session.startedAt) - session.pausedSeconds)
        return SessionSummary(
            id: session.id,
            modelID: session.persistentModelID,
            label: session.displayName,
            start: session.startedAt,
            end: end,
            minutes: Int(running / 60),
            plannedMinutes: session.plannedDurationMinutes,
            focusShare: FocusRate.of(focused: focus, drifted: drift)
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

    /// Not sorted yet: no rule, built-in or the user's, says what it is.
    func isUnsorted(_ row: UsageRow) -> Bool {
        guard row.bundleId != ActivityTracker.selfBundleId else { return false }
        if let host = row.host {
            return classifier.matchingRule(bundleId: "", windowTitle: nil, url: "https://\(host)/") == nil
        }
        return classifier.matchingRule(bundleId: row.bundleId, windowTitle: nil, url: nil) == nil
    }

    /// Undoes a sort: removes the user's rule for the app or site and puts
    /// its past activity back to what the remaining rules say.
    func clearCategory(for row: UsageRow) {
        let pattern = row.host ?? row.bundleId
        let kind: RuleMatchKind = row.host == nil ? .bundleId : .host
        guard let rule = userRules().first(where: { $0.pattern == pattern && $0.matchKind == kind }),
              !(isStrictLocked && rule.classification == .distraction) else { return }
        let context = container.mainContext
        context.delete(rule)
        Persistence.save(context)
        classifier.invalidate()

        let events: [ActivityEvent]
        if let host = row.host {
            events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.url != nil }))
                .filter { $0.url.flatMap { URL(string: $0)?.host?.lowercased() }.map { Classifier.host($0, matches: host) } == true }
        } else {
            events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { $0.bundleIdentifier == pattern }
            ))
        }
        for event in events {
            event.classification = classifier.classify(bundleId: event.bundleIdentifier, windowTitle: event.windowTitle, url: event.url)
        }
        Persistence.save(context)
        classifier.invalidate()
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

    /// Deletes a rule, unless Strict's lock keeps a blocked one until the session ends.
    func deleteRule(_ rule: AppRule) {
        guard !(isStrictLocked && rule.classification == .distraction) else { return }
        let context = container.mainContext
        context.delete(rule)
        Persistence.save(context)
        classifier.invalidate()
    }
}
