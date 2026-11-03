import Foundation

/// One place in a stretch of lost focus, for its row and the top site.
struct AnalyzerPlace: Equatable, Sendable {
    let name: String
    let target: String
    let isSite: Bool
    let bundleId: String?
    let isDistraction: Bool
    var seconds: TimeInterval
}

/// A stretch of lost focus during working time. Real events: its times and
/// places are what was tracked. Window titles are never read.
struct AnalyzerLoss: Equatable, Sendable {
    let start: Date
    let end: Date
    /// The time in it that was tracked, counted once.
    let seconds: TimeInterval
    /// Set by rule; nil until the period's late-day pattern is known, and
    /// after that if nothing explains it.
    var cause: AnalyzerCause?
    let switches: Int
    /// Most time first.
    let places: [AnalyzerPlace]
    /// It starts in the late part of its day.
    var isLate = false

    /// Who to name on its row: site names from an app the person opted out of
    /// are dropped. There's no title here to show: rows are apps and sites only.
    func placeNames(optedOut: Set<String>, limit: Int = 4) -> [String] {
        places.filter { place in
            !(place.isSite && place.bundleId.map(optedOut.contains) == true)
        }.prefix(limit).map(\.name)
    }
}

/// A finished session, for "sessions with a goal against those without".
struct AnalyzerSessionStat: Equatable, Sendable {
    let hasGoal: Bool
    let longest: TimeInterval
}

/// One day's attention, worked out once from its events. Finished days don't
/// change, so `StatsStore` keeps these.
struct AnalyzerDay: Equatable, Sendable {
    let day: Date
    var tracked: TimeInterval = 0
    var focused: TimeInterval = 0
    /// Time in calls and calendar events, counted once, and its share of the
    /// time tracked or booked.
    var callSeconds: TimeInterval = 0
    var callShare = 0.0
    var longest: TimeInterval = 0
    var deepBlocks = 0
    /// How long each return took, calls and time away left out.
    var returns: [TimeInterval] = []
    var gettingStarted: TimeInterval?
    var losses: [AnalyzerLoss] = []
    var sessions: [AnalyzerSessionStat] = []
    /// Focused and lost time on each side of where the day's late part starts.
    var earlyFocus: TimeInterval = 0
    var earlyLost: TimeInterval = 0
    var lateFocus: TimeInterval = 0
    var lateLost: TimeInterval = 0

    var isCallHeavy: Bool { callShare >= AnalyzerRules.callHeavyShare }

    /// Days off aren't working days: too little tracked or focused, or a
    /// weekend when weekends don't count.
    func isWorking(weekendsCount: Bool, calendar: Calendar) -> Bool {
        tracked >= AnalyzerRules.workingDayTracked && focused >= AnalyzerRules.workingDayFocus
            && (weekendsCount || !calendar.isDateInWeekend(day))
    }

    /// Whether an experiment can count this day.
    func countsForExperiment(weekendsCount: Bool, calendar: Calendar) -> Bool {
        isWorking(weekendsCount: weekendsCount, calendar: calendar) && !isCallHeavy
    }
}

/// Works out a day from its events.
///
/// A day's tracked time falls into exactly one of: a focused stretch, a call,
/// or lost focus. Churn, rapid switching across three or more apps, breaks a
/// stretch even when each app is "focus" on its own; that's what lets the same
/// time never count as both focused and lost. A stretch running over midnight
/// is cut there, each side counting for its own day.
enum AnalyzerDayBuilder {
    /// One run in one app.
    struct Segment: Equatable {
        var start: Date
        var end: Date
        let kind: Classification
        let target: String
        let name: String
        let isSite: Bool
        let bundleId: String?
        var isCall: Bool
        var isMessaging: Bool

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    struct Stretch: Equatable {
        var start: Date
        var end: Date
        var focused: TimeInterval
    }

