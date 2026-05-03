import SwiftUI
import Charts

struct TimelinePoint: Identifiable {
    let id = UUID()
    let minute: Int
    let focus: Double
    let neutral: Double
    let distraction: Double
}

/// Per-minute classification timeline, rendered as a clean stacked bar chart.
///
/// The choppy "noise" look of the previous AreaMark version came from
/// rendering 1440 individual minutes at full resolution — each minute had
/// near-zero or full values, producing visual jitter. We bucket the input
/// minutes into wider bars (target ~80 bars across the visible width) so
/// each bar represents a calm, readable chunk of time.
struct FocusTimelineChart: View {
    let series: [TimelinePoint]

    init(series: [TimelinePoint]) {
        self.series = series
    }

    private struct Bucket: Identifiable {
        let id = UUID()
        /// Bucket start, in minutes since the window's `from`.
        let startMinute: Int
        /// Width of the bucket in minutes.
        let durationMinutes: Int
        let focus: Double         // seconds
        let neutral: Double
        let distraction: Double

        var total: Double { focus + neutral + distraction }
    }

    /// Aim for ~80 bars across the chart so each bar is readable.
    /// Buckets snap to common readable widths.
    private var bucketMinutes: Int {
        let target = max(1, series.count / 80)
        let snaps = [1, 2, 5, 10, 15, 30, 60, 120]
        return snaps.first(where: { $0 >= target }) ?? snaps.last!
    }

    private var buckets: [Bucket] {
        guard !series.isEmpty else { return [] }
        let width = bucketMinutes
        var out: [Bucket] = []
        var i = 0
        while i < series.count {
            let end = min(i + width, series.count)
            var f: Double = 0, n: Double = 0, d: Double = 0
            for j in i..<end {
                let p = series[j]
                f += p.focus * 60
                n += p.neutral * 60
                d += p.distraction * 60
            }
            out.append(Bucket(
                startMinute: i,
                durationMinutes: end - i,
                focus: f, neutral: n, distraction: d
            ))
            i = end
        }
        return out
    }

    /// X-axis tick stride in minutes. Aim for ~6–8 readable labels.
    private var xStride: Int {
        let total = max(1, series.count)
        let target = max(1, total / 7)
        let snaps = [5, 10, 15, 30, 60, 120, 240, 360]
        return snaps.first(where: { $0 >= target }) ?? snaps.last!
    }

    var body: some View {
        if series.isEmpty {
            HStack {
                Spacer()
                Text("No activity in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 40)
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart(buckets) { b in
            BarMark(
                x: .value("Minute", b.startMinute),
                y: .value("Seconds", b.focus),
                width: .ratio(0.95)
            )
            .foregroundStyle(by: .value("Class", "Focus"))
            .position(by: .value("Class", "Focus"), span: .automatic)

            BarMark(
                x: .value("Minute", b.startMinute),
                y: .value("Seconds", b.neutral),
                width: .ratio(0.95)
            )
            .foregroundStyle(by: .value("Class", "Neutral"))

            BarMark(
                x: .value("Minute", b.startMinute),
                y: .value("Seconds", b.distraction),
                width: .ratio(0.95)
            )
            .foregroundStyle(by: .value("Class", "Distraction"))
        }
        .chartForegroundStyleScale([
            "Focus":       Theme.focus,
            "Neutral":     Theme.neutral.opacity(0.5),
            "Distraction": Theme.distraction,
        ])
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Theme.separator.opacity(0.4))
                AxisValueLabel {
                    if let raw = v.as(Double.self) {
                        Text(formatYAxis(seconds: raw))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            let ticks = Array(Swift.stride(from: 0, through: series.count, by: xStride))
            AxisMarks(values: ticks) { v in
                AxisGridLine().foregroundStyle(Theme.separator.opacity(0.25))
                AxisValueLabel {
                    if let raw = v.as(Int.self) {
                        Text(formatMinute(raw))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Y-axis: format big-bucket seconds as minutes/hours.
    private func formatYAxis(seconds: Double) -> String {
        let m = seconds / 60
        if m >= 60 { return "\(Int(m / 60))h" }
        return "\(Int(m))m"
    }

    /// X-axis: minutes-since-from formatted readably.
    private func formatMinute(_ m: Int) -> String {
        if series.count <= 90 { return "\(m)m" }
        if m == 0 { return "0h" }
        if m % 60 == 0 { return "\(m / 60)h" }
        let h = m / 60
        let r = m % 60
        return "\(h):\(String(format: "%02d", r))"
    }
}
