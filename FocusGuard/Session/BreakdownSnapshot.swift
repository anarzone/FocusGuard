import Foundation

/// (focus, neutral, distraction) durations in seconds. Used by the popover
/// hero, the Reports view, and the EscalationEngine.
struct BreakdownSnapshot: Equatable {
    let focus: TimeInterval
    let neutral: TimeInterval
    let distraction: TimeInterval

    var total: TimeInterval { focus + neutral + distraction }

    /// The focus rate, 0...1 (see `FocusRate`). The old name, kept for the
    /// screens that still use it.
    var focusPercent: Double { focusRate }
}
