import Foundation

/// A day with time tracked but too little focus to be a working day: what
/// the summaries say about it, for "days that got away".
struct AnalyzerQuietDay: Equatable, Sendable {
    let day: Date
    let tracked: TimeInterval
    let distraction: TimeInterval
}

/// What the causes don't explain: they read only the time between two
/// focused stretches. Distractions right after the last stretch of a day,
/// and days with no focused stretch at all, are lost too.
struct AnalyzerLeftOut: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        let day: Date
        var focused: TimeInterval = 0
        /// Lost between focused stretches: what the causes explain.
        var between: TimeInterval = 0
        /// On distractions after the last stretch, or all day on a day that got away.
        var unseen: TimeInterval = 0
        /// No focused stretch, and enough on distractions.
        var gotAway = false
        /// A weekend that doesn't count, or a day with too little tracked.
        var isOff = true

        var id: Date { day }
    }

    /// Every day of the period, oldest first.
    var days: [Day] = []

    var between: TimeInterval { days.reduce(0) { $0 + $1.between } }
    /// After the last focused stretch, on days that had one.
    var after: TimeInterval { days.filter { !$0.gotAway }.reduce(0) { $0 + $1.unseen } }
    var afterDays: Int { days.filter { !$0.gotAway && $0.unseen > 0 }.count }
    var awayDays: Int { days.filter(\.gotAway).count }
    var away: TimeInterval { days.filter(\.gotAway).reduce(0) { $0 + $1.unseen } }
    var workingDays: Int { days.filter { !$0.isOff && !$0.gotAway }.count }
    var total: TimeInterval { between + after + away }

    var isWorthShowing: Bool {
        after + away >= AnalyzerRules.leftOutMinimum && afterDays + awayDays >= AnalyzerRules.leftOutDays
    }

    /// `days` are the period's days with enough tracked and focused, already
    /// without the lost focus the user said is fine; `quiet` the ones with
    /// time tracked and too little focus.
    static func make(period: DateInterval, days: [AnalyzerDay], quiet: [AnalyzerQuietDay], weekendsCount: Bool,
                     calendar: Calendar = .current) -> AnalyzerLeftOut {
        var out = AnalyzerLeftOut()
        var cursor = calendar.startOfDay(for: period.start)
        while cursor < period.end {
            let date = cursor
            var entry = Day(day: date)
            let counts = weekendsCount || !calendar.isDateInWeekend(date)
            if counts, let day = days.first(where: { calendar.isDate($0.day, inSameDayAs: date) }),
               day.tracked >= AnalyzerRules.workingDayTracked {
                entry.isOff = false
                entry.focused = day.focused
                if day.hasFocus {
                    entry.between = day.losses.reduce(0) { $0 + $1.seconds }
                    entry.unseen = day.afterLast
                } else if day.distraction >= AnalyzerRules.gotAwayMinimum {
                    entry.gotAway = true
                    entry.unseen = day.distraction
                }
            } else if counts, let day = quiet.first(where: { calendar.isDate($0.day, inSameDayAs: date) }),
                      day.tracked >= AnalyzerRules.workingDayTracked, day.distraction >= AnalyzerRules.gotAwayMinimum {
                entry.isOff = false
                entry.gotAway = true
                entry.unseen = day.distraction
            }
            out.days.append(entry)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = calendar.startOfDay(for: next)
        }
        return out
    }
}
