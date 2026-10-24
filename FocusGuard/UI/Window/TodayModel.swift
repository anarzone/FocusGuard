import Foundation
import SwiftData

/// A session on the Today page: its row, its block on the day strip and
/// the tooltip over that block.
struct TodaySession: Identifiable, Equatable {
    let id: UUID
    let modelID: PersistentIdentifier
    let name: String
    let start: Date
    /// Nil while it runs.
    let end: Date?
    let minutes: Int
    let plannedMinutes: Int?
    /// Focus rate, 0...1: focus ÷ (focus + drift).
    let rate: Double
    /// Focus, drift and other in time order, merged into runs, for the
    /// tooltip's bar.
    let runs: [Run]
    /// Where the time went, most first.
    let apps: [(name: String, seconds: TimeInterval)]
    /// "drifted early, finished strong".
    let shape: String
    /// Its longest unbroken focus run.
    let bestRun: TimeInterval

    var isLive: Bool { end == nil }

    struct Run: Equatable {
        let kind: SessionTimeline.Kind
        let seconds: TimeInterval
    }

    static func == (a: TodaySession, b: TodaySession) -> Bool {
        a.id == b.id && a.name == b.name && a.end == b.end && a.minutes == b.minutes && a.rate == b.rate
    }
}

/// Everything the Today page shows for one day.
struct TodayModel {
    let day: Date
    let focused: TimeInterval
    /// Focus inside sessions; the rest of `focused` was between them.
    let focusedInSessions: TimeInterval
    let drifted: TimeInterval
    let goal: TimeInterval
    /// Longest unbroken focus run inside sessions, and the session it was in.
    let bestZone: TimeInterval
    let bestZoneSession: String?
    let sessions: [TodaySession]
    let activity: [DaySpan]
    /// The day strip's span, whole hours.
    let window: DateInterval
    let topApps: [UsageRow]
    /// When the first activity of the day was recorded.
    let trackingStarted: Date?

    var focusedBetweenSessions: TimeInterval { max(0, focused - focusedInSessions) }
    var focusRate: Double { FocusRate.of(focused: focused, drifted: drifted) }
    /// Anything to judge the rate on.
    var hasRate: Bool { focused + drifted >= 60 }
    var goalProgress: Double { goal > 0 ? min(1, focused / goal) : 0 }
    var inSessionProgress: Double { goal > 0 ? min(goalProgress, focusedInSessions / goal) : 0 }

    static func empty(day: Date = .now) -> TodayModel {
        TodayModel(day: day, focused: 0, focusedInSessions: 0, drifted: 0, goal: FocusGoal.dailySeconds,
                   bestZone: 0, bestZoneSession: nil, sessions: [], activity: [],
                   window: DateInterval(start: day, duration: 3600), topApps: [], trackingStarted: nil)
    }
}

/// Builds the Today page's model from the store. Cheap enough to run every
/// few seconds while the page is open.
@MainActor
enum TodayModelBuilder {
    static func build(day date: Date, context: ModelContext, now: Date = .now,
                      calendar: Calendar = .current) -> TodayModel {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let until = min(now, dayEnd)

        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= dayStart && $0.startedAt < dayEnd },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let events = Persistence.fetch(context, descriptor)

        var focused: TimeInterval = 0, inSessions: TimeInterval = 0, drifted: TimeInterval = 0
        for event in events {
            let seconds = max(0, min(event.endedAt, until).timeIntervalSince(max(event.startedAt, dayStart)))
            switch event.classification {
            case .focus:
                focused += seconds
                if event.session != nil { inSessions += seconds }
            case .distraction:
                drifted += seconds
            default:
                break
            }
        }

