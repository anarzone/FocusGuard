import Foundation

/// (focus, neutral, distraction) durations in seconds. Used by the popover
/// hero, the Reports view, and the EscalationEngine.
struct BreakdownSnapshot: Equatable {
    let focus: TimeInterval
    let neutral: TimeInterval
    let distraction: TimeInterval

    var total: TimeInterval { focus + neutral + distraction }

    var focusPercent: Double {
        total > 0 ? focus / total : 0
    }
}