    static func make(day: Date, events: [CoachEvent], sessions: [CoachSession] = [], busy: [DateInterval] = [],
                     calendar: Calendar = .current) -> AnalyzerDay {
        let span = DateInterval(start: day, end: calendar.startOfDay(1, from: day))
        let segments = self.segments(events, in: span)
        var result = AnalyzerDay(day: day)
        guard !segments.isEmpty else { return result }
        let busy = busy.compactMap { $0.intersection(with: span) }.sorted { $0.start < $1.start }

        result.tracked = segments.reduce(0) { $0 + $1.duration }
        result.focused = segments.filter { $0.kind == .focus && !$0.isCall }.reduce(0) { $0 + $1.duration }
        let callSpans = merged(segments.filter(\.isCall).map { DateInterval(start: $0.start, end: $0.end) } + busy)
        result.callSeconds = callSpans.reduce(0) { $0 + $1.duration }
        let booked = CoachData.covered(segments.map { DateInterval(start: $0.start, end: $0.end) } + busy)
        result.callShare = booked > 0 ? result.callSeconds / booked : 0

        let inChurn = Set(churnRuns(segments).flatMap { Array($0) })
        let stretches = self.stretches(segments, churn: inChurn)
        result.longest = stretches.map(\.focused).max() ?? 0
        result.deepBlocks = stretches.filter { $0.focused >= AnalyzerRules.deepBlock }.count
        result.sessions = sessionStats(sessions, events: events, span: span)

        let solid = stretches.filter { $0.focused >= AnalyzerRules.solidStretch }
        guard let first = solid.first, let last = solid.last else { return result }
        let sitDown = sitDown(before: first.start, segments)

        // Time before the first focus, then between focused stretches. After
        // the last one the working day is over: the evening's browsing isn't
        // lost focus.
        var spans = [DateInterval]()
        if sitDown < first.start { spans.append(DateInterval(start: sitDown, end: first.start)) }
        for (before, after) in zip(solid, solid.dropFirst()) {
            spans.append(DateInterval(start: before.end, end: after.start))
            if isReturn(from: before.end, to: after.start, segments: segments, busy: busy) {
                result.returns.append(after.start.timeIntervalSince(before.end))
            }
        }
        // Work carried over from yesterday isn't a start.
        let carriedOver = (events.map(\.start).min() ?? span.end) <= span.start
        if !carriedOver {
            let callsBefore = callSpans.reduce(0.0) { total, call in
                total + (call.intersection(with: DateInterval(start: sitDown, end: first.start))?.duration ?? 0)
            }
            result.gettingStarted = max(0, first.start.timeIntervalSince(sitDown) - callsBefore)
        }

        let lateFrom = sitDown.addingTimeInterval(last.end.timeIntervalSince(sitDown) * AnalyzerRules.lateDayShare)
        for (index, segment) in segments.enumerated()
        where segment.kind == .focus && !segment.isCall && !inChurn.contains(index)
            && solid.contains(where: { $0.start <= segment.start && segment.end <= $0.end }) {
            result.earlyFocus += max(0, min(segment.end, lateFrom).timeIntervalSince(segment.start))
            result.lateFocus += max(0, segment.end.timeIntervalSince(max(segment.start, lateFrom)))
        }

        for span in spans {
            for slices in pieces(in: span, segments: segments, busy: busy) {
                let seconds = slices.reduce(0) { $0 + $1.duration }
                guard seconds >= AnalyzerRules.shortestLoss, let start = slices.first?.start, let end = slices.last?.end else { continue }
                result.losses.append(AnalyzerLoss(
                    start: start, end: end, seconds: seconds,
                    cause: cause(slices, start: start, end: end, segments: segments, callSpans: callSpans, churn: inChurn),
                    switches: switchCount(slices), places: places(slices), isLate: start >= lateFrom))
                for slice in slices {
                    result.earlyLost += max(0, min(slice.end, lateFrom).timeIntervalSince(slice.start))
                    result.lateLost += max(0, slice.end.timeIntervalSince(max(slice.start, lateFrom)))
                }
            }
        }
        return result
    }

    // MARK: Segments

