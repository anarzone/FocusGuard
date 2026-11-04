import Foundation

/// A line of the week update, and what it stands on.
struct WeekLine: Identifiable, Equatable {
    enum Group: Equatable {
        case done
        case going
        /// A guess at time without a goal. Left out of what's shared until
        /// the user keeps it.
        case check
        /// A guess the user kept.
        case also
    }

    /// One thing behind the line.
    struct Evidence: Equatable {
        enum Kind: Equatable { case time, verdict, task, apps, note, ask }
        let kind: Kind
        let text: String
    }

    /// The goal or the guess, lowercased, so an edit stays with it.
    let id: String
    let text: String
    let group: Group
    let project: String?
    let seconds: TimeInterval
    /// The days it drew on.
    let days: Set<Date>
    let evidence: [Evidence]
    /// Newest first.
    let sessions: [WorkLogEntry]
}

/// The week as something to share: done, still going, and what to check.
struct WeekUpdate: Equatable {
    let done: [WeekLine]
    let going: [WeekLine]
    let check: [WeekLine]
    let also: [WeekLine]
    let leftOut: [WeekLine]

    var lines: [WeekLine] { done + going + check + also }
    var isEmpty: Bool { lines.isEmpty && leftOut.isEmpty }
    /// Whether it can go out as it is.
    var isReady: Bool { check.isEmpty }

    /// What Copy puts on the clipboard. Guesses stay out until they're kept.
    func text(interval: DateInterval) -> String {
        var out = [String(localized: "Week of \(interval.start.formatted(.dateTime.day().month(.wide)))")]
        for (title, lines) in [(GoalVerdict.done.chipText, done), (String(localized: "Still going"), going),
                               (String(localized: "Also this week"), also)] where !lines.isEmpty {
            out.append("")
            out.append(title)
            out += lines.map { "- \($0.text) (\(WindowFormat.hm($0.seconds)))" }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// What the user decided about a guess, for one week. Kept with the week, so
/// it's still there when the week is opened again.
enum WeekDecision: Codable, Equatable {
    case kept(name: String?)
    case left
}

/// The decisions, in the defaults. Half a year of weeks is kept.
struct WeekEditStore {
    static let key = "yourWeek.edits"
    static let weeksKept = 26
    var defaults: UserDefaults = UITestMode.defaults

    private static func weekKey(_ start: Date) -> String { String(Int(start.timeIntervalSince1970)) }

    func decisions(week start: Date) -> [String: WeekDecision] { all()[Self.weekKey(start)] ?? [:] }

    func set(_ decision: WeekDecision?, line: String, week start: Date) {
        var weeks = all()
        var decisions = weeks[Self.weekKey(start)] ?? [:]
        decisions[line] = decision
        weeks[Self.weekKey(start)] = decisions.isEmpty ? nil : decisions
        let kept = weeks.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }.prefix(Self.weeksKept)
        let trimmed = weeks.filter { kept.contains($0.key) }
        if let data = try? JSONEncoder().encode(trimmed) { defaults.set(data, forKey: Self.key) }
    }

    func erase() { defaults.removeObject(forKey: Self.key) }

    private func all() -> [String: [String: WeekDecision]] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: WeekDecision]].self, from: data)) ?? [:]
    }
}

/// Builds the update from the week's sessions, by fixed rules: every line
/// can say where it came from.
enum WeekUpdateBuilder {
    /// Time without a goal has to add up to this before it's worth asking about.
    static let guessFrom: TimeInterval = 30 * 60

    static func build(_ model: WorkLogModel, decisions: [String: WeekDecision] = [:],
                      links: [UUID: TaskLink] = [:], calendar: Calendar = .current) -> WeekUpdate {
        var done: [WeekLine] = [], going: [WeekLine] = [], check: [WeekLine] = []
        var also: [WeekLine] = [], leftOut: [WeekLine] = []

        let goals = Dictionary(grouping: model.entries.filter(\.hasGoal)) { $0.title.lowercased() }
        for (key, entries) in goals {
            let line = goalLine(id: "goal:\(key)", entries: sortedNewestFirst(entries), links: links, calendar: calendar)
            if line.group == .done { done.append(line) } else { going.append(line) }
        }

        let loose = model.entries.filter { !$0.hasGoal && !$0.isLive && $0.focused > 0 }
        let guesses = Dictionary(grouping: loose) { $0.project ?? $0.mostly ?? "" }
        for (name, entries) in guesses where !name.isEmpty {
            let seconds = entries.reduce(0) { $0 + $1.focused }
            guard seconds >= guessFrom else { continue }
            let id = "time:\(name.lowercased())"
            let base = guessLine(id: id, name: name, entries: sortedNewestFirst(entries), seconds: seconds, calendar: calendar)
            switch decisions[id] {
            case .kept(let renamed):
                also.append(base.kept(name: renamed ?? name))
            case .left:
                leftOut.append(base)
            case nil:
                check.append(base)
            }
        }
        func order(_ lines: [WeekLine]) -> [WeekLine] {
            lines.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
        }
        return WeekUpdate(done: order(done), going: order(going), check: order(check), also: order(also), leftOut: order(leftOut))
    }