        var sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= dayStart && $0.startedAt < dayEnd },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        sessionDescriptor.fetchLimit = 50
        let sessionModels = Persistence.fetch(context, sessionDescriptor)

        let sessions = sessionModels.map { item(for: $0, now: now) }
        let best = sessions.max { $0.bestRun < $1.bestRun }

        let activity = MenuInsightsBuilder.mergedSpans(events, from: dayStart).map {
            DaySpan(start: $0.start, end: min($0.end, dayEnd), kind: $0.kind)
        }

        return TodayModel(
            day: dayStart,
            focused: focused,
            focusedInSessions: inSessions,
            drifted: drifted,
            goal: FocusGoal.dailySeconds,
            bestZone: best?.bestRun ?? 0,
            bestZoneSession: (best?.bestRun ?? 0) >= 60 ? best?.name : nil,
            sessions: sessions,
            activity: activity,
            window: stripWindow(activity: activity, dayStart: dayStart, dayEnd: dayEnd, now: now, calendar: calendar),
            topApps: MenuInsightsBuilder.usageRows(context: context, from: dayStart, to: until, limit: 6),
            trackingStarted: events.first.map { max($0.startedAt, dayStart) }
        )
    }

    static func item(for session: Session, now: Date) -> TodaySession {
        let segments = SessionTimeline.segments(from: session.events)
        var focus: TimeInterval = 0, drift: TimeInterval = 0
        var apps: [String: TimeInterval] = [:]
        for event in session.events {
            let seconds = max(0, event.duration) + 1
            switch event.classification {
            case .focus: focus += seconds
            case .distraction: drift += seconds
            default: break
            }
            let host = event.url.flatMap { URL(string: $0)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            apps[host ?? event.appName, default: 0] += seconds
        }
        let end = session.endedAt
        let running = max(0, (end ?? now).timeIntervalSince(session.startedAt) - session.pausedSeconds)
        return TodaySession(
            id: session.id,
            modelID: session.persistentModelID,
            name: session.displayName,
            start: session.startedAt,
            end: end,
            minutes: Int(running / 60),
            plannedMinutes: session.plannedDurationMinutes,
            rate: FocusRate.of(focused: focus, drifted: drift),
            runs: runs(of: segments),
            apps: apps.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) },
            shape: shape(of: SessionNamer.pattern(of: segments)),
            bestRun: FocusRuns.compute(FocusRuns.spans(from: session.events), now: now).longest
        )
    }

    /// Adjacent segments of one kind merged into a run; runs under 2% of
    /// the session fold into their neighbour so the bar stays readable.
    static func runs(of segments: [SessionTimeline.Segment]) -> [TodaySession.Run] {
        let total = segments.reduce(0) { $0 + max(0, $1.seconds) }
        guard total > 0 else { return [] }
        var out: [TodaySession.Run] = []
        for segment in segments {
            let kind = SessionTimeline.Kind(segment.classification)
            let seconds = max(0, segment.seconds)
            if let last = out.last, last.kind == kind || seconds < total * 0.02 {
                out[out.count - 1] = TodaySession.Run(kind: last.kind, seconds: last.seconds + seconds)
            } else {
                out.append(TodaySession.Run(kind: kind, seconds: seconds))
            }
        }
        return out
    }

    /// How it went, in a few words, for the strip's tooltip.
    static func shape(of pattern: SessionNamer.Pattern) -> String {
        switch pattern {
        case .lockedIn:  return "focused the whole way"
        case .slowStart: return "slow to start, then steady"
        case .comeback:  return "drifted early, finished strong"
        case .fading:    return "strong start, faded at the end"
        case .steady:    return "steady, with a few drifts"
        case .bumpy:     return "on and off"
        case .wandering: return "mostly drifting"
        case .quiet:     return "little to go on"
        }
    }

    /// 08:00–20:00, stretched to cover whatever happened and an hour past now.
    static func stripWindow(activity: [DaySpan], dayStart: Date, dayEnd: Date, now: Date,
                            calendar: Calendar) -> DateInterval {
        let firstHour = activity.first.map { calendar.component(.hour, from: $0.start) } ?? 8
        var lastHour = activity.last.map { calendar.component(.hour, from: $0.end.addingTimeInterval(-1)) + 1 } ?? 20
        if now >= dayStart && now < dayEnd {
            lastHour = max(lastHour, calendar.component(.hour, from: now) + 1)
        }
        let startHour = min(8, firstHour)
        let endHour = min(24, max(20, lastHour))
        let start = calendar.date(byAdding: .hour, value: startHour, to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: endHour, to: dayStart) ?? dayEnd
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(3600)))
    }
}

