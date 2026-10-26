import Foundation

/// A part of the day in whole local hours, `from` up to (not including) `to`.
struct CoachHours: Codable, Hashable, Sendable {
    let from: Int
    let to: Int

    static let morning = CoachHours(from: 0, to: 12)
    static let afternoon = CoachHours(from: 12, to: 17)
    static let evening = CoachHours(from: 17, to: 24)
    /// The parts sessions are grouped into, in order.
    static let parts = [morning, afternoon, evening]

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return from <= hour && hour < to
    }

    /// "before noon", "between 12:00 and 17:00", "after 17:00".
    func phrase(locale: Locale = .current, calendar: Calendar = .current) -> String {
        func clock(_ hour: Int) -> String {
            let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 0)) ?? .now
            return HabitFormat.time(date, locale: locale, calendar: calendar)
        }
        if from == 0 { return to == 12 ? "before noon" : "before \(clock(to))" }
        if to == 24 { return "after \(clock(from))" }
        return "between \(clock(from)) and \(clock(to))"
    }

    /// "morning", "afternoon" or "evening" for the three parts.
    var partOfDay: String? {
        switch self {
        case .morning:   return "morning"
        case .afternoon: return "afternoon"
        case .evening:   return "evening"
        default:         return nil
        }
    }
}

/// Something true about a week, worked out from the numbers alone. The
/// coach picks the strongest one each week; a model may only reword it.
enum CoachFinding: Equatable, Sendable {
    /// Sessions in one part of the day went much worse than in another.
    case timeOfDay(TimeOfDay)
    /// The same distraction, opened soon after most sessions ended.
    case afterSessions(AfterSessions)
    /// One day drifted far more than the others.
    case driftDay(DriftDay)
    /// Days whose first session started late focused less.
    case lateStarts(LateStarts)

    struct TimeOfDay: Equatable, Sendable {
        let weak: CoachHours
        let weakRate: Double
        let weakSessions: Int
        let strong: CoachHours
        let strongRate: Double
        let strongSessions: Int
        /// The weak sessions' drift after their 25th minute, as a share of all their drift.
        let lateDriftShare: Double
        /// The weak sessions' average length.
        let weakMinutes: Int
    }

    struct AfterSessions: Equatable, Sendable {
        let target: String
        let name: String
        let isSite: Bool
        /// Sessions it followed, of `sessions`.
        let count: Int
        let sessions: Int
        let withinMinutes: Int
        /// Average time a day on it, over the days with anything tracked.
        let dailySeconds: TimeInterval
    }

    struct DriftDay: Equatable, Sendable {
        let day: Date
        let drift: TimeInterval
        /// The other active days' average drift.
        let othersAverage: TimeInterval
        /// Where most of that day's drift went.
        let target: String
        let name: String
        let isSite: Bool
        let targetSeconds: TimeInterval
        /// Average time a day on it over the week's active days.
        let dailySeconds: TimeInterval
    }

    struct LateStarts: Equatable, Sendable {
        /// A first session at or after this clock time (minutes after
        /// midnight) counts as late.
        let cutoff: Int
        let lateDays: Int
        let earlyDays: Int
        /// Average focused time on late days, and on early ones.
        let lateFocus: TimeInterval
        let earlyFocus: TimeInterval
    }

    /// 0...1: how clear and how useful the finding is, to rank them.
    var strength: Double {
        switch self {
        case .timeOfDay(let f):
            let gap = f.strongRate - f.weakRate
            return min(1, gap / 0.35) * min(1, Double(min(f.weakSessions, f.strongSessions)) / 3)
        case .afterSessions(let f):
            return Double(f.count) / Double(max(1, f.sessions)) * min(1, Double(f.count) / 4) * 0.9
        case .driftDay(let f):
            return min(1, (f.drift - f.othersAverage) / max(1, f.drift)) * 0.8
        case .lateStarts(let f):
            return min(1, (f.earlyFocus - f.lateFocus) / max(1, f.earlyFocus)) * 0.75
        }
    }
}

/// Finds the week's patterns with plain statistics, so whatever the coach
/// says is true of the user's own data.
enum CoachPatternFinder {
    /// Drift after this point in a session counts as late.
    static let lateInSession: TimeInterval = 25 * 60
    /// How soon after a session ends a distraction counts as "right after".
    static let afterSessionWindow: TimeInterval = 3 * 60

    /// Every pattern found, strongest first.
    /// - Parameter lateStartCutoff: minutes after midnight from which a
    ///   day's first session counts as late (10:00 by default).
    static func find(in data: CoachData, lateStartCutoff: Int = 600,
                     calendar: Calendar = .current) -> [CoachFinding] {
        [timeOfDay(data, calendar: calendar),
         afterSessions(data, calendar: calendar),
         driftDay(data, calendar: calendar),
         lateStarts(data, cutoff: lateStartCutoff, calendar: calendar)]
            .compactMap { $0 }
            .sorted { $0.strength > $1.strength }
    }

    // MARK: - Time of day

