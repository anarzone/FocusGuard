import SwiftUI
import Charts

/// Day-bucketed sparkline. Two init shapes:
///  - `WeekChart(values:)` — legacy 7-element array of seconds (M…S, last = today)
///  - `WeekChart(daily:)` — arbitrary range as [DailyTotal]; labels adapt to length
struct WeekChart: View {
    private let bars: [DayBar]

    init(values: [TimeInterval]) {
        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        let last = values.count - 1
        self.bars = values.enumerated().map { i, v in
            DayBar(label: i < labels.count ? labels[i] : "", minutes: v / 60, isLast: i == last)
        }
    }

    init(daily: [DailyTotal]) {
        let last = daily.count - 1
        let calendar = Calendar.current
        let formatter = DateFormatter()
        // Pick label style based on range length so we don't crowd the axis.
        let style: LabelStyle = {
            switch daily.count {
            case ...8:  return .weekday
            case ...32: return .dayOfMonthEveryNth(5)
            default:    return .monthDay
            }
        }()
        self.bars = daily.enumerated().map { i, d in
            let label: String
            switch style {
            case .weekday:
                formatter.dateFormat = "EEEEE" // single-letter weekday
                label = formatter.string(from: d.date)
            case .dayOfMonthEveryNth(let n):
                let day = calendar.component(.day, from: d.date)
                label = (i == 0 || i == last || day % n == 0) ? "\(day)" : ""
            case .monthDay:
                formatter.dateFormat = "MMM d"
                label = (i == 0 || i == last) ? formatter.string(from: d.date) : ""
            }
            return DayBar(label: label, minutes: d.seconds / 60, isLast: i == last)
        }
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Day", bar.id.uuidString),
                y: .value("Minutes", bar.minutes)
            )
            .foregroundStyle(bar.isLast ? Theme.focus : Theme.fill2)
            .cornerRadius(2)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisValueLabel {
                    if let id = value.as(String.self),
                       let bar = bars.first(where: { $0.id.uuidString == id }),
                       !bar.label.isEmpty {
                        Text(bar.label)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private enum LabelStyle {
    case weekday
    case dayOfMonthEveryNth(Int)
    case monthDay
}

private struct DayBar: Identifiable {
    let id = UUID()
    let label: String
    let minutes: Double
    let isLast: Bool
}
