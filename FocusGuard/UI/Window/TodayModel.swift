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
    /// Anything to judge the rate on: time only in other apps shows "–", not 0%.
    var hasRate = true
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
        TodayModel(day: day, focused: 0, focusedInSessions: 0, drifted: 0, goal: FocusGoal.seconds(on: day),
                   bestZone: 0, bestZoneSession: nil, sessions: [], activity: [],
                   window: DateInterval(start: day, duration: 3600), topApps: [], trackingStarted: nil)
    }
}

/// The Today page as loaded: the day, whether any session exists yet (none
/// means the first-day page) and the streak.
struct TodayPageData {
    var model: TodayModel
    var hasSessions: Bool
    var streak: Int
}

/// Builds the Today page's model from the store. Runs on `StatsStore`, off
/// the main thread, every few seconds while the page is open.
enum TodayModelBuilder {
    static func build(day date: Date, context: ModelContext, now: Date = .now,
                      calendar: Calendar = .current) -> TodayModel {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.startOfDay(1, from: dayStart)
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

        let sessionModels = MenuInsightsBuilder.sessions(from: dayStart, to: dayEnd, context: context)

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
            goal: FocusGoal.seconds(on: dayStart, calendar: calendar),
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
            let seconds = max(0, event.duration)
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
            hasRate: focus + drift > 0,
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
        case .lockedIn:  return String(localized: "focused the whole way")
        case .slowStart: return String(localized: "slow to start, then steady")
        case .comeback:  return String(localized: "drifted early, finished strong")
        case .fading:    return String(localized: "strong start, faded at the end")
        case .steady:    return String(localized: "steady, with a few drifts")
        case .bumpy:     return String(localized: "on and off", comment: "How a session went: focus came and went")
        case .wandering: return String(localized: "mostly drifting")
        case .quiet:     return String(localized: "little to go on", comment: "How a session went: too little activity to judge it")
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
        if c.isFirstDay {
            return (String(localized: "Day one."), String(localized: "Start a session and this page fills in as you work."))
        }
        if !c.isToday {
            guard c.hasActivity else { return (String(localized: "Nothing was tracked this day."), "") }
            if c.focused >= c.goal { return (String(localized: "Goal met: \(WindowFormat.hm(c.focused)) focused."), "") }
            return (String(localized: "\(WindowFormat.hm(c.focused)) focused."),
                    String(localized: "\(WindowFormat.hm(c.goal - c.focused)) short of the goal."))
        }
        if c.focused >= c.goal {
            return (String(localized: "Goal met: \(WindowFormat.hm(c.focused)) focused today."), String(localized: "Anything more is a bonus."))
        }
        let remaining = c.goal - c.focused
        let lead = String(localized: "\(gap(remaining)) to your \(goalName(c.goal)).", comment: "37 minutes to your 4-hour goal.")
        if c.inSession {
            guard let left = c.sessionLeft else { return (lead, String(localized: "This session counts as you go.")) }
            if left >= remaining { return (lead, String(localized: "This session can cover it.")) }
            if left >= remaining * 0.5 { return (lead, String(localized: "This session can cover most of it.")) }
            return (lead, String(localized: "This session gets you closer."))
        }
        if c.onBreak { return (lead, String(localized: "Back to it after the break.")) }
        let next = TimeInterval(max(1, c.nextLength) * 60)
        if next >= remaining { return (lead, String(localized: "One \(c.nextLength)-minute session now gets you there.")) }
        if next >= remaining * 0.75 { return (lead, String(localized: "One \(c.nextLength)-minute session now gets you nearly there.")) }
        let count = Int((remaining / next).rounded(.up))
        return (lead, String(localized: "About \(count) sessions of \(c.nextLength) minutes would do it."))
    }

    /// "37 minutes", "An hour", "2h 10m".
    static func gap(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 55 { return String(localized: "\(minutes) minutes", comment: "Plural on minutes: 1 minute / 2 minutes") }
        if minutes <= 65 { return String(localized: "An hour", comment: "Starts the sentence: An hour to your 4-hour goal.") }
        return WindowFormat.hm(TimeInterval(minutes * 60))
    }

    /// "4-hour goal", "3h 30m goal".
    static func goalName(_ goal: TimeInterval) -> String {
        let minutes = Int(goal / 60)
        if minutes % 60 == 0 {
            return String(localized: "\(minutes / 60)-hour goal", comment: "Goes into: 37 minutes to your 4-hour goal.")
        }
        return String(localized: "\(WindowFormat.hm(goal)) goal", comment: "Goes into: 37 minutes to your 3h 30m goal.")
    }
}

/// "goal met Monday to Thursday": the days a streak covers.
enum StreakWords {
    /// The streak's days, newest first, walking back from yesterday the way
    /// `StreakCalculator` does (weekends skipped unless they count).
    static func days(count: Int, now: Date, weekendsCount: Bool, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        var out: [Date] = []
        var cursor = calendar.startOfDay(-1, from: now)
        var guardDays = 0
        while out.count < count, guardDays < 400 {
            let weekday = calendar.component(.weekday, from: cursor)
            let weekend = weekday == 1 || weekday == 7
            if weekendsCount || !weekend { out.append(cursor) }
            cursor = calendar.startOfDay(-1, from: cursor)
            guardDays += 1
        }
        return out
    }

    static func detail(count: Int, now: Date, weekendsCount: Bool, calendar: Calendar = .current) -> String {
        let days = days(count: count, now: now, weekendsCount: weekendsCount, calendar: calendar)
        guard let last = days.first, let first = days.last else {
            return String(localized: "meet today's goal to start one", comment: "Under the streak, when there is none: start a streak")
        }
        let weekday = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                       timeZone: calendar.timeZone).weekday(.wide)
        if days.count == 1 {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            if calendar.isDate(last, inSameDayAs: yesterday) { return String(localized: "goal met yesterday") }
            return String(localized: "goal met \(last.formatted(weekday))", comment: "Under the streak, with a weekday: goal met Monday")
        }
        let spanDays = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        if spanDays < 7 {
            return String(localized: "goal met \(first.formatted(weekday)) to \(last.formatted(weekday))", comment: "Under the streak: goal met Monday to Thursday")
        }
        let date = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                    timeZone: calendar.timeZone).day().month(.wide)
        return String(localized: "goal met since \(first.formatted(date))", comment: "Under the streak: goal met since 5 October")
    }
}