    private static func sortedNewestFirst(_ entries: [WorkLogEntry]) -> [WorkLogEntry] {
        entries.sorted { $0.start > $1.start }
    }

    private static func days(_ entries: [WorkLogEntry], calendar: Calendar) -> Set<Date> {
        Set(entries.map { calendar.startOfDay(for: $0.start) })
    }

    private static func goalLine(id: String, entries: [WorkLogEntry], links: [UUID: TaskLink], calendar: Calendar) -> WeekLine {
        let newest = entries.first
        let seconds = entries.reduce(0) { $0 + $1.focused }
        // A running session means it isn't over, whatever an earlier one said.
        var settled: (entry: WorkLogEntry, verdict: GoalVerdict)?
        if newest?.isLive != true {
            for entry in entries {
                if case .verdict(let verdict) = entry.state { settled = (entry, verdict); break }
            }
        }
        var evidence: [WeekLine.Evidence] = []
        if let link = entries.compactMap({ links[$0.id] }).first {
            evidence.append(.init(kind: .task, text: link.ticked
                ? String(localized: "Ticked off in \(link.task.source.name)", comment: "Where a goal came from: Ticked off in Linear")
                : String(localized: "From \(link.task.source.name)", comment: "Where a goal came from: From Linear")))
        }
        if let settled {
            let weekday = settled.entry.start.formatted(.dateTime.weekday(.wide))
            let text: String
            switch settled.verdict {
            case .done:   text = String(localized: "Marked done in \(weekday)'s session", comment: "Marked done in Wednesday's session")
            case .partly: text = String(localized: "Marked partly done in \(weekday)'s session", comment: "Marked partly done in Wednesday's session")
            case .notYet: text = String(localized: "Marked not yet in \(weekday)'s session", comment: "Marked not yet in Wednesday's session")
            }
            evidence.append(.init(kind: .verdict, text: text))
        } else {
            evidence.append(.init(kind: .verdict, text: String(localized: "Not marked done yet, so it stays under Still going")))
        }
        evidence.append(.init(kind: .time, text: String(localized: "\(entries.count) sessions with this goal, \(WindowFormat.hm(seconds)) focused",
                                                        comment: "Plural on count: 1 session with this goal, 2h focused")))
        if let apps = newest?.apps, !apps.isEmpty { evidence.append(.init(kind: .apps, text: apps)) }
        if let note = newest?.note, newest?.isLive == false { evidence.append(.init(kind: .note, text: note)) }
        return WeekLine(id: id, text: newest?.title ?? "", group: settled?.verdict == .done ? .done : .going,
                        project: entries.compactMap(\.project).first, seconds: seconds,
                        days: days(entries, calendar: calendar), evidence: evidence, sessions: entries)
    }

    private static func guessLine(id: String, name: String, entries: [WorkLogEntry], seconds: TimeInterval, calendar: Calendar) -> WeekLine {
        var evidence = [WeekLine.Evidence(kind: .time, text: String(localized: "\(WindowFormat.hm(seconds)) on \(name), with no goal set",
                                                                    comment: "2h 05m on github.com, with no goal set"))]
        if let apps = entries.first?.apps, !apps.isEmpty, apps != name { evidence.append(.init(kind: .apps, text: apps)) }
        return WeekLine(id: id, text: String(localized: "\(name)?", comment: "A guess at what some time was: github.com?"),
                        group: .check, project: entries.compactMap(\.project).first, seconds: seconds,
                        days: days(entries, calendar: calendar), evidence: evidence, sessions: entries)
    }
}

private extension WeekLine {
    func kept(name: String) -> WeekLine {
        var kept = evidence
        kept.insert(.init(kind: .verdict, text: String(localized: "You kept this line")), at: 0)
        return WeekLine(id: id, text: name, group: .also, project: project, seconds: seconds,
                        days: days, evidence: kept, sessions: sessions)
    }
}

/// The numbers at the top of the page: the week's focus, by day and project.
/// Its totals are the same ones Today and Reports show, so focus outside
/// sessions counts here too, under Other.
struct WeekOverview: Equatable {
    struct Series: Identifiable, Equatable {
        /// The project's name, or `otherID`.
        let id: String
        let title: String
        /// Which of the three project colours; nil is Other.
        let slot: Int?
        let seconds: TimeInterval
    }

    struct Day: Identifiable, Equatable {
        let date: Date
        /// By `series` order.
        let seconds: [String: TimeInterval]
        let goal: TimeInterval
        var id: Date { date }
        var total: TimeInterval { seconds.values.reduce(0, +) }
        var metGoal: Bool { goal > 0 && total >= goal }
    }

