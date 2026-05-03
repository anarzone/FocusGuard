import SwiftUI
import Charts

struct TimelinePoint: Identifiable {
    let id = UUID()
    let minute: Int
    let focus: Double
    let neutral: Double
    let distraction: Double
}

/// Stacked time-series bar chart on Apple Charts. We bucket the per-minute
/// series and use a CATEGORICAL x axis (one slot per bucket, identified by a
/// stable string key). Categorical x is the only mode where Charts both
/// (a) gives bars proper slot widths and (b) auto-stacks BarMarks that share
/// the same x value and are categorized via foregroundStyle(by:). Quantitative
/// (Int / Double) x values produced zero-width bars.
struct FocusTimelineChart: View {
    let series: [TimelinePoint]

    private struct Stack: Identifiable {
        let id = UUID()
        let slot: String      // categorical x — stable per bucket
        let bucketStart: Int  // minutes from range start (used to build labels)
        let category: String
        let seconds: Double
    }

    // MARK: - Bucketing

    /// Aim for ~50 bars across the chart so they're wide enough to read.
    private var bucketMinutes: Int {
        let target = max(1, series.count / 50)
        let snaps = [1, 5, 10, 15, 30, 60, 120, 240, 480, 720, 1440]
        return snaps.first(where: { $0 >= target }) ?? snaps.last!
    }

    private var stacks: [Stack] {
        guard !series.isEmpty else { return [] }
        let width = bucketMinutes
        var out: [Stack] = []
        var i = 0
        while i < series.count {
            let end = min(i + width, series.count)
            var f: Double = 0, n: Double = 0, d: Double = 0
            for j in i..<end {
                f += series[j].focus * 60
                n += series[j].neutral * 60
                d += series[j].distraction * 60
            }
            // Stable, sortable slot key — Charts keeps categorical order in
            // insertion order when we build the array linearly.
            let slot = String(format: "%06d", i)
            // Order is the bottom-to-top stack order.
            if f > 0 { out.append(Stack(slot: slot, bucketStart: i, category: "Focus",       seconds: f)) }
            if n > 0 { out.append(Stack(slot: slot, bucketStart: i, category: "Neutral",     seconds: n)) }
            if d > 0 { out.append(Stack(slot: slot, bucketStart: i, category: "Distraction", seconds: d)) }
            i = end
        }
        return out
    }

    /// Slots in display order — used for the X domain so we get every bucket
    /// shown even if it has zero seconds.
    private var allSlots: [String] {
        guard !series.isEmpty else { return [] }
        var out: [String] = []
        var i = 0
        while i < series.count {
            out.append(String(format: "%06d", i))
            i += bucketMinutes
        }
        return out
    }

    /// Subset of slots that should display an x-axis label, with the label
    /// value (formatted minute → hour string).
    private var labeledSlots: [(slot: String, label: String)] {
        let total = max(1, series.count)
        let target = max(1, total / 7)
        let snaps = [60, 120, 180, 360, 720, 1440, 2880, 4320, 10080]
        let strideMin = snaps.first(where: { $0 >= target }) ?? snaps.last!
        let strideBuckets = max(1, strideMin / bucketMinutes)
        var out: [(String, String)] = []
        for (idx, slot) in allSlots.enumerated() where idx % strideBuckets == 0 {
            let minute = idx * bucketMinutes
            out.append((slot, formatX(minute)))
        }
        return out
    }

    // MARK: - View

    var body: some View {
        if series.isEmpty {
            empty
        } else {
            chart
        }
    }

    private var empty: some View {
        HStack {
            Spacer()
            Text("No activity in this range")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 40)
    }

    private var chart: some View {
        Chart(stacks) { s in
            BarMark(
                x: .value("Time", s.slot),
                y: .value("Seconds", s.seconds)
            )
            .foregroundStyle(by: .value("Category", s.category))
            .cornerRadius(1.5)
        }
        .chartForegroundStyleScale([
            "Focus":       Theme.focus,
            "Neutral":     Theme.neutral.opacity(0.6),
            "Distraction": Theme.distraction,
        ])
        .chartXScale(domain: allSlots)
        .chartXAxis {
            AxisMarks(values: labeledSlots.map(\.slot)) { v in
                AxisGridLine().foregroundStyle(Theme.separator.opacity(0.5))
                AxisTick().foregroundStyle(Theme.separator.opacity(0.5))
                AxisValueLabel {
                    if let slot = v.as(String.self),
                       let label = labeledSlots.first(where: { $0.slot == slot })?.label {
                        Text(label)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Theme.separator.opacity(0.5))
                AxisValueLabel {
                    if let s = v.as(Double.self) {
                        Text(formatY(s))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    // MARK: - Formatting

    private func formatX(_ minute: Int) -> String {
        if series.count <= 60 * 36 {
            // Single-day range — clock-style hour labels.
            if minute == 0 { return "0h" }
            if minute % 60 == 0 { return "\(minute / 60)h" }
            let h = minute / 60
            let r = minute % 60
            return "\(h):\(String(format: "%02d", r))"
        }
        // Multi-day range — collapse to day index.
        let day = minute / (60 * 24) + 1
        return "d\(day)"
    }

    private func formatY(_ seconds: Double) -> String {
        let m = seconds / 60
        if m >= 60 { return String(format: "%.0fh", m / 60) }
        return "\(Int(m.rounded()))m"
    }
}
