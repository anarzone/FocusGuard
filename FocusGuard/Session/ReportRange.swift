import Foundation

/// User-selectable time window for the Reports view. Drives every section
/// (hero, timeline, top apps, distractions) so they're always in sync.
enum ReportRange: Hashable {
    case today
    case yesterday
    case last7Days
    case last30Days
    case thisWeek
    case thisMonth
    case custom(from: Date, to: Date)

    var label: String {
        switch self {
        case .today:                       return "Today"
        case .yesterday:                   return "Yesterday"
        case .last7Days:                   return "Last 7 days"
        case .last30Days:                  return "Last 30 days"
        case .thisWeek:                    return "This week"
        case .thisMonth:                   return "This month"
        case .custom:                      return "Custom"
        }
    }

    /// Resolves to a concrete (from, to) using the current calendar.
    func dateRange(now: Date = .now, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return (startOfToday, now)
        case .yesterday:
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return (startOfYesterday, startOfToday)
        case .last7Days:
            let from = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return (from, now)
        case .last30Days:
            let from = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return (from, now)
        case .thisWeek:
            // Calendar's firstWeekday determines whether weeks start on Sunday/Monday.
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let weekStart = calendar.date(from: comps) ?? startOfToday
            return (weekStart, now)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let monthStart = calendar.date(from: comps) ?? startOfToday
            return (monthStart, now)
        case .custom(let from, let to):
            return (from, to)
        }
    }

    /// Used for the heading line on the report ("Today · 3 May 2026").
    func headingDateString(now: Date = .now) -> String {
        let (from, to) = dateRange(now: now)
        let f = DateFormatter()
        switch self {
        case .today, .yesterday:
            f.dateFormat = "EEEE, MMM d"
            return f.string(from: from)
        case .custom:
            f.dateFormat = "MMM d"
            return "\(f.string(from: from)) – \(f.string(from: to))"
        default:
            f.dateFormat = "MMM d"
            return "\(f.string(from: from)) – \(f.string(from: to))"
        }
    }

    static let presets: [ReportRange] = [
        .today, .yesterday, .last7Days, .last30Days, .thisWeek, .thisMonth
    ]
}