    static let otherID = "\u{1}other"
    /// More than this many hues can't be told apart; the rest go under Other.
    static let colours = 3

    let focused: TimeInterval
    /// Change from the week before; nil with nothing to compare.
    let change: TimeInterval?
    let goalMet: Int
    let goalCounted: Int
    /// A day's goal, for the line across the chart.
    let goal: TimeInterval
    /// Most time first, Other last.
    let series: [Series]
    let days: [Day]
    /// The days that count toward the goal, for the dots.
    let goalDays: [Day]

    /// - Parameters:
    ///   - allFocus: each day's whole focus, in or out of sessions; nil until
    ///     Reports' numbers are in.
    ///   - remembered: the colour each project had last.
    static func make(model: WorkLogModel, report: ReportsModel?, goal: (Date) -> TimeInterval, weekendsCount: Bool,
                     remembered: [String: Int] = [:], calendar: Calendar = .current) -> WeekOverview {
        let sheet = model.timesheet
        var allFocus: [Date: TimeInterval] = [:]
        for bucket in report?.data.buckets ?? [] { allFocus[calendar.startOfDay(for: bucket.interval.start)] = bucket.focus }

        // Monday to Friday, and a weekend day with time on it.
        var dates = sheet.days
        for (date, seconds) in allFocus where seconds >= 60 && !dates.contains(date) { dates.append(date) }
        if dates.isEmpty {
            var day = calendar.startOfDay(for: model.interval.start)
            while day < model.interval.end {
                if !calendar.isDateInWeekend(day) { dates.append(day) }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? model.interval.end
            }
        }
        dates.sort()

        let named = sheet.rows.compactMap(\.project)
        let coloured = Array(named.prefix(colours))
        let slots = assignSlots(coloured, remembered: remembered)
        var others = false
        let days: [Day] = dates.map { date in
            var seconds: [String: TimeInterval] = [:]
            var inSessions: TimeInterval = 0
            if let column = sheet.days.firstIndex(of: date) {
                for row in sheet.rows {
                    let value = row.seconds[column]
                    guard value > 0 else { continue }
                    inSessions += value
                    let key = row.project.flatMap { coloured.contains($0) ? $0 : nil } ?? otherID
                    seconds[key, default: 0] += value
                }
            }
            let outside = max(0, (allFocus[date] ?? inSessions) - inSessions)
            if outside >= 1 { seconds[otherID, default: 0] += outside }
            if (seconds[otherID] ?? 0) > 0 { others = true }
            return Day(date: date, seconds: seconds, goal: goal(date))
        }

        var totals: [String: TimeInterval] = [:]
        for day in days { for (key, value) in day.seconds { totals[key, default: 0] += value } }
        var series = coloured.map { Series(id: $0, title: $0, slot: slots[$0], seconds: totals[$0] ?? 0) }
        if others {
            series.append(Series(id: otherID, title: String(localized: "Other", comment: "Focus that isn't one of the week's main projects"),
                                 slot: nil, seconds: totals[otherID] ?? 0))
        }
        let focused = report?.data.breakdown.focus ?? model.focused
        let before = report?.data.previous.focus ?? 0
        return WeekOverview(
            focused: focused,
            change: before >= 60 ? focused - before : nil,
            goalMet: report?.goal.met ?? days.filter(\.metGoal).count,
            goalCounted: report?.goal.counted ?? days.count,
            goal: report?.data.goalPerBucket ?? goal(model.interval.start),
            series: series,
            days: days,
            goalDays: days.filter { weekendsCount || !calendar.isDateInWeekend($0.date) }
        )
    }

    /// A project keeps its colour from week to week while it can: colour
    /// follows the project, not how much time it had.
    static func assignSlots(_ names: [String], remembered: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        var taken = Set<Int>()
        for name in names {
            if let slot = remembered[name], (0..<colours).contains(slot), taken.insert(slot).inserted { out[name] = slot }
        }
        for name in names where out[name] == nil {
            if let slot = (0..<colours).first(where: { !taken.contains($0) }) {
                out[name] = slot
                taken.insert(slot)
            }
        }
        return out
    }
}

/// The colour each project had last, in the defaults.
struct WeekColourStore {
    static let key = "yourWeek.projectColours"
    /// Older ones are dropped; they'd have lost their colour by now anyway.
    static let kept = 40
    var defaults: UserDefaults = UITestMode.defaults

    var remembered: [String: Int] { defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:] }

    func remember(_ slots: [String: Int]) {
        let all = remembered.merging(slots) { $1 }
        guard all != remembered else { return }
        defaults.set(all.count > Self.kept ? slots : all, forKey: Self.key)
    }

    func erase() { defaults.removeObject(forKey: Self.key) }
}
