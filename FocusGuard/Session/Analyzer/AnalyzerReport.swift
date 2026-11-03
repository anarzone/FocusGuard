import Foundation

/// Four numbers for a typical working day: medians, days with heavy calls and
/// calls themselves left out.
struct AnalyzerMeasures: Equatable, Sendable {
    var days = 0
    var longest: TimeInterval?
    var deepBlocks: Double?
    /// Nil until there are enough returns or mornings to say.
    var comingBack: TimeInterval?
    var gettingStarted: TimeInterval?

    static func make(_ days: [AnalyzerDay]) -> AnalyzerMeasures {
        let clear = days.filter { !$0.isCallHeavy }
        var out = AnalyzerMeasures(days: clear.count)
        out.longest = AnalyzerMath.median(clear.map(\.longest))
        out.deepBlocks = AnalyzerMath.median(clear.map { Double($0.deepBlocks) })
        if clear.reduce(0, { $0 + $1.returns.count }) >= AnalyzerRules.enoughReturns {
            out.comingBack = AnalyzerMath.median(clear.compactMap { AnalyzerMath.median($0.returns) })
        }
        let starts = clear.compactMap(\.gettingStarted)
        if starts.count >= AnalyzerRules.enoughStarts { out.gettingStarted = AnalyzerMath.median(starts) }
        return out
    }
}

/// A row in "Why focus gets lost". `cause` nil is "Couldn't tell": lost time
/// no rule explains, which is never named.
struct AnalyzerCauseRow: Equatable, Sendable, Identifiable {
    let cause: AnalyzerCause?
    /// All of it, counted once across rows.
    var seconds: TimeInterval = 0
    /// Over all working days: "about 1h 10m a day".
    var perDay: TimeInterval = 0
    var episodes = 0
    var daysSeen = 0
    /// Whether it may be named: enough time, on enough days, enough times.
    var isSteady = false
    /// The person said it's not this.
    var isMuted = false

    var id: String { cause?.rawValue ?? "unsure" }
}

/// What the page says about why.
enum AnalyzerFinding: Equatable, Sendable {
    /// Under 7 working days: this many to go.
    case learning(daysLeft: Int)
    case named(AnalyzerCause)
    /// The top two are too close to pick one.
    case tooClose(AnalyzerCause, AnalyzerCause)
    /// Nothing steady enough or big enough to name.
    case nothingClear
}

struct AnalyzerGoalSide: Equatable, Sendable {
    let longest: TimeInterval
    let count: Int
}

/// What's behind a cause, from real events.
struct AnalyzerCauseDetail: Equatable, Sendable {
    var row: AnalyzerCauseRow
    /// The longest times it happened, newest first among equals.
    var examples: [AnalyzerLoss] = []
    /// Only from enough sessions on both sides.
    var withGoal: AnalyzerGoalSide?
    var withoutGoal: AnalyzerGoalSide?
    /// The top distraction, and its time a day, for a limit.
    var topDistraction: AnalyzerPlace?
    var topDistractionPerDay: TimeInterval = 0
    /// The message app these stretches most often held.
    var topMessageApp: String?
    var sessions = 0
    var goallessSessions = 0
    /// Focus rate before and after the day's late part starts.
    var earlyRate: Double?
    var lateRate: Double?
}

/// The Analyzer page's facts, as plain values, worked out off the main thread.
struct AnalyzerReport: Equatable, Sendable {
    var period: DateInterval
    var workingDays = 0
    var measures = AnalyzerMeasures()
    /// The equal period before, only when both have enough days.
    var previous: AnalyzerMeasures?
    var rows: [AnalyzerCauseRow] = []
    var finding: AnalyzerFinding
    var details: [AnalyzerCause: AnalyzerCauseDetail] = [:]

