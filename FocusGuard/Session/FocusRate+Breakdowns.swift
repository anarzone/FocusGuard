import Foundation

// `FocusRate` itself lives in FocusGuardShared, so the widgets use it too.

extension BreakdownSnapshot {
    var focusRate: Double { FocusRate.of(focused: focus, drifted: distraction) }
}

extension DailyBreakdown {
    var focusRate: Double { FocusRate.of(focused: focus, drifted: distraction) }
}

extension ReportBucket {
    var focusRate: Double { FocusRate.of(focused: focus, drifted: drift) }
}
