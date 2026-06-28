import Foundation

/// Builds the compact text summary of the user's focus data that is sent to the
/// LLM. This is the **single source of truth for what leaves the device** — the
/// "what gets sent" disclosure in Settings renders the exact same string. It is
/// intentionally a pure function of already-aggregated values (no SwiftData, no
/// window titles, no raw URLs — only hostnames/app names + numbers) so it is
/// trivially unit-testable and auditable.
enum FocusSummaryBuilder {
    struct Inputs {
        var rangeLabel: String
        var breakdown: BreakdownSnapshot
        var distractions: [DistractionEntry]
        var currentStreak: Int
        var weeklyAverageFocusSeconds: TimeInterval
    }

    static func summary(_ input: Inputs) -> String {
        let b = input.breakdown
        var lines: [String] = []
        lines.append("Focus report — \(input.rangeLabel)")
        lines.append("Focus: \(minutes(b.focus)) min (\(percent(b.focusPercent)))")
        lines.append("Neutral: \(minutes(b.neutral)) min")
        lines.append("Distraction: \(minutes(b.distraction)) min")
        lines.append("Tracked total: \(minutes(b.total)) min")
        lines.append("Current focus streak: \(input.currentStreak) day\(input.currentStreak == 1 ? "" : "s")")
        lines.append("7-day average focus: \(minutes(input.weeklyAverageFocusSeconds)) min/day")

        if input.distractions.isEmpty {
            lines.append("")
            lines.append("Top distractions: none recorded.")
        } else {
            lines.append("")
            lines.append("Top distractions:")
            for (i, d) in input.distractions.enumerated() {
                lines.append("\(i + 1). \(d.name) — \(minutes(d.seconds)) min (\(percent(d.fractionOfTotal)) of distraction time)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func minutes(_ seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded())
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