    /// Everything from the rules: `days` and `before` are the period's and the
    /// one before's days with anything tracked, `muted` what the person ruled out.
    static func make(period: DateInterval, days: [AnalyzerDay], before: [AnalyzerDay], muted: Set<AnalyzerCause>,
                     weekendsCount: Bool, calendar: Calendar = .current) -> AnalyzerReport {
        let working = days.filter { $0.isWorking(weekendsCount: weekendsCount, calendar: calendar) }.sorted { $0.day < $1.day }
        let earlier = before.filter { $0.isWorking(weekendsCount: weekendsCount, calendar: calendar) }
        var report = AnalyzerReport(period: period, workingDays: working.count,
                                    measures: AnalyzerMeasures.make(working),
                                    finding: .learning(daysLeft: max(0, AnalyzerRules.namingDays - working.count)))
        if working.count >= AnalyzerRules.compareDays, earlier.count >= AnalyzerRules.compareDays {
            report.previous = AnalyzerMeasures.make(earlier)
        }
        guard working.count >= AnalyzerRules.namingDays else { return report }

        let labelled = label(working)
        report.rows = rows(labelled, muted: muted)
        report.finding = finding(report.rows, workingDays: labelled.count)
        for row in report.rows {
            guard let cause = row.cause else { continue }
            report.details[cause] = detail(row, days: labelled)
        }
        return report
    }

    // MARK: The rules

    /// Late-day time nothing else explains becomes a late-day dip, but only
    /// where the period shows that pattern against the person's own earlier hours.
    static func label(_ days: [AnalyzerDay]) -> [AnalyzerDay] {
        guard hasLateDayDip(days) else { return days }
        return days.map { day in
            var day = day
            guard !day.isCallHeavy else { return day }
            for index in day.losses.indices where day.losses[index].cause == nil && day.losses[index].isLate {
                day.losses[index].cause = .tiredness
            }
            return day
        }
    }

    static func hasLateDayDip(_ days: [AnalyzerDay]) -> Bool {
        let measured = days.filter {
            !$0.isCallHeavy && $0.earlyFocus + $0.earlyLost >= AnalyzerRules.lateDaySideMinimum
                && $0.lateFocus + $0.lateLost >= AnalyzerRules.lateDaySideMinimum
        }
        guard measured.count >= AnalyzerRules.lateDayDays else { return false }
        func rate(_ focus: TimeInterval, _ lost: TimeInterval) -> Double { focus + lost > 0 ? focus / (focus + lost) : 0 }
        let early = rate(measured.reduce(0) { $0 + $1.earlyFocus }, measured.reduce(0) { $0 + $1.earlyLost })
        let late = rate(measured.reduce(0) { $0 + $1.lateFocus }, measured.reduce(0) { $0 + $1.lateLost })
        let lower = measured.filter { rate($0.lateFocus, $0.lateLost) < rate($0.earlyFocus, $0.earlyLost) }.count
        return early - late >= AnalyzerRules.lateDayDrop
            && Double(lower) / Double(measured.count) >= AnalyzerRules.lateDayLowerShare
    }

    /// One row a cause, most time first, and what's left as "Couldn't tell".
    /// Whether a row is steady counts only days that can speak for it: heavy
    /// call days count for meetings alone.
    static func rows(_ days: [AnalyzerDay], muted: Set<AnalyzerCause>) -> [AnalyzerCauseRow] {
        let causes: [AnalyzerCause?] = AnalyzerCause.allCases + [nil]
        let rows = causes.map { cause -> AnalyzerCauseRow in
            var row = AnalyzerCauseRow(cause: cause)
            var steadySeconds = 0.0, steadyDays = 0, steadyEpisodes = 0
            for day in days {
                let losses = day.losses.filter { $0.cause == cause }
                guard !losses.isEmpty else { continue }
                let seconds = losses.reduce(0) { $0 + $1.seconds }
                row.seconds += seconds
                row.episodes += losses.count
                row.daysSeen += 1
                if cause == .meetings || !day.isCallHeavy {
                    steadySeconds += seconds
                    steadyDays += 1
                    steadyEpisodes += losses.count
                }
            }
            row.perDay = row.seconds / Double(max(1, days.count))
            let base = cause == .meetings ? days.count : days.filter { !$0.isCallHeavy }.count
            if let cause, base > 0 {
                row.isMuted = muted.contains(cause)
                row.isSteady = steadySeconds / Double(base) >= AnalyzerRules.causeDailyMinimum
                    && Double(steadyDays) / Double(base) >= AnalyzerRules.causeDayShare
                    && steadyEpisodes >= AnalyzerRules.causeEpisodes
                    && (cause == .meetings || base >= AnalyzerRules.causeClearDays)
            }
            return row
        }
        return rows.sorted { a, b in
            if (a.cause == nil) != (b.cause == nil) { return b.cause == nil }
            return a.seconds > b.seconds
        }
    }

