import Foundation

/// Three patterns across the period, each said only once there's enough to
/// say it: when sessions break, the best hours, and getting back after a call.
struct AnalyzerPatterns: Equatable, Sendable {
    /// Sessions whose first drift came in each 5-minute slice of the first hour.
    var breaks: [Int] = Array(repeating: 0, count: 12)
    var sessionsWithBreak = 0
    /// Focus rate (0–1) in each hour from `firstHour` on, nil with too little tracked.
    var hourRates: [Double?] = []
    /// Median minutes back to work after a call, and after a drift.
    var afterCall: TimeInterval?
    var afterDrift: TimeInterval?
    var calls = 0

    static let firstHour = 8
    static let lastHour = 19
    /// Sessions that broke, before naming when they break.
    static let enoughBreaks = 10
    /// Tracked time in an hour across the period, before giving it a rate:
    /// a few minutes a working day, not one good morning.
    static let enoughInHour: TimeInterval = 2 * 60 * 60
    static let enoughCalls = 5
    /// A slice is named only when it holds this share of the breaks and is
    /// this many ahead of the next: otherwise there's no one time.
    static let breakShare = 0.25
    static let breakLead = 2
    /// The best hours are named only this far above the day's own rate.
    static let hoursLead = 0.10

    var hasBreaks: Bool { sessionsWithBreak >= Self.enoughBreaks }
    /// The 5-minute slice sessions most often break in, when one stands out.
    var commonBreak: Int? {
        guard hasBreaks, let top = breaks.indices.max(by: { breaks[$0] < breaks[$1] }) else { return nil }
        let next = breaks.indices.filter { $0 != top }.map { breaks[$0] }.max() ?? 0
        let share = Double(breaks[top]) / Double(max(1, sessionsWithBreak))
        return share >= Self.breakShare && breaks[top] - next >= Self.breakLead ? top : nil
    }

    /// Focus rate across every hour with enough tracked.
    var overallRate: Double? {
        let rates = hourRates.compactMap { $0 }
        return rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
    }

    /// The best two hours in a row, when they stand out from the rest of the day.
    var bestHours: (hour: Int, rate: Double)? {
        var best: (Int, Double)?
        for index in hourRates.indices.dropLast() {
            guard let a = hourRates[index], let b = hourRates[index + 1] else { continue }
            let rate = (a + b) / 2
            if best == nil || rate > best!.1 { best = (Self.firstHour + index, rate) }
        }
        guard let best, let overall = overallRate, best.1 - overall >= Self.hoursLead else { return nil }
        return best
    }

    static func make(_ days: [AnalyzerDay]) -> AnalyzerPatterns {
        var patterns = AnalyzerPatterns()
        for session in days.flatMap(\.sessions) {
            guard let brokeAt = session.brokeAt, brokeAt < 3600 else { continue }
            patterns.breaks[min(11, Int(brokeAt / 300))] += 1
            patterns.sessionsWithBreak += 1
        }
        patterns.hourRates = (firstHour..<lastHour).map { hour in
            let tracked = days.reduce(0) { $0 + ($1.hourTracked[hour] ?? 0) }
            guard tracked >= enoughInHour else { return nil }
            return days.reduce(0) { $0 + ($1.hourFocus[hour] ?? 0) } / tracked
        }
        let calls = days.flatMap(\.afterCalls)
        patterns.calls = calls.count
        patterns.afterCall = calls.count >= enoughCalls ? median(calls) : nil
        patterns.afterDrift = median(days.flatMap(\.returns))
        return patterns
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
