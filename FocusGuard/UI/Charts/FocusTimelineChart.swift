import SwiftUI
import Charts

/// Per-minute stacked area showing the focus/neutral/distraction split
/// of a session. Fed with mock data until Phase 4 ships classification —
/// once that lands, this view aggregates real `ActivityEvent` rows by minute.
struct FocusTimelineChart: View {
    /// Minute index → (focus%, neutral%, distraction%)
    let series: [TimelinePoint]

    init(series: [TimelinePoint]) {
        self.series = series
    }

    var body: some View {
        Chart {
            ForEach(series) { p in
                AreaMark(
                    x: .value("Minute", p.minute),
                    yStart: .value("0", 0),
                    yEnd: .value("Focus", p.focus)
                )
                .foregroundStyle(by: .value("Series", "Focus"))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Minute", p.minute),
                    yStart: .value("Focus", p.focus),
                    yEnd: .value("FocusNeutral", p.focus + p.neutral)
                )
                .foregroundStyle(by: .value("Series", "Neutral"))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Minute", p.minute),
                    yStart: .value("FocusNeutral", p.focus + p.neutral),
                    yEnd: .value("Total", p.focus + p.neutral + p.distraction)
                )
                .foregroundStyle(by: .value("Series", "Distraction"))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale([
            "Focus": Theme.focus,
            "Neutral": Theme.neutral,
            "Distraction": Theme.distraction,
        ])
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { v in
                AxisGridLine().foregroundStyle(Theme.separator)
                AxisValueLabel(centered: false) {
                    if let raw = v.as(Double.self) {
                        Text("\(Int(raw * 100))%")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { v in
                AxisGridLine().foregroundStyle(Theme.separator.opacity(0.4))
                AxisValueLabel {
                    if let raw = v.as(Int.self) {
                        Text("\(raw)m")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

struct TimelinePoint: Identifiable {
    let id = UUID()
    let minute: Int
    let focus: Double
    let neutral: Double
    let distraction: Double
}
