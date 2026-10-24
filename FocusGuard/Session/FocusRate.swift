import Foundation

/// The focus rate shown everywhere: focused ÷ (focused + drifted).
/// Neutral and other time is left out, so a call or a minute in Finder
/// neither helps nor hurts. Session names are judged on the same rate.
enum FocusRate {
    /// 0...1. Zero when nothing was focused or drifted.
    static func of(focused: TimeInterval, drifted: TimeInterval) -> Double {
        let focused = max(0, focused), counted = focused + max(0, drifted)
        return counted > 0 ? focused / counted : 0
    }

    /// Whole percent, as shown: 87.
    static func percent(focused: TimeInterval, drifted: TimeInterval) -> Int {
        Int((of(focused: focused, drifted: drifted) * 100).rounded())
    }
}

extension BreakdownSnapshot {
    var focusRate: Double { FocusRate.of(focused: focus, drifted: distraction) }
}

extension DailyBreakdown {
    var focusRate: Double { FocusRate.of(focused: focus, drifted: distraction) }
}

extension ReportBucket {
    var focusRate: Double { FocusRate.of(focused: focus, drifted: drift) }
}
