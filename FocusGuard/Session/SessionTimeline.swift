import Foundation

/// Minute-by-minute picture of a focus session, drawn as the session ring.
/// One cell is one minute (several, for long sessions, so the ring never has
/// more than `maxCells` slices), coloured by what dominated that slice of
/// running time.
struct SessionTimeline: Equatable {
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
    /// Open-ended sessions grow their timeline in steps of this many minutes.
    static let columns = 10

    let cells: [Cell]
    let minutesPerCell: Int

    // MARK: - Stats (classified cells only — `now` and `future` excluded)

    var focusCells: Int { cells.filter { $0 == .focus }.count }
    var driftCells: Int { cells.filter { $0 == .drift }.count }
    var otherCells: Int { cells.filter { $0 == .other }.count }
    var classifiedCells: Int { focusCells + driftCells + otherCells }

    /// The focus rate in whole percent: other cells don't count.
    var focusPercent: Int {
        FocusRate.percent(focused: Double(focusCells), drifted: Double(driftCells))
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
    ) -> SessionTimeline {
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
        return SessionTimeline(cells: cells, minutesPerCell: minutesPerCell)
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

extension SessionTimeline {
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

// MARK: - Ring geometry

extension SessionTimeline {
    enum Kind: Equatable {
        case focus, drift, other

        init(_ classification: Classification) {
            switch classification {
            case .focus:       self = .focus
            case .distraction: self = .drift
            case .neutral:     self = .other
            }
        }
    }

    /// One coloured arc of the ring, in degrees clockwise from 12 o'clock.
    struct RingSegment: Equatable {
        let kind: Kind
        let start: Double
        let end: Double
        /// The timeline cells this arc covers — how a hovered arc is traced
        /// back to the activity behind it.
        var cells: Range<Int> = 0..<0
    }

    /// Arcs for the ring. Consecutive cells of the same kind merge into one
    /// arc, with a small gap between arcs of different kinds.
    ///
    /// - Parameter progress: live sessions pass how far through the timeline
    ///   they are (0...1); the `now` cell's arc stops there and the knob sits
    ///   on it. Finished sessions pass nil and the ring closes, gap included.
    func ringSegments(progress: Double?, gapDegrees: Double = 1.6) -> [RingSegment] {
        guard !cells.isEmpty else { return [] }
        let per = 360.0 / Double(cells.count)
        var raw: [RingSegment] = []
        for (index, cell) in cells.enumerated() {
            let start = Double(index) * per
            let kind: Kind
            var end = start + per
            switch cell {
            case .focus: kind = .focus
            case .drift: kind = .drift
            case .other: kind = .other
            case .now(let classification):
                kind = Kind(classification)
                if let progress { end = min(end, max(start, progress * 360)) }
            case .future:
                continue
            }
            if let last = raw.last, last.kind == kind, abs(last.end - start) < 0.001 {
                raw[raw.count - 1] = RingSegment(kind: kind, start: last.start, end: end,
                                                 cells: last.cells.lowerBound..<(index + 1))
            } else {
                raw.append(RingSegment(kind: kind, start: start, end: end, cells: index..<(index + 1)))
            }
        }

        let closed = progress == nil
        let half = gapDegrees / 2
        return raw.enumerated().compactMap { index, segment in
            let start = segment.start + ((index > 0 || closed) ? half : 0)
            let end = segment.end - ((index < raw.count - 1 || closed) ? half : 0)
            guard end > start else { return nil }
            return RingSegment(kind: segment.kind, start: start, end: min(end, start + 359.9), cells: segment.cells)
        }
    }

    /// Fraction of the timeline that has elapsed, for the ring's knob.
    static func progress(elapsed: TimeInterval, timeline: SessionTimeline) -> Double {
        let total = Double(timeline.cells.count * timeline.minutesPerCell) * 60
        guard total > 0 else { return 0 }
        return min(1, max(0, elapsed / total))
    }
}

// MARK: - What happened in a stretch

extension SessionTimeline {
    /// One app or site inside a stretch of the ring.
    struct StretchApp: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let seconds: TimeInterval
        let classification: Classification
    }

    /// A hovered arc of the ring: when it was, what kind, and what was used.
    struct Stretch: Equatable {
        let kind: Kind
        let start: Date
        let end: Date
        let minutes: Int
        let apps: [StretchApp]
        /// The arc reaches the minute in progress.
        let includesNow: Bool
    }

    /// Summarises the activity behind `cells`. Cells spread tracked time
    /// evenly (see `classify`), so this walks the same cumulative tracked
    /// time to find which events — and which wall-clock span — they cover.
    static func stretch(cells: Range<Int>, kind: Kind, in timeline: SessionTimeline,
                        events: [ActivityEvent], now: Date = .now) -> Stretch? {
        let sorted = events.sorted { $0.startedAt < $1.startedAt }
        let lengths = sorted.map { max(0, $0.duration) + 1 }
        let total = lengths.reduce(0, +)
        let done = timeline.classifiedCells
        guard total > 0, !cells.isEmpty else { return nil }

        let slice = done > 0 ? total / Double(done) : total
        let includesNow = cells.upperBound > done
        // Tracked time is spread over the finished cells only, so the minute
        // in progress has none of its own — show the latest minute instead.
        let latest = max(0, total - Double(timeline.minutesPerCell) * 60)
        let lo = includesNow ? min(Double(cells.lowerBound) * slice, latest)
                             : Double(cells.lowerBound) * slice
        let hi = includesNow ? total : Double(cells.upperBound) * slice
        guard hi > lo || includesNow else { return nil }

        var cursor: TimeInterval = 0
        var start: Date?
        var end: Date?
        var tally: [String: (seconds: TimeInterval, classification: Classification)] = [:]
        for (event, length) in zip(sorted, lengths) {
            let a = cursor, b = cursor + length
            cursor = b
            let overlap = min(b, hi) - max(a, lo)
            guard overlap > 0 else { continue }
            if start == nil { start = event.startedAt.addingTimeInterval(max(0, lo - a)) }
            end = event.startedAt.addingTimeInterval(min(b, hi) - a)
            let host = event.url.flatMap { URL(string: $0)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            let name = host ?? event.appName
            let previous = tally[name]?.seconds ?? 0
            tally[name] = (previous + overlap, event.classification ?? .neutral)
        }
        guard let first = start ?? sorted.last?.endedAt else { return nil }
        let last = includesNow ? now : (end ?? first)

        let apps = tally
            .map { StretchApp(name: $0.key, seconds: $0.value.seconds, classification: $0.value.classification) }
            .sorted { $0.seconds > $1.seconds }
        return Stretch(
            kind: kind,
            start: first,
            end: max(first, last),
            minutes: max(1, Int(((hi - lo) / 60).rounded())),
            apps: Array(apps.prefix(3)),
            includesNow: includesNow
        )
    }
}
