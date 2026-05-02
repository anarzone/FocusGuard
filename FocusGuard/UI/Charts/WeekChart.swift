import SwiftUI
import Charts

struct WeekChart: View {
    /// Tracked seconds for each of the last 7 days, oldest first.
    let values: [TimeInterval]

    private var data: [DayBar] {
        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        return values.enumerated().map { i, v in
            DayBar(day: labels[i], minutes: v / 60, isToday: i == values.count - 1)
        }
    }

    var body: some View {
        Chart(data) { bar in
            BarMark(
                x: .value("Day", bar.day),
                y: .value("Minutes", bar.minutes)
            )
            .foregroundStyle(bar.isToday ? Theme.focus : Theme.fill2)
            .cornerRadius(2)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisValueLabel()
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct DayBar: Identifiable {
    let id = UUID()
    let day: String
    let minutes: Double
    let isToday: Bool
}
