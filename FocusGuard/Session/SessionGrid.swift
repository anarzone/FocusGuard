import Foundation

/// Minute-by-minute picture of a focus session — the menu's replacement for a
/// countdown. One cell is one minute (several, for long sessions, so the grid
/// never exceeds `maxCells`), coloured by what dominated that slice of
/// running time.
struct SessionGrid: Equatable {
    enum Cell: Equatable {
        case focus, drift, other
        /// The minute in progress, tinted by what the user is doing right now.
        case now(Classification)
        case future
    }

    /// A stretch of tracked time, in session order.
    struct Segment: Equatable {
        let classification: Classification
        let seconds: TimeInterval
    }

    static let maxCells = 60
    static let columns = 10

    let cells: [Cell]
    let minutesPerCell: Int

    // MARK: - Stats (classified cells only — `now` and `future` excluded)

    var focusCells: Int { cells.filter { $0 == .focus }.count }
    var driftCells: Int { cells.filter { $0 == .drift }.count }
    var otherCells: Int { cells.filter { $0 == .other }.count }
    var classifiedCells: Int { focusCells + driftCells + otherCells }

    var focusPercent: Int {
        guard classifiedCells > 0 else { return 0 }
        return Int((Double(focusCells) / Double(classifiedCells) * 100).rounded())
    }

    var longestFocusRunMinutes: Int {
        var best = 0, run = 0
        for cell in cells {
            if cell == .focus { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best * minutesPerCell
    }

    // MARK: - Building

    /// - Parameters:
    ///   - segments: tracked time in order.
    ///   - elapsed: running seconds (pauses excluded).
    ///   - planned: planned length in seconds; nil for open-ended sessions.
    ///   - current: what the user is doing now. Non-nil means the session is
    ///     live: the grid then shows a `now` cell and `future` cells up to the
    ///     planned length. Nil means it ended: the grid covers exactly the
    ///     minutes that ran.
    ///   - live: override for a paused session — still live (future cells
    ///     shown) but with no `now` cell. Defaults to `current != nil`.
    static func build(
        segments: [Segment],
        elapsed: TimeInterval,
        planned: TimeInterval?,
        current: Classification?,
        live: Bool? = nil
    ) -> SessionGrid {
        let elapsedMinutes = max(0, elapsed) / 60
        let live = live ?? (current != nil)

        let totalMinutes: Int
        if live, let planned, planned > 0 {
            totalMinutes = max(1, Int((planned / 60).rounded(.up)))
        } else if live {
            // Open-ended: grow a row of ten at a time.
            totalMinutes = (Int(elapsedMinutes) / columns + 1) * columns
        } else {
            totalMinutes = max(1, Int(elapsedMinutes.rounded()))
        }

        let minutesPerCell = max(1, Int((Double(totalMinutes) / Double(maxCells)).rounded(.up)))
        let cellCount = Int((Double(totalMinutes) / Double(minutesPerCell)).rounded(.up))
        let done = live
            ? min(cellCount, Int(elapsedMinutes / Double(minutesPerCell)))
            : cellCount

        var cells = classify(segments, into: done)
        if let current, cells.count < cellCount {
            cells.append(.now(current))
        }
        while cells.count < cellCount { cells.append(.future) }
        return SessionGrid(cells: cells, minutesPerCell: minutesPerCell)
    }

    /// Spreads tracked time evenly across `count` cells and gives each cell
    /// the classification that covers most of its slice. Spreading (rather
    /// than bucketing by wall clock) keeps idle gaps and the tracker's 1 Hz
    /// sampling from leaving holes.
    static func classify(_ segments: [Segment], into count: Int) -> [Cell] {
        guard count > 0 else { return [] }
        let total = segments.reduce(0) { $0 + max(0, $1.seconds) }
        guard total > 0 else { return Array(repeating: .other, count: count) }

        let slice = total / Double(count)
        var out: [Cell] = []
        out.reserveCapacity(count)
        var index = 0
        var used: TimeInterval = 0

        for _ in 0..<count {
            var need = slice
            var share: [Classification: TimeInterval] = [:]
            while need > 1e-9, index < segments.count {
                let segment = segments[index]
                let take = min(max(0, segment.seconds) - used, need)
                share[segment.classification, default: 0] += take
                need -= take
                used += take
                if used >= max(0, segment.seconds) - 1e-9 {
                    index += 1
                    used = 0
                }
            }
            out.append(dominant(share))
        }
        return out
    }

    /// Ties go to drift, then focus — a drifted minute should never hide.
    private static func dominant(_ share: [Classification: TimeInterval]) -> Cell {
        let focus = share[.focus] ?? 0
        let drift = share[.distraction] ?? 0
        let other = share[.neutral] ?? 0
        if drift > 0, drift >= focus, drift >= other { return .drift }
        if focus > 0, focus >= other { return .focus }
        return .other
    }
}

extension SessionGrid {
    /// Segments from a session's events, in order. Each event covers its
    /// first through last 1 Hz sample, so it stands for `duration + 1` seconds.
    static func segments(from events: [ActivityEvent]) -> [Segment] {
        events
            .sorted { $0.startedAt < $1.startedAt }
            .map { Segment(classification: $0.classification ?? .neutral, seconds: max(0, $0.duration) + 1) }
    }

    /// The site (or app) the user drifted to most, with total seconds.
    static func topDrift(in events: [ActivityEvent]) -> (name: String, seconds: TimeInterval)? {
        var totals: [String: TimeInterval] = [:]
        for event in events where event.classification == .distraction {
            let host = event.url.flatMap { URL(string: $0)?.host }
                .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            totals[host ?? event.appName, default: 0] += max(0, event.duration) + 1
        }
        return totals.max { $0.value < $1.value }.map { (name: $0.key, seconds: $0.value) }
    }
}
