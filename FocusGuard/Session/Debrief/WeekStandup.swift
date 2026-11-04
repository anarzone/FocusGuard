import Foundation

/// What to say at standup: the last day worked, what's on today, and what's
/// blocking. FocusGuard can't know what's blocking, so only the user fills
/// that in, and nothing goes out saying nothing is.
struct WeekStandup: Equatable {
    struct Item: Equatable, Identifiable {
        let text: String
        /// Where it came from: "Marked done", "Next on Linear".
        let from: String
        var id: String { text }
    }

    /// The day the first column is about; nil before there's one.
    let lastDay: Date?
    let lastTitle: String
    let last: [Item]
    let nextTitle: String
    let next: [Item]

    var isEmpty: Bool { last.isEmpty && next.isEmpty }

    /// What Copy for Slack puts on the clipboard, in Slack's own bold.
    func text(blockers: [String]) -> String {
        var parts: [String] = []
        func add(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            parts.append((["*\(title)*"] + lines.map { "• \($0)" }).joined(separator: "\n"))
        }
        add(lastTitle, last.map(\.text))
        add(nextTitle, next.map(\.text))
        add(String(localized: "Blocked", comment: "A standup's column for what's in the way"), blockers)
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// - Parameters:
    ///   - isCurrent: the week being looked at is this one, so today's tasks
    ///     and meetings belong in it.
    ///   - earlier: the week before, for a Monday with nothing yet this week.
    static func make(model: WorkLogModel, earlier: WorkLogModel? = nil, isCurrent: Bool, tasks: [TaskItem] = [],
                     meetings: [NextMeeting] = [], now: Date = .now, calendar: Calendar = .current) -> WeekStandup {
        let today = calendar.startOfDay(for: now)
        let days = (model.days + (earlier?.days ?? [])).sorted { $0.day > $1.day }
        let lastDay = isCurrent ? days.first { $0.day < today } : days.first
        let todays = isCurrent ? days.first { $0.day == today } : nil

        var last: [Item] = []
        var next: [Item] = []
        if let lastDay {
            for line in goals(in: lastDay) {
                if line.verdict == .done {
                    last.append(Item(text: line.text, from: String(localized: "Marked done, \(WindowFormat.hm(line.seconds))", comment: "Where a standup line came from: Marked done, 2h 40m")))
                } else {
                    last.append(Item(text: line.text, from: String(localized: "\(WindowFormat.hm(line.seconds)) focused", comment: "Where a standup line came from: 2h 40m focused")))
                    next.append(Item(text: line.text, from: String(localized: "Still open", comment: "Where a standup line came from: a goal that isn't done")))
                }
            }
            if last.isEmpty {
                let focused = WindowFormat.hm(lastDay.focused)
                let count = lastDay.entries.count
                last.append(Item(text: String(localized: "\(count) sessions, \(focused) focused", comment: "Plural on count: 1 session, 3h focused"), from: String(localized: "No goals set", comment: "Where a standup line came from: sessions without goals")))
            }
        }
        if let todays {
            let open = goals(in: todays).filter { $0.verdict != .done }
            next = next.filter { item in !goals(in: todays).contains { $0.text.lowercased() == item.text.lowercased() && $0.verdict == .done } }
            next += open.map { Item(text: $0.text, from: String(localized: "Today's goal", comment: "Where a standup line came from")) }
        }
        if isCurrent {
            next += tasks.prefix(2).map {
                Item(text: $0.title, from: String(localized: "Next on \($0.source.name)", comment: "Where a standup line came from: Next on Linear"))
            }
            next += meetings.map {
                Item(text: String(localized: "\($0.title) at \(WindowFormat.clock($0.start))", comment: "A meeting in a standup: Design review at 10:00"),
                     from: String(localized: "Calendar", comment: "Heading over goals suggested from the calendar"))
            }
        }
        var seen = Set<String>()
        next = next.filter { seen.insert($0.text.lowercased()).inserted }

        let lastTitle: String
        if let lastDay, calendar.date(byAdding: .day, value: -1, to: today) == lastDay.day {
            lastTitle = String(localized: "Yesterday")
        } else {
            lastTitle = lastDay?.day.formatted(.dateTime.weekday(.wide)) ?? String(localized: "Last time", comment: "Heading over the last session's unfinished goal")
        }
        return WeekStandup(lastDay: lastDay?.day, lastTitle: lastTitle, last: last,
                           nextTitle: isCurrent ? String(localized: "Today") : String(localized: "Next", comment: "A standup's column for what comes next"), next: next)
    }

    /// A day's goals, newest verdict winning, oldest first.
    private static func goals(in day: WorkLogDay) -> [(text: String, verdict: GoalVerdict?, seconds: TimeInterval)] {
        var out: [(text: String, verdict: GoalVerdict?, seconds: TimeInterval)] = []
        for entry in day.entries.sorted(by: { $0.start < $1.start }) where entry.hasGoal {
            var verdict: GoalVerdict?
            if case .verdict(let said) = entry.state { verdict = said }
            if let index = out.firstIndex(where: { $0.text.lowercased() == entry.title.lowercased() }) {
                out[index].verdict = verdict ?? out[index].verdict
                out[index].seconds += entry.focused
            } else {
                out.append((entry.title, verdict, entry.focused))
            }
        }
        return out
    }
}

/// What's blocking, in the user's words, until they take it off. It stays from
/// day to day, because a blocker usually does.
struct WeekBlockerStore {
    static let key = "yourWeek.blockers"
    var defaults: UserDefaults = UITestMode.defaults

    var blockers: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockers.contains(trimmed) else { return }
        defaults.set(blockers + [trimmed], forKey: Self.key)
    }

    func remove(_ text: String) {
        defaults.set(blockers.filter { $0 != text }, forKey: Self.key)
    }

    func erase() { defaults.removeObject(forKey: Self.key) }
}
