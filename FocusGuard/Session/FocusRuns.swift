import Foundation

/// "In the zone": unbroken stretches of focused time inside sessions.
///
/// A run survives short blips — a glance at Finder, a quick tab switch — and
/// breaks when the user drifts to something distracting for longer than
/// `driftBreak`, spends longer than `blipGrace` on anything else, or goes
/// idle for longer than `blipGrace`.
struct FocusRuns: Equatable {
    struct Span: Equatable {
        let start: Date
        let end: Date
        let classification: Classification
    }

    /// Non-focus time shorter than this doesn't break a run.
    static let blipGrace: TimeInterval = 30
    /// Distracting time longer than this breaks a run — matches the default
    /// silence window, so the counter resets as the menu shows "drifted".
    static let driftBreak: TimeInterval = 10

    /// Length of the run in progress; 0 when not currently in one.
    let current: TimeInterval
    /// Longest run in the spans.
    let longest: TimeInterval
    /// Length of the most recent run that has ended (for "Run ended at…").
    let lastEnded: TimeInterval

    static let empty = FocusRuns(current: 0, longest: 0, lastEnded: 0)

    static func compute(_ spans: [Span], now: Date) -> FocusRuns {
        var longest: TimeInterval = 0
        var lastEnded: TimeInterval = 0
        var runStart: Date?
        var lastFocusEnd: Date?

        func endRun() {
            if let start = runStart, let end = lastFocusEnd {
                lastEnded = end.timeIntervalSince(start)
            }
            runStart = nil
        }

        for span in spans.sorted(by: { $0.start < $1.start }) {
            let length = span.end.timeIntervalSince(span.start)
            if span.classification == .focus {
                if let end = lastFocusEnd, runStart != nil, span.start.timeIntervalSince(end) > blipGrace {
                    endRun()
                }
                if runStart == nil { runStart = span.start }
                lastFocusEnd = max(lastFocusEnd ?? span.end, span.end)
                if let start = runStart, let end = lastFocusEnd {
                    longest = max(longest, end.timeIntervalSince(start))
                }
            } else {
                let limit = span.classification == .distraction ? driftBreak : blipGrace
                if runStart != nil, length > limit { endRun() }
            }
        }

        var current: TimeInterval = 0
        if let start = runStart, let end = lastFocusEnd {
            if now.timeIntervalSince(end) <= blipGrace {
                current = end.timeIntervalSince(start)
            } else {
                lastEnded = end.timeIntervalSince(start)
            }
        }
        return FocusRuns(current: current, longest: longest, lastEnded: lastEnded)
    }

    /// Spans from tracked events. Each event covers its first through last
    /// 1 Hz sample, so it ends one second after `endedAt`.
    static func spans(from events: [ActivityEvent]) -> [Span] {
        events.map {
            Span(start: $0.startedAt,
                 end: $0.endedAt.addingTimeInterval(1),
                 classification: $0.classification ?? .neutral)
        }
    }
}
