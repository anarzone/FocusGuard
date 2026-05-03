import SwiftUI
import Charts

struct TimelinePoint: Identifiable {
    let id = UUID()
    let minute: Int
    let focus: Double
    let neutral: Double
    let distraction: Double
}

/// Stacked time-series bar chart built on Apple Charts. Buckets the per-minute
/// series into ~60 readable bars across the chart and stacks focus / neutral /
/// distraction within each bar. Replaces the hand-drawn GeometryReader version
/// which rendered as scattered dots when most buckets only had one category.
struct FocusTimelineChart: View {
    let series: [TimelinePoint]

    private struct Stack: Identifiable {
        let id = UUID()
        let bucketStart: Int   // minute offset from range start
        let category: String
        let seconds: Double
    }

    // MARK: - Bucketing

    /// Aim for ~60 bars across the chart. Snaps to readable widths so labels
    /// and bar density stay sane across "Today" (1440 min) → "Last 30 days"
    /// (43200 min) ranges.
    private var bucketMinutes: Int {
        let target = max(1, series.count / 60)
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
            // Order is the stack order from bottom to top.
            if f > 0 { out.append(Stack(bucketStart: i, category: "Focus", seconds: f)) }
            if n > 0 { out.append(Stack(bucketStart: i, category: "Neutral", seconds: n)) }
            if d > 0 { out.append(Stack(bucketStart: i, category: "Distraction", seconds: d)) }
            i = end
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
                x: .value("Time", s.bucketStart),
                y: .value("Seconds", s.seconds),
                width: .ratio(0.92)
            )
            .foregroundStyle(by: .value("Category", s.category))
            .cornerRadius(1.5)
        }
        .chartForegroundStyleScale([
            "Focus":       Theme.focus,
            "Neutral":     Theme.neutral.opacity(0.6),
            "Distraction": Theme.distraction,
        ])
        .chartXScale(domain: 0...max(1, series.count))
        .chartXAxis {
            AxisMarks(values: xTicks) { v in
                AxisGridLine().foregroundStyle(Theme.separator.opacity(0.5))
                AxisTick().foregroundStyle(Theme.separator.opacity(0.5))
                AxisValueLabel {
                    if let m = v.as(Int.self) {
                        Text(formatX(m))
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
        .chartLegend(position: .top, alignment: .leading, spacing: 14)
        .frame(height: 200)
    }

    // MARK: - Axes

    private var xStrideMinutes: Int {
        let total = max(1, series.count)
        let target = max(1, total / 7)
        let snaps = [60, 120, 180, 360, 720, 1440, 2880, 4320, 10080]
        return snaps.first(where: { $0 >= target }) ?? snaps.last!
    }

    private var xTicks: [Int] {
        Array(Swift.stride(from: 0, through: max(1, series.count), by: xStrideMinutes))
    }

    private func formatX(_ minute: Int) -> String {
        if series.count <= 60 * 36 {
            // Single-day range — show clock-style hour labels.
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
