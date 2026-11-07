import Foundation

/// What set off the lost focus: the place the user was in, then the
/// distraction they went to. "x.com while you wait on Codex", "YouTube after
/// Slack". Built from the period's lost-focus moments and its waits, by rule.
struct AnalyzerTrigger: Equatable, Identifiable, Sendable {
    struct Step: Equatable, Sendable {
        enum Kind: String, Sendable { case app, site, wait }
        let label: String
        let kind: Kind
    }

    /// One time it happened, for the list the user can correct.
    struct Moment: Equatable, Identifiable, Sendable {
        let start: Date
        let seconds: TimeInterval
        /// Ruled out by the user: "Not a distraction".
        var isRuledOut = false

        var id: String { AnalyzerTriggers.key(start) }
    }

    /// "wait:Codex>x.com", "Slack>youtube.com".
    let id: String
    let steps: [Step]
    var moments: [Moment]
    /// Times each working day, oldest first, for the little bars.
    var perDay: [Int]
    /// The cause the existing fixes are keyed by, when there is one.
    var cause: AnalyzerCause?

    var counted: [Moment] { moments.filter { !$0.isRuledOut } }
    var count: Int { counted.count }
    var seconds: TimeInterval { counted.reduce(0) { $0 + $1.seconds } }
    var daysSeen: Int { perDay.filter { $0 > 0 }.count }
    var isWait: Bool { steps.first?.kind == .wait }

    /// How sure: 1 early, 2 fairly, 3 seen on most days.
    func sureness(workingDays: Int) -> Int {
        guard workingDays > 0 else { return 1 }
        let share = Double(daysSeen) / Double(workingDays)
        if daysSeen >= 4 && share >= 0.5 { return 3 }
        return daysSeen >= 2 ? 2 : 1
    }
}

enum AnalyzerTriggers {
    /// Fewer than this and it's not a pattern yet.
    static let fewestTimes = 2
    static let shown = 4
    /// The ruled-out moments, by start.
    static let ruledOutKey = "analyzer.notDistraction"

    static func key(_ start: Date) -> String { String(Int(start.timeIntervalSinceReferenceDate)) }

    /// The triggers, most time first. A lost-focus moment during a wait the
    /// user drifted in counts for the wait: the wait says more about why.
    static func make(days: [AnalyzerDay], waits: [WaitRecord], ruledOut: Set<String>,
                     optedOut: Set<String> = [], calendar: Calendar = .current) -> [AnalyzerTrigger] {
        let dayStarts = days.map { calendar.startOfDay(for: $0.day) }
        var found: [String: AnalyzerTrigger] = [:]

        func add(id: String, steps: [AnalyzerTrigger.Step], start: Date, seconds: TimeInterval, cause: AnalyzerCause?) {
            guard let dayIndex = dayStarts.firstIndex(of: calendar.startOfDay(for: start)) else { return }
            var trigger = found[id] ?? AnalyzerTrigger(id: id, steps: steps, moments: [], perDay: Array(repeating: 0, count: days.count), cause: cause)
            let moment = AnalyzerTrigger.Moment(start: start, seconds: seconds, isRuledOut: ruledOut.contains(key(start)))
            trigger.moments.append(moment)
            if !moment.isRuledOut { trigger.perDay[dayIndex] += 1 }
            found[id] = trigger
        }

        let drifts = waits.filter { $0.drifted && $0.to != nil }
        for wait in drifts {
            let to = wait.to ?? ""
            add(id: "wait:\(wait.tool)>\(to)",
                steps: [.init(label: wait.tool, kind: .wait), .init(label: to, kind: .site)],
                start: wait.start, seconds: wait.drift, cause: .habit)
        }
        for day in days {
            for loss in day.losses {
                guard let to = loss.places.first(where: { $0.isDistraction && !optedOut.contains($0.bundleId ?? "") }) else { continue }
                let during = drifts.contains { wait in
                    let end = wait.start.addingTimeInterval(wait.seconds)
                    return loss.start < end && wait.start < loss.end
                }
                if during { continue }
                var steps: [AnalyzerTrigger.Step] = []
                if let opening = loss.opening, opening.target != to.target, !optedOut.contains(opening.bundleId ?? "") {
                    steps.append(.init(label: opening.name, kind: opening.isSite ? .site : .app))
                } else if let before = loss.before, !optedOut.contains(before.bundleId ?? "") {
                    steps.append(.init(label: before.name, kind: before.isSite ? .site : .app))
                }
                steps.append(.init(label: to.name, kind: to.isSite ? .site : .app))
                add(id: steps.map(\.label).joined(separator: ">"), steps: steps, start: loss.start, seconds: loss.seconds, cause: loss.cause)
            }
        }
        return found.values
            .filter { $0.count >= fewestTimes }
            .map { trigger in
                var trigger = trigger
                trigger.moments.sort { $0.start > $1.start }
                return trigger
            }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
            .prefix(shown)
            .map { $0 }
    }

    /// What the rule saw, in words: never why.
    static func because(_ trigger: AnalyzerTrigger, workingDays: Int) -> String {
        let days = trigger.daysSeen
        let last = trigger.steps.last?.label ?? ""
        if trigger.isWait, let tool = trigger.steps.first?.label {
            return String(localized: "Each time, \(tool) was working: you had just left it, and \(last) came within a minute and a half. Seen on \(days) of \(workingDays) days.",
                          comment: "Analyzer: the tool, the site, then days seen and working days")
        }
        if trigger.steps.count > 1, let first = trigger.steps.first?.label {
            return String(localized: "\(last) came right after \(first), with no work in between. Seen on \(days) of \(workingDays) days.",
                          comment: "Analyzer: the distraction, the app before it, then days seen and working days")
        }
        return String(localized: "Focus ended on \(last), with nothing just before it. Seen on \(days) of \(workingDays) days.",
                      comment: "Analyzer: the distraction, then days seen and working days")
    }

    /// The headline: "x.com while you wait on Codex".
    static func title(_ trigger: AnalyzerTrigger) -> String {
        let last = trigger.steps.last?.label ?? ""
        if trigger.isWait, let tool = trigger.steps.first?.label {
            return String(localized: "\(last) while you wait on \(tool)", comment: "Analyzer trigger: the site, then the tool")
        }
        if trigger.steps.count > 1, let first = trigger.steps.first?.label {
            return String(localized: "\(last) after \(first)", comment: "Analyzer trigger: the distraction, then the app before it")
        }
        return last
    }
}

/// The moments the user said weren't a distraction, kept on this Mac.
enum AnalyzerRuledOut {
    static func load(_ defaults: UserDefaults = UITestMode.defaults) -> Set<String> {
        Set(defaults.stringArray(forKey: AnalyzerTriggers.ruledOutKey) ?? [])
    }

    static func toggle(_ moment: AnalyzerTrigger.Moment, _ defaults: UserDefaults = UITestMode.defaults) {
        var set = load(defaults)
        if set.contains(moment.id) { set.remove(moment.id) } else { set.insert(moment.id) }
        defaults.set(Array(set).sorted(), forKey: AnalyzerTriggers.ruledOutKey)
    }

    static func erase(_ defaults: UserDefaults = UITestMode.defaults) {
        defaults.removeObject(forKey: AnalyzerTriggers.ruledOutKey)
    }
}
