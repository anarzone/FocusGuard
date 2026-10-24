import Foundation
import SwiftData

/// The stretch of time "How focused was I?" asks about.
enum FocusPeriod: Equatable {
    case today, yesterday, thisWeek
}

/// Focused time, focus rate and sessions over a day or a week.
struct FocusSummary: Equatable {
    let period: FocusPeriod
    /// Start of the period; it runs to `until` (now, for today and this week).
    let from: Date
    let until: Date
    let focused: TimeInterval
    let drifted: TimeInterval
    let other: TimeInterval
    /// Sessions started in the period, the running one included.
    let sessions: Int
    /// Longest unbroken focus run inside those sessions.
    let bestStretch: TimeInterval

    var tracked: TimeInterval { focused + drifted + other }

    var focusRate: Double { FocusRate.of(focused: focused, drifted: drifted) }
    var focusPercent: Int { FocusRate.percent(focused: focused, drifted: drifted) }
}

enum FocusNumbers {
    static func range(of period: FocusPeriod, now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        switch period {
        case .today:
            return DateInterval(start: today, end: tomorrow)
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
            return DateInterval(start: yesterday, end: today)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: today, end: tomorrow)
        }
    }

    /// Reads one period through `context`. Cheap for a day; a week reads a
    /// week of events, so callers keep it off the main thread.
    static func summary(_ period: FocusPeriod, context: ModelContext, now: Date = .now,
                        calendar: Calendar = .current) -> FocusSummary {
        let range = range(of: period, now: now, calendar: calendar)
        let from = range.start, end = range.end
        let until = min(now, end)
        let breakdown = ReportBuilder(context: context).breakdown(from: from, to: until)

        let sessionCount = Persistence.fetchCount(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= from && $0.startedAt < end }
        ))

        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < end }
        )
        let sessionEvents = Persistence.fetch(context, descriptor).filter { $0.session != nil }
        let best = FocusRuns.compute(FocusRuns.spans(from: sessionEvents), now: until).longest

        return FocusSummary(
            period: period, from: from, until: until,
            focused: breakdown.focus, drifted: breakdown.distraction, other: breakdown.neutral,
            sessions: sessionCount, bestStretch: best
        )
    }

    /// `summary` on a fresh context, off the main thread.
    static func summary(_ period: FocusPeriod, container: ModelContainer, now: Date = .now) async -> FocusSummary {
        await Task.detached(priority: .userInitiated) {
            summary(period, context: ModelContext(container), now: now)
        }.value
    }

    // MARK: - Words

    /// "3h 40m", "45m", "0m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return FocusGoal.format(minutes: minutes)
    }

    /// One sentence for Siri and Spotlight.
    static func sentence(for summary: FocusSummary) -> String {
        let when: String
        switch summary.period {
        case .today:     when = "Today so far"
        case .yesterday: when = "Yesterday"
        case .thisWeek:  when = "This week so far"
        }
        guard summary.tracked >= 60 else {
            switch summary.period {
            case .today:     return "Nothing tracked today yet."
            case .yesterday: return "Nothing was tracked yesterday."
            case .thisWeek:  return "Nothing tracked this week yet."
            }
        }
        let sessions = summary.sessions == 1 ? "1 session" : "\(summary.sessions) sessions"
        return "\(when): \(duration(summary.focused)) focused, \(summary.focusPercent)% focus rate, \(sessions)."
    }
}
