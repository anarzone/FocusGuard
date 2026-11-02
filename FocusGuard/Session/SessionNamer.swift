import Foundation

/// Names a session from how it went: a word for the focus pattern and a
/// word for the length — "Locked-in Deep Dive", "Comeback Run". A session
/// that's still running can't be judged yet, so it goes by the time of day.
///
/// `Session.autoName` keeps the English name whatever the language, since
/// `ReportsModelBuilder.pattern(of:)` reads the pattern back out of it.
/// `localizedName(stored:)` turns it into the name people see.
enum SessionNamer {
    /// How the focus went, judged on the focus rate and where the drift fell.
    /// The raw value is the word inside a stored name; `title` is what's shown.
    enum Pattern: String, CaseIterable {
        case lockedIn = "Locked-in"
        case slowStart = "Slow-start"
        case comeback = "Comeback"
        case fading = "Fading"
        case steady = "Steady"
        case bumpy = "Bumpy"
        case wandering = "Wandering"
        /// Nothing counted either way: away from the Mac, or only in
        /// neutral apps.
        case quiet = "Quiet"

        var title: String {
            switch self {
            case .lockedIn:   return String(localized: "Locked-in", comment: "How a session went, as a label")
            case .slowStart:  return String(localized: "Slow-start", comment: "How a session went, as a label")
            case .comeback:   return String(localized: "Comeback", comment: "How a session went, as a label")
            case .fading:     return String(localized: "Fading", comment: "How a session went, as a label")
            case .steady:     return String(localized: "Steady", comment: "How a session went, as a label")
            case .bumpy:      return String(localized: "Bumpy", comment: "How a session went, as a label")
            case .wandering:  return String(localized: "Wandering", comment: "How a session went, as a label")
            case .quiet:      return String(localized: "Quiet", comment: "How a session went, as a label")
            }
        }
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

    /// The name to store: always English.
    static func name(segments: [SessionTimeline.Segment], runningSeconds: TimeInterval) -> String {
        "\(pattern(of: segments).rawValue) \(Length(minutes: runningSeconds / 60).rawValue)"
    }

    static func name(for session: Session, endedAt: Date? = nil) -> String {
        let end = endedAt ?? session.endedAt ?? .now
        let running = max(0, end.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        return name(segments: SessionTimeline.segments(from: session.events), runningSeconds: running)
    }

    /// A stored name in the user's language; a name it can't read stays as it is.
    static func localizedName(stored: String) -> String {
        for word in Pattern.allCases where stored.hasPrefix(word.rawValue + " ") {
            if let length = Length(rawValue: String(stored.dropFirst(word.rawValue.count + 1))) {
                return localizedName(word, length)
            }
        }
        return stored
    }

    /// Each name is a key of its own: the two words agree differently in
    /// each language, and can't be put together from parts.
    private static func localizedName(_ word: Pattern, _ length: Length) -> String {
        switch (word, length) {
        case (.lockedIn, .sprint):    return String(localized: "Locked-in Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.lockedIn, .run):       return String(localized: "Locked-in Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.lockedIn, .deepDive):  return String(localized: "Locked-in Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.lockedIn, .marathon):  return String(localized: "Locked-in Marathon", comment: "Automatic session name, shown alone and inside sentences")
        case (.slowStart, .sprint):   return String(localized: "Slow-start Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.slowStart, .run):      return String(localized: "Slow-start Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.slowStart, .deepDive): return String(localized: "Slow-start Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.slowStart, .marathon): return String(localized: "Slow-start Marathon", comment: "Automatic session name, shown alone and inside sentences")
        case (.comeback, .sprint):    return String(localized: "Comeback Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.comeback, .run):       return String(localized: "Comeback Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.comeback, .deepDive):  return String(localized: "Comeback Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.comeback, .marathon):  return String(localized: "Comeback Marathon", comment: "Automatic session name, shown alone and inside sentences")
        case (.fading, .sprint):      return String(localized: "Fading Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.fading, .run):         return String(localized: "Fading Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.fading, .deepDive):    return String(localized: "Fading Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.fading, .marathon):    return String(localized: "Fading Marathon", comment: "Automatic session name, shown alone and inside sentences")
        case (.steady, .sprint):      return String(localized: "Steady Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.steady, .run):         return String(localized: "Steady Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.steady, .deepDive):    return String(localized: "Steady Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.steady, .marathon):    return String(localized: "Steady Marathon", comment: "Automatic session name, shown alone and inside sentences")
        case (.bumpy, .sprint):       return String(localized: "Bumpy Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.bumpy, .run):          return String(localized: "Bumpy Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.bumpy, .deepDive):     return String(localized: "Bumpy Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.bumpy, .marathon):     return String(localized: "Bumpy Marathon", comment: "Automatic session name, shown alone and inside sentences")
        case (.wandering, .sprint):   return String(localized: "Wandering Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.wandering, .run):      return String(localized: "Wandering Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.wandering, .deepDive): return String(localized: "Wandering Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.wandering, .marathon): return String(localized: "Wandering Marathon", comment: "Automatic session name, shown alone and inside sentences")
        case (.quiet, .sprint):       return String(localized: "Quiet Sprint", comment: "Automatic session name, shown alone and inside sentences")
        case (.quiet, .run):          return String(localized: "Quiet Run", comment: "Automatic session name, shown alone and inside sentences")
        case (.quiet, .deepDive):     return String(localized: "Quiet Deep Dive", comment: "Automatic session name, shown alone and inside sentences")
        case (.quiet, .marathon):     return String(localized: "Quiet Marathon", comment: "Automatic session name, shown alone and inside sentences")
        }
    }

    /// Patterns about *when* the drifting happened come first: they say
    /// more than the overall rate. The rate is `FocusRate`, the same figure
    /// the session lists show as a percentage; the thirds are thirds of
    /// tracked time.
    static func pattern(of segments: [SessionTimeline.Segment]) -> Pattern {
        func seconds(_ c: Classification) -> TimeInterval {
            segments.filter { $0.classification == c }.reduce(0) { $0 + max(0, $1.seconds) }
        }
        let focus = seconds(.focus), drifted = seconds(.distraction)
        guard focus + drifted >= 60 else { return .quiet }
        let total = segments.reduce(0) { $0 + max(0, $1.seconds) }
        let rate = FocusRate.of(focused: focus, drifted: drifted)
        if rate >= 0.9 { return .lockedIn }

        let drift = driftShareByThird(segments, total: total)
        if drift[0] >= driftedThird, drift[1] <= cleanThird, drift[2] <= cleanThird { return .slowStart }
        if max(drift[0], drift[1]) >= driftedThird, drift[2] <= cleanThird { return .comeback }
        if drift[0] <= cleanThird, drift[2] >= driftedThird { return .fading }

        switch rate {
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
        case 5..<12: return String(localized: "Morning focus", comment: "Name of a session still running, shown alone and inside sentences")
        case 12..<17: return String(localized: "Afternoon focus", comment: "Name of a session still running, shown alone and inside sentences")
        case 17..<22: return String(localized: "Evening focus", comment: "Name of a session still running, shown alone and inside sentences")
        default: return String(localized: "Late-night focus", comment: "Name of a session still running, shown alone and inside sentences")
        }
    }
}

extension Session {
    /// What to call this session: the user's own label, else the name it
    /// earned when it ended, else the time of day while it runs.
    var displayName: String {
        label ?? autoName.map(SessionNamer.localizedName(stored:)) ?? SessionNamer.liveName(startedAt: startedAt)
    }
}
