import Foundation

/// What the desktop widgets and the Control Center control show. The app
/// writes it to the shared App Group folder whenever something changes;
/// the widget extension only reads it. Compiled into both.
struct SurfaceSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var writtenAt: Date
    var phase: Phase
    /// The running or paused session.
    var session: Running?
    var onBreak: Break?
    var today: Day
    var week: Week
    var lastSession: Last?
    /// The length "Start" uses: the menu's last one, else the default.
    var usualMinutes: Int
    /// Widget commands the app has carried out, newest last (a few at most).
    var handled: [UUID] = []

    enum Phase: String, Codable {
        case ready, focusing, paused, onBreak
    }

    struct Running: Codable, Equatable {
        var name: String
        var startedAt: Date
        /// Nil for an open-ended session.
        var plannedSeconds: TimeInterval?
        /// Running time (pauses left out) when the snapshot was written.
        var runningSeconds: TimeInterval
        var focused: TimeInterval
        var drifted: TimeInterval
        var other: TimeInterval
        /// The session ring, one character per cell, as the menu draws it:
        /// f focused, d drifted, o other, n the cell in progress, . to come.
        var ring: String

        var focusRate: Double { SurfaceSnapshot.rate(focused: focused, drifted: drifted) }
    }

    struct Break: Codable, Equatable {
        var startedAt: Date
        var endsAt: Date
        /// False with strict breaks: nothing offers to end it.
        var canEndEarly: Bool
    }

    struct Day: Codable, Equatable {
        /// Start of the day these numbers are for.
        var start: Date
        var focused: TimeInterval
        var drifted: TimeInterval
        var other: TimeInterval
        var sessions: Int
        var goalSeconds: TimeInterval
        /// Days in a row the goal was met, up to yesterday.
        var streak: Int

        var focusRate: Double { SurfaceSnapshot.rate(focused: focused, drifted: drifted) }
        var goalProgress: Double { goalSeconds > 0 ? min(1, focused / goalSeconds) : 0 }
    }

    struct Week: Codable, Equatable {
        /// Start of the week's first day.
        var start: Date
        /// Focused seconds per day, seven of them, in calendar order.
        var focused: [TimeInterval]
    }

    struct Last: Codable, Equatable {
        var name: String
        var endedAt: Date
        var minutes: Int
        var focusRate: Double
    }

    /// Focused ÷ (focused + drifted), the rate shown everywhere.
    static func rate(focused: TimeInterval, drifted: TimeInterval) -> Double {
        let counted = max(0, focused) + max(0, drifted)
        return counted > 0 ? max(0, focused) / counted : 0
    }

    // MARK: - Time

    /// When the running session ends, if it's timed and not paused.
    var sessionEndsAt: Date? {
        guard phase == .focusing, let session, let planned = session.plannedSeconds else { return nil }
        return writtenAt.addingTimeInterval(max(0, planned - session.runningSeconds))
    }

    /// Running time of the session at `date`.
    func running(at date: Date) -> TimeInterval {
        guard let session else { return 0 }
        guard phase == .focusing else { return session.runningSeconds }
        return session.runningSeconds + max(0, date.timeIntervalSince(writtenAt))
    }

    /// Seconds left at `date` in a timed session.
    func timeLeft(at date: Date) -> TimeInterval? {
        guard let planned = session?.plannedSeconds else { return nil }
        return max(0, planned - running(at: date))
    }

    /// Share of a timed session done at `date`, 0...1; nil when open-ended.
    func sessionProgress(at date: Date) -> Double? {
        guard let planned = session?.plannedSeconds, planned > 0 else { return nil }
        return min(1, running(at: date) / planned)
    }

    /// The snapshot as it will look at `date` if nothing else happens: a
    /// timed session or a break that has run out is over, and a new day or
    /// week starts from zero. Lets a widget timeline run ahead without the
    /// app.
    func projected(to date: Date, calendar: Calendar = .current) -> SurfaceSnapshot {
        var next = self
        if phase == .focusing, let session, let planned = session.plannedSeconds,
           running(at: date) >= planned {
            next.phase = .ready
            next.session = nil
            next.lastSession = Last(
                name: session.name,
                endedAt: writtenAt.addingTimeInterval(max(0, planned - session.runningSeconds)),
                minutes: Int(planned / 60),
                focusRate: session.focusRate
            )
        }
        if phase == .onBreak, let onBreak, onBreak.endsAt <= date {
            next.phase = .ready
            next.onBreak = nil
        }
        if !calendar.isDate(today.start, inSameDayAs: date) && date > today.start {
            next.today = Day(start: calendar.startOfDay(for: date), focused: 0, drifted: 0, other: 0,
                             sessions: next.phase == .ready ? 0 : 1, goalSeconds: today.goalSeconds,
                             streak: today.focused >= today.goalSeconds && today.goalSeconds > 0
                                 ? today.streak + 1 : today.streak)
        }
        if let weekEnd = calendar.date(byAdding: .day, value: 7, to: week.start), date >= weekEnd {
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            next.week = Week(start: start, focused: Array(repeating: 0, count: 7))
        }
        return next
    }

    /// Index of `date`'s day in the week, 0...6, or nil outside it.
    func weekIndex(of date: Date, calendar: Calendar = .current) -> Int? {
        let day = calendar.dateComponents([.day], from: week.start, to: calendar.startOfDay(for: date)).day ?? -1
        return (0..<7).contains(day) ? day : nil
    }
}