    /// The part of the day whose sessions ran at the lowest focus rate,
    /// against the one with the highest, 15 points apart or more.
    static func timeOfDay(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        struct Part {
            var focus: TimeInterval = 0, drift: TimeInterval = 0, lateDrift: TimeInterval = 0
            var sessions = 0, minutes = 0
            var rate: Double { FocusRate.of(focused: focus, drifted: drift) }
        }
        let bySession = data.eventsBySession
        var parts: [CoachHours: Part] = [:]
        for session in data.sessions {
            guard let hours = CoachHours.parts.first(where: { $0.contains(session.start, calendar: calendar) }) else { continue }
            let events = bySession[session.id] ?? []
            let tally = CoachData.tally(events)
            guard tally.focus + tally.drift >= 5 * 60 else { continue }
            let lateFrom = session.start.addingTimeInterval(lateInSession)
            var part = parts[hours] ?? Part()
            part.focus += tally.focus
            part.drift += tally.drift
            part.lateDrift += events.filter { $0.kind == .distraction }
                .reduce(0) { $0 + max(0, $1.end.timeIntervalSince(max($1.start, lateFrom))) }
            part.sessions += 1
            part.minutes += session.minutes
            parts[hours] = part
        }
        let rated: [(CoachHours, Part)] = CoachHours.parts.compactMap { hours in
            guard let part = parts[hours], part.sessions >= 2, part.focus + part.drift >= 20 * 60 else { return nil }
            return (hours, part)
        }
        guard rated.count >= 2,
              let weak = rated.min(by: { $0.1.rate < $1.1.rate }),
              let strong = rated.max(by: { $0.1.rate < $1.1.rate }),
              strong.1.rate - weak.1.rate >= 0.15 else { return nil }
        return .timeOfDay(.init(
            weak: weak.0, weakRate: weak.1.rate, weakSessions: weak.1.sessions,
            strong: strong.0, strongRate: strong.1.rate, strongSessions: strong.1.sessions,
            lateDriftShare: weak.1.drift > 0 ? weak.1.lateDrift / weak.1.drift : 0,
            weakMinutes: weak.1.minutes / max(1, weak.1.sessions)
        ))
    }

    // MARK: - Right after sessions

    /// The distraction opened first within 3 minutes of a session ending,
    /// when it's the same one after at least 3 sessions and half of them.
    static func afterSessions(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        guard data.sessions.count >= 4 else { return nil }
        let loose = data.events.filter { $0.session == nil && $0.kind == .distraction }.sorted { $0.start < $1.start }
        var counts: [String: (name: String, isSite: Bool, count: Int)] = [:]
        for session in data.sessions {
            let window = session.end.addingTimeInterval(-1)...session.end.addingTimeInterval(afterSessionWindow)
            guard let first = loose.first(where: { window.contains($0.start) }) else { continue }
            let entry = counts[first.target] ?? (first.name, first.isSite, 0)
            counts[first.target] = (entry.name, entry.isSite, entry.count + 1)
        }
        guard let best = counts.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
              best.value.count >= 3,
              Double(best.value.count) / Double(data.sessions.count) >= 0.5 else { return nil }
        let total = data.events.filter { $0.target == best.key }.reduce(0) { $0 + $1.duration }
        return .afterSessions(.init(
            target: best.key, name: best.value.name, isSite: best.value.isSite,
            count: best.value.count, sessions: data.sessions.count,
            withinMinutes: Int(afterSessionWindow / 60),
            dailySeconds: total / Double(max(1, data.activeDays(calendar: calendar).count))
        ))
    }

    // MARK: - The day that drifted

    /// The day with the most drift, when it's well above the other days.
    static func driftDay(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        let byDay = Dictionary(grouping: data.events) { calendar.startOfDay(for: $0.start) }
        guard byDay.count >= 3 else { return nil }
        let drift = byDay.mapValues { $0.filter { $0.kind == .distraction }.reduce(0) { $0 + $1.duration } }
        guard let worst = drift.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        let others = drift.filter { $0.key != worst.key }.map(\.value)
        let average = others.reduce(0, +) / Double(max(1, others.count))
        guard worst.value >= 45 * 60, worst.value >= average * 1.6, worst.value - average >= 30 * 60 else { return nil }

        let onDay = (byDay[worst.key] ?? []).filter { $0.kind == .distraction }
        let byTarget = Dictionary(grouping: onDay, by: \.target).mapValues { $0.reduce(0) { $0 + $1.duration } }
        guard let top = byTarget.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              let sample = onDay.first(where: { $0.target == top.key }) else { return nil }
        let weekTotal = data.events.filter { $0.target == top.key }.reduce(0) { $0 + $1.duration }
        return .driftDay(.init(
            day: worst.key, drift: worst.value, othersAverage: average,
            target: top.key, name: sample.name, isSite: sample.isSite, targetSeconds: top.value,
            dailySeconds: weekTotal / Double(byDay.count)
        ))
    }

    // MARK: - Late starts

    /// Days whose first session started at or after `cutoff`, against days
    /// that started earlier, when the early ones focused clearly more.
    static func lateStarts(_ data: CoachData, cutoff: Int = 600, calendar: Calendar = .current) -> CoachFinding? {
        let firstByDay = Dictionary(grouping: data.sessions) { calendar.startOfDay(for: $0.start) }
            .compactMapValues { $0.map(\.start).min() }
        let focusByDay = Dictionary(grouping: data.events.filter { $0.kind == .focus }) { calendar.startOfDay(for: $0.start) }
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
        var late: [TimeInterval] = [], early: [TimeInterval] = []
        for (day, first) in firstByDay {
            let parts = calendar.dateComponents([.hour, .minute], from: first)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if minute >= cutoff { late.append(focusByDay[day] ?? 0) } else { early.append(focusByDay[day] ?? 0) }
        }
        guard late.count >= 2, early.count >= 2 else { return nil }
        let lateFocus = late.reduce(0, +) / Double(late.count)
        let earlyFocus = early.reduce(0, +) / Double(early.count)
        guard earlyFocus >= lateFocus * 1.3, earlyFocus - lateFocus >= 45 * 60 else { return nil }
        return .lateStarts(.init(cutoff: cutoff, lateDays: late.count, earlyDays: early.count,
                                 lateFocus: lateFocus, earlyFocus: earlyFocus))
    }
}