// MARK: - Words

/// The line under the page title: "37 minutes to your 4-hour goal. This
/// session can cover most of it."
enum TodayHeadline {
    struct Context {
        var focused: TimeInterval
        var goal: TimeInterval
        var isToday: Bool
        var isFirstDay = false
        /// Seconds left in the running timed session; nil when none runs
        /// or it's open-ended.
        var sessionLeft: TimeInterval?
        var inSession = false
        var onBreak = false
        /// The length "Start" would use, in minutes.
        var nextLength: Int
        var hasActivity = true
    }

    static func make(_ c: Context) -> (lead: String, rest: String) {
        if c.isFirstDay { return ("Day one.", "Start a session and this page fills in as you work.") }
        if !c.isToday {
            guard c.hasActivity else { return ("Nothing was tracked this day.", "") }
            if c.focused >= c.goal { return ("Goal met: \(WindowFormat.hm(c.focused)) focused.", "") }
            return ("\(WindowFormat.hm(c.focused)) focused.", "\(WindowFormat.hm(c.goal - c.focused)) short of the goal.")
        }
        if c.focused >= c.goal {
            return ("Goal met: \(WindowFormat.hm(c.focused)) focused today.", "Anything more is a bonus.")
        }
        let remaining = c.goal - c.focused
        let lead = "\(gap(remaining)) to your \(goalName(c.goal))."
        if c.inSession {
            guard let left = c.sessionLeft else { return (lead, "This session counts as you go.") }
            if left >= remaining { return (lead, "This session can cover it.") }
            if left >= remaining * 0.5 { return (lead, "This session can cover most of it.") }
            return (lead, "This session gets you closer.")
        }
        if c.onBreak { return (lead, "Back to it after the break.") }
        let next = TimeInterval(max(1, c.nextLength) * 60)
        if next >= remaining { return (lead, "One \(c.nextLength)-minute session now gets you there.") }
        if next >= remaining * 0.75 { return (lead, "One \(c.nextLength)-minute session now gets you nearly there.") }
        let count = Int((remaining / next).rounded(.up))
        return (lead, "About \(count) sessions of \(c.nextLength) minutes would do it.")
    }

    /// "37 minutes", "An hour", "2h 10m".
    static func gap(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 55 { return WindowFormat.count(minutes, "minute") }
        if minutes <= 65 { return "An hour" }
        return WindowFormat.hm(TimeInterval(minutes * 60))
    }

    /// "4-hour goal", "3h 30m goal".
    static func goalName(_ goal: TimeInterval) -> String {
        let minutes = Int(goal / 60)
        if minutes % 60 == 0 { return "\(minutes / 60)-hour goal" }
        return "\(WindowFormat.hm(goal)) goal"
    }
}

/// "goal met Monday to Thursday": the days a streak covers.
enum StreakWords {
    /// The streak's days, newest first, walking back from yesterday the way
    /// `StreakCalculator` does (weekends skipped unless they count).
    static func days(count: Int, now: Date, weekendsCount: Bool, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        var out: [Date] = []
        var cursor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        var guardDays = 0
        while out.count < count, guardDays < 400 {
            let weekday = calendar.component(.weekday, from: cursor)
            let weekend = weekday == 1 || weekday == 7
            if weekendsCount || !weekend { out.append(cursor) }
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            guardDays += 1
        }
        return out
    }

    static func detail(count: Int, now: Date, weekendsCount: Bool, calendar: Calendar = .current) -> String {
        let days = days(count: count, now: now, weekendsCount: weekendsCount, calendar: calendar)
        guard let last = days.first, let first = days.last else { return "meet today's goal to start one" }
        let weekday = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                       timeZone: calendar.timeZone).weekday(.wide)
        if days.count == 1 {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return "goal met \(calendar.isDate(last, inSameDayAs: yesterday) ? "yesterday" : last.formatted(weekday))"
        }
        let spanDays = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        if spanDays < 7 {
            return "goal met \(first.formatted(weekday)) to \(last.formatted(weekday))"
        }
        let date = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                    timeZone: calendar.timeZone).day().month(.wide)
        return "goal met since \(first.formatted(date))"
    }
}