    /// Names a cause only when it's steady, not ruled out by the person, and
    /// clearly ahead of every other, "Couldn't tell" included.
    static func finding(_ rows: [AnalyzerCauseRow], workingDays: Int) -> AnalyzerFinding {
        guard workingDays >= AnalyzerRules.namingDays else {
            return .learning(daysLeft: AnalyzerRules.namingDays - workingDays)
        }
        let open = rows.filter { $0.cause != nil && !$0.isMuted }.sorted { $0.perDay > $1.perDay }
        guard let top = open.first, let cause = top.cause, top.isSteady else { return .nothingClear }
        let unsure = rows.first { $0.cause == nil }?.perDay ?? 0
        guard top.perDay > unsure else { return .nothingClear }
        guard let next = open.dropFirst().first, next.perDay > 0, let second = next.cause else { return .named(cause) }
        let ahead = top.perDay >= next.perDay * AnalyzerRules.causeLead
            && top.perDay - next.perDay >= AnalyzerRules.causeDailyMargin
        return ahead ? .named(cause) : .tooClose(cause, second)
    }

    private static func detail(_ row: AnalyzerCauseRow, days: [AnalyzerDay]) -> AnalyzerCauseDetail {
        guard let cause = row.cause else { return AnalyzerCauseDetail(row: row) }
        var detail = AnalyzerCauseDetail(row: row)
        let losses = days.flatMap { $0.losses.filter { $0.cause == cause } }
        detail.examples = Array(losses.sorted {
            $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.start > $1.start
        }.prefix(3))

        let sessions = days.flatMap(\.sessions)
        let with = sessions.filter(\.hasGoal), without = sessions.filter { !$0.hasGoal }
        detail.sessions = sessions.count
        detail.goallessSessions = without.count
        if with.count >= AnalyzerRules.goalSessions, without.count >= AnalyzerRules.goalSessions,
           let a = AnalyzerMath.median(with.map(\.longest)), let b = AnalyzerMath.median(without.map(\.longest)) {
            detail.withGoal = AnalyzerGoalSide(longest: a, count: with.count)
            detail.withoutGoal = AnalyzerGoalSide(longest: b, count: without.count)
        }

        var seconds: [String: AnalyzerPlace] = [:]
        var messages: [String: Int] = [:]
        for loss in losses {
            for place in loss.places where place.isDistraction {
                if seconds[place.target] == nil { seconds[place.target] = place } else { seconds[place.target]?.seconds += place.seconds }
            }
            if let message = loss.places.first(where: { AnalyzerApps.isMessaging(target: $0.target, isSite: $0.isSite) }) {
                messages[message.name, default: 0] += 1
            }
        }
        if let top = seconds.values.max(by: { $0.seconds != $1.seconds ? $0.seconds < $1.seconds : $0.target > $1.target }) {
            detail.topDistraction = top
            detail.topDistractionPerDay = top.seconds / Double(max(1, days.count))
        }
        detail.topMessageApp = messages.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key

        let clear = days.filter { !$0.isCallHeavy }
        let earlyFocus = clear.reduce(0) { $0 + $1.earlyFocus }, earlyLost = clear.reduce(0) { $0 + $1.earlyLost }
        let lateFocus = clear.reduce(0) { $0 + $1.lateFocus }, lateLost = clear.reduce(0) { $0 + $1.lateLost }
        if earlyFocus + earlyLost > 0, lateFocus + lateLost > 0 {
            detail.earlyRate = earlyFocus / (earlyFocus + earlyLost)
            detail.lateRate = lateFocus / (lateFocus + lateLost)
        }
        return detail
    }
}
