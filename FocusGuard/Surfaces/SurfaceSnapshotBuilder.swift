import Foundation
import SwiftData

/// The numbers the widgets show that come from the store: today, this
/// week day by day, and the last session. Read off the main thread; days
/// already over are kept, since they don't change.
actor SurfaceStats {
    struct Numbers: Equatable {
        let today: FocusSummary
        let week: SurfaceSnapshot.Week
        let last: SurfaceSnapshot.Last?
        let streak: Int
    }

    private let container: ModelContainer
    /// Focused seconds of finished days, by day start.
    private var pastFocus: [Date: TimeInterval] = [:]
    /// The streak only moves at midnight (or when the goal changes).
    private var streak: (day: Date, goal: TimeInterval, value: Int)?

    init(container: ModelContainer) {
        self.container = container
    }

    /// Reclassified or erased events: kept days are stale.
    func forgetPastDays() {
        pastFocus = [:]
        streak = nil
    }

    func read(now: Date, goal: TimeInterval, calendar: Calendar = .current) -> Numbers {
        let context = ModelContext(container)
        let today = FocusNumbers.summary(.today, context: context, now: now, calendar: calendar)
        let dayStart = calendar.startOfDay(for: now)

        let range = FocusNumbers.range(of: .thisWeek, now: now, calendar: calendar)
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: range.start) ?? range.start }
        let missing = days.filter { $0 < dayStart && pastFocus[$0] == nil }
        if let first = missing.first {
            for day in ReportBuilder(context: context).dailyBreakdowns(from: first, to: dayStart, calendar: calendar) {
                pastFocus[day.date] = day.focus
            }
            pastFocus = pastFocus.filter { $0.key >= range.start }
        }
        let focused = days.map { day -> TimeInterval in
            if day < dayStart { return pastFocus[day] ?? 0 }
            return calendar.isDate(day, inSameDayAs: dayStart) ? today.focused : 0
        }

        if streak?.day != dayStart || streak?.goal != goal {
            streak = (dayStart, goal, StreakCalculator(context: context).currentStreak(now: now, calendar: calendar))
        }

        return Numbers(
            today: today,
            week: SurfaceSnapshot.Week(start: range.start, focused: focused),
            last: Self.lastSession(context, now: now),
            streak: streak?.value ?? 0
        )
    }

    private static func lastSession(_ context: ModelContext, now: Date) -> SurfaceSnapshot.Last? {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.endedAt != nil },
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let session = Persistence.fetch(context, descriptor).first, let endedAt = session.endedAt else { return nil }
        let split = SurfaceSnapshotBuilder.split(SessionTimeline.segments(from: session.events))
        let running = max(0, endedAt.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        return SurfaceSnapshot.Last(name: session.displayName, endedAt: endedAt, minutes: Int(running / 60),
                                    focusRate: SurfaceSnapshot.rate(focused: split.focused, drifted: split.drifted))
    }
}

/// Puts the snapshot together from the live session or break and the
/// numbers from the store.
@MainActor
enum SurfaceSnapshotBuilder {
    static func make(sessions: SessionManager, breaks: BreakManager,
                     timeline: (Session) -> SessionTimeline,
                     numbers: SurfaceStats.Numbers, goal: TimeInterval, usualMinutes: Int,
                     handled: [UUID], now: Date) -> SurfaceSnapshot {
        var phase = SurfaceSnapshot.Phase.ready
        var running: SurfaceSnapshot.Running?
        var onBreak: SurfaceSnapshot.Break?

        if let state = breaks.current {
            phase = .onBreak
            onBreak = SurfaceSnapshot.Break(startedAt: state.startedAt,
                                            endsAt: state.startedAt.addingTimeInterval(state.plannedDuration),
                                            canEndEarly: breaks.canEndEarly)
        } else if let session = sessions.currentSession {
            phase = session.pausedAt == nil ? .focusing : .paused
            let split = split(SessionTimeline.segments(from: session.events))
            running = SurfaceSnapshot.Running(
                name: session.displayName,
                startedAt: session.startedAt,
                plannedSeconds: session.plannedDurationMinutes.map { TimeInterval($0 * 60) },
                runningSeconds: sessions.runningSeconds(for: session, now: now),
                focused: split.focused, drifted: split.drifted, other: split.other,
                ring: ring(timeline(session))
            )
        }

        let today = numbers.today
        return SurfaceSnapshot(
            writtenAt: now,
            phase: phase,
            session: running,
            onBreak: onBreak,
            today: SurfaceSnapshot.Day(start: today.from, focused: today.focused, drifted: today.drifted,
                                       other: today.other, sessions: today.sessions, goalSeconds: goal,
                                       streak: numbers.streak),
            week: numbers.week,
            lastSession: numbers.last,
            usualMinutes: usualMinutes,
            handled: handled
        )
    }

    /// Tracked seconds by kind.
    nonisolated static func split(_ segments: [SessionTimeline.Segment]) -> (focused: TimeInterval, drifted: TimeInterval, other: TimeInterval) {
        var focused: TimeInterval = 0, drifted: TimeInterval = 0, other: TimeInterval = 0
        for segment in segments {
            switch segment.classification {
            case .focus:       focused += segment.seconds
            case .distraction: drifted += segment.seconds
            case .neutral:     other += segment.seconds
            }
        }
        return (focused, drifted, other)
    }

    /// The ring as characters: f focused, d drifted, o other, n now, . to come.
    nonisolated static func ring(_ timeline: SessionTimeline) -> String {
        String(timeline.cells.map { cell -> Character in
            switch cell {
            case .focus:  return "f"
            case .drift:  return "d"
            case .other:  return "o"
            case .now:    return "n"
            case .future: return "."
            }
        })
    }
}
