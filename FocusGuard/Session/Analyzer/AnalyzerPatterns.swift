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
    /// Tracked time in an hour across the period, before giving it a rate.
    static let enoughInHour: TimeInterval = 30 * 60
    static let enoughCalls = 3

    var hasBreaks: Bool { sessionsWithBreak >= Self.enoughBreaks }
    /// The 5-minute slice sessions most often break in.
    var commonBreak: Int? { hasBreaks ? breaks.indices.max { breaks[$0] < breaks[$1] } : nil }

    /// The best two hours in a row: their first hour and their rate.
    var bestHours: (hour: Int, rate: Double)? {
        var best: (Int, Double)?
        for index in hourRates.indices.dropLast() {
            guard let a = hourRates[index], let b = hourRates[index + 1] else { continue }
            let rate = (a + b) / 2
            if best == nil || rate > best!.1 { best = (Self.firstHour + index, rate) }
        }
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
