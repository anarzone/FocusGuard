import Foundation

/// Names a session from how it went: a word for the focus pattern and a
/// word for the length — "Locked-in Deep Dive", "Comeback Run". A session
/// that's still running can't be judged yet, so it goes by the time of day.
enum SessionNamer {
    /// How the focus went, judged on tracked time.
    enum Pattern: String, CaseIterable {
        case lockedIn = "Locked-in"
        case slowStart = "Slow-start"
        case comeback = "Comeback"
        case fading = "Fading"
        case steady = "Steady"
        case bumpy = "Bumpy"
        case wandering = "Wandering"
        /// Nothing was tracked (away from the Mac the whole time).
        case quiet = "Quiet"
    }

    /// How long it ran, pauses excluded.
    enum Length: String, CaseIterable {
        case sprint = "Sprint"
        case run = "Run"
        case deepDive = "Deep Dive"
        case marathon = "Marathon"

        init(minutes: Double) {
            switch minutes {
            case ..<20: self = .sprint
            case ..<45: self = .run
            case ...90: self = .deepDive
            default: self = .marathon
            }
        }
    }

    /// Drift share in a third of the session that counts as "drifted".
    static let driftedThird = 0.25
    /// Drift share in a third of the session that still counts as clean.
    static let cleanThird = 0.10

    static func name(segments: [SessionTimeline.Segment], runningSeconds: TimeInterval) -> String {
        "\(pattern(of: segments).rawValue) \(Length(minutes: runningSeconds / 60).rawValue)"
    }

    static func name(for session: Session, endedAt: Date? = nil) -> String {
        let end = endedAt ?? session.endedAt ?? .now
        let running = max(0, end.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        return name(segments: SessionTimeline.segments(from: session.events), runningSeconds: running)
    }

    /// Patterns about *when* the drifting happened come first: they say
    /// more than the overall share. Focus share is focused / tracked time,
    /// the same figure the session lists show as a percentage.
    static func pattern(of segments: [SessionTimeline.Segment]) -> Pattern {
        let total = segments.reduce(0) { $0 + max(0, $1.seconds) }
        guard total >= 60 else { return .quiet }
        let focus = segments.filter { $0.classification == .focus }.reduce(0) { $0 + max(0, $1.seconds) }
        let share = focus / total
        if share >= 0.9 { return .lockedIn }

        let drift = driftShareByThird(segments, total: total)
        if drift[0] >= driftedThird, drift[1] <= cleanThird, drift[2] <= cleanThird { return .slowStart }
        if max(drift[0], drift[1]) >= driftedThird, drift[2] <= cleanThird { return .comeback }
        if drift[0] <= cleanThird, drift[2] >= driftedThird { return .fading }

        switch share {
        case 0.75...: return .steady
        case 0.5...: return .bumpy
        default: return .wandering
        }
    }

    /// Share of each third of tracked time spent on distractions.
    static func driftShareByThird(_ segments: [SessionTimeline.Segment], total: TimeInterval) -> [Double] {
        let third = total / 3
        var drifted = [0.0, 0.0, 0.0]
        var cursor: TimeInterval = 0
        for segment in segments {
            let start = cursor, end = cursor + max(0, segment.seconds)
            cursor = end
            guard segment.classification == .distraction else { continue }
            for i in 0..<3 {
                let overlap = min(end, third * Double(i + 1)) - max(start, third * Double(i))
                if overlap > 0 { drifted[i] += overlap }
            }
        }
        return drifted.map { $0 / third }
    }

    /// "Morning focus", "Late-night focus" — for a session still running.
    static func liveName(startedAt: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: startedAt) {
        case 5..<12: return "Morning focus"
        case 12..<17: return "Afternoon focus"
        case 17..<22: return "Evening focus"
        default: return "Late-night focus"
        }
    }
}

extension Session {
    /// What to call this session: the user's own label, else the name it
    /// earned when it ended, else the time of day while it runs.
    var displayName: String {
        label ?? autoName ?? SessionNamer.liveName(startedAt: startedAt)
    }
}