    /// Events cut to the day, overlaps counted once, and runs in one app put
    /// together. Teams is both: under 5 minutes it's chat, longer a call.
    static func segments(_ events: [CoachEvent], in span: DateInterval) -> [Segment] {
        var out: [Segment] = []
        var cursor = span.start
        for event in events.sorted(by: { $0.start < $1.start }) {
            let start = max(event.start, cursor), end = min(event.end, span.end)
            guard end > start else { continue }
            cursor = end
            if let last = out.last, last.target == event.target, last.kind == event.kind,
               start.timeIntervalSince(last.end) <= AnalyzerRules.sameEventGap {
                out[out.count - 1].end = end
            } else {
                out.append(Segment(start: start, end: end, kind: event.kind, target: event.target, name: event.name,
                                   isSite: event.isSite, bundleId: event.bundleId, isCall: event.isCall,
                                   isMessaging: AnalyzerApps.isMessaging(target: event.target, isSite: event.isSite)))
            }
        }
        for index in out.indices where out[index].isCall && out[index].isMessaging {
            if out[index].duration < AnalyzerRules.shortestCall {
                out[index].isCall = false
            } else {
                out[index].isMessaging = false
            }
        }
        return out
    }

    /// Runs of rapid switching: indexes into `segments`. Messages, distractions
    /// and calls have rules of their own, so they end a run.
    static func churnRuns(_ segments: [Segment]) -> [Range<Int>] {
        func qualifies(_ segment: Segment) -> Bool {
            !segment.isCall && !segment.isMessaging && segment.kind != .distraction
                && segment.duration <= AnalyzerRules.churnDwell
        }
        var runs: [Range<Int>] = []
        var index = 0
        while index < segments.count {
            guard qualifies(segments[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < segments.count, qualifies(segments[end]),
                  segments[end].start.timeIntervalSince(segments[end - 1].end) <= AnalyzerRules.stretchGrace {
                end += 1
            }
            let run = index..<end
            let seconds = segments[end - 1].end.timeIntervalSince(segments[index].start)
            if seconds >= AnalyzerRules.churnMinimum,
               Double(run.count - 1) / (seconds / 60) >= AnalyzerRules.churnSwitchesPerMinute,
               Set(run.map { segments[$0].target }).count >= AnalyzerRules.churnApps {
                runs.append(run)
            }
            index = end
        }
        return runs
    }

    /// Focused time with no break over the grace. A call or churn long enough
    /// to matter is longer than the grace, so it ends one.
    static func stretches(_ segments: [Segment], churn: Set<Int>) -> [Stretch] {
        var out: [Stretch] = []
        for (index, segment) in segments.enumerated() where segment.kind == .focus && !segment.isCall && !churn.contains(index) {
            if let last = out.last, segment.start.timeIntervalSince(last.end) <= AnalyzerRules.stretchGrace {
                out[out.count - 1].end = segment.end
                out[out.count - 1].focused += segment.duration
            } else {
                out.append(Stretch(start: segment.start, end: segment.end, focused: segment.duration))
            }
        }
        return out
    }

    /// The first activity of the day, calls left out, after any long gap
    /// before the first focus.
    private static func sitDown(before first: Date, _ segments: [Segment]) -> Date {
        var cursor = first, sitDown = first
        for segment in segments.reversed() where segment.start < first {
            if cursor.timeIntervalSince(segment.end) >= AnalyzerRules.sitDownGap { break }
            cursor = segment.start
            if !segment.isCall { sitDown = segment.start }
        }
        return sitDown
    }

    /// A return, as Pick up counts one: no call and no time away on the way,
    /// and long enough to have been a drift.
    private static func isReturn(from start: Date, to end: Date, segments: [Segment], busy: [DateInterval]) -> Bool {
        guard end.timeIntervalSince(start) >= AnalyzerRules.shortestLoss else { return false }
        let span = DateInterval(start: start, end: end)
        guard !busy.contains(where: { ($0.intersection(with: span)?.duration ?? 0) > 0 }) else { return false }
        var cursor = start
        for segment in segments where segment.end > start && segment.start < end {
            if segment.isCall || segment.start.timeIntervalSince(cursor) >= AnalyzerRules.awayGap { return false }
            cursor = segment.end
        }
        return end.timeIntervalSince(cursor) < AnalyzerRules.awayGap
    }

    // MARK: Lost focus

    /// A piece of a segment that's lost focus.
    struct Slice: Equatable {
        let index: Int
        let start: Date
        let end: Date
        let source: Segment

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The tracked time in `span`, split at calls, calendar events and time away.
    private static func pieces(in span: DateInterval, segments: [Segment], busy: [DateInterval]) -> [[Slice]] {
        var out: [[Slice]] = []
        var current: [Slice] = []
        func flush() {
            if !current.isEmpty { out.append(current) }
            current = []
        }
        for (index, segment) in segments.enumerated() where segment.end > span.start && segment.start < span.end {
            guard !segment.isCall else {
                flush()
                continue
            }
            let clip = DateInterval(start: max(segment.start, span.start), end: min(segment.end, span.end))
            for part in subtract(busy, from: clip) {
                if let last = current.last {
                    let gap = DateInterval(start: last.end, end: max(last.end, part.start))
                    if gap.duration >= AnalyzerRules.awayGap || busy.contains(where: { ($0.intersection(with: gap)?.duration ?? 0) > 0 }) {
                        flush()
                    }
                }
                current.append(Slice(index: index, start: part.start, end: part.end, source: segment))
            }
        }
        flush()
        return out
    }

    private static func subtract(_ spans: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        var out: [DateInterval] = []
        var cursor = interval.start
        for span in spans where span.end > interval.start && span.start < interval.end {
            if span.start > cursor { out.append(DateInterval(start: cursor, end: span.start)) }
            cursor = max(cursor, span.end)
        }
        if cursor < interval.end { out.append(DateInterval(start: cursor, end: interval.end)) }
        return out
    }

    /// Exactly one cause, by rule, tried in order. Nil: nothing here explains
    /// it, which the period's late-day pattern may still.
    private static func cause(_ slices: [Slice], start: Date, end: Date, segments: [Segment], callSpans: [DateInterval],
                              churn: Set<Int>) -> AnalyzerCause? {
        if let before = callSpans.last(where: { $0.end <= start }),
           let after = callSpans.first(where: { $0.start >= end }),
           after.start.timeIntervalSince(before.end) < AnalyzerRules.deepBlock {
            return .meetings
        }
        let lead = AnalyzerRules.messageLead
        if segments.contains(where: {
            $0.isMessaging && $0.end >= start.addingTimeInterval(-lead) && $0.start <= start.addingTimeInterval(lead)
        }) {
            return .chatAndMail
        }
        if slices.contains(where: { $0.source.kind == .distraction }) { return .habit }
        let seconds = slices.reduce(0) { $0 + $1.duration }
        let churning = slices.filter { churn.contains($0.index) }.reduce(0) { $0 + $1.duration }
        if seconds > 0, churning / seconds >= AnalyzerRules.churnShare { return .unclearTask }
        return nil
    }

    private static func switchCount(_ slices: [Slice]) -> Int {
        zip(slices, slices.dropFirst()).filter { $0.source.target != $1.source.target }.count
    }

    private static func places(_ slices: [Slice]) -> [AnalyzerPlace] {
        var out: [AnalyzerPlace] = []
        for slice in slices {
            if let index = out.firstIndex(where: { $0.target == slice.source.target }) {
                out[index].seconds += slice.duration
            } else {
                out.append(AnalyzerPlace(name: slice.source.name, target: slice.source.target, isSite: slice.source.isSite,
                                         bundleId: slice.source.bundleId, isDistraction: slice.source.kind == .distraction,
                                         seconds: slice.duration))
            }
        }
        return out.sorted { $0.seconds > $1.seconds }
    }

    // MARK: Sessions

    private static func sessionStats(_ sessions: [CoachSession], events: [CoachEvent], span: DateInterval) -> [AnalyzerSessionStat] {
        sessions.filter { span.start <= $0.start && $0.start < span.end }.map { session in
            let own = segments(events.filter { $0.session == session.id }, in: span)
            let churn = Set(churnRuns(own).flatMap { Array($0) })
            return AnalyzerSessionStat(hasGoal: session.hasGoal, longest: stretches(own, churn: churn).map(\.focused).max() ?? 0)
        }
    }

    private static func merged(_ spans: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, span.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                out.append(span)
            }
        }
        return out
    }
}
