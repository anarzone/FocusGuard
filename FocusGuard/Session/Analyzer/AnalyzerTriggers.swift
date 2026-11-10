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
    /// Enough of it is ruled out to ask if the whole pattern is fine, and the
    /// user hasn't answered: it stays listed until they do, however few count.
    var isAsking = false

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
    /// How long a tested hold keeps the site waiting: most waits on a tool
    /// are over by then.
    static let holdMinutes = 2
    /// The ruled-out moments, by start.
    static let ruledOutKey = "analyzer.notDistraction"

    static func key(_ start: Date) -> String { String(Int(start.timeIntervalSinceReferenceDate)) }

    /// The triggers, most time first. A lost-focus moment during a wait the
    /// user drifted in counts for the wait: the wait says more about why.
    static func make(days: [AnalyzerDay], waits: [WaitRecord], ruledOut: Set<String>,
                     optedOut: Set<String> = [], lessons: AnalyzerLessons = AnalyzerLessons(),
                     calendar: Calendar = .current) -> [AnalyzerTrigger] {
        build(days: days, waits: waits, ruledOut: ruledOut, optedOut: optedOut, lessons: lessons, calendar: calendar).shown
    }

    /// The pattern a lost-focus moment belongs to: where the user was, then
    /// the distraction. Nil when it has no distraction to name, or happened
    /// during a wait they drifted in.
    static func pattern(of loss: AnalyzerLoss, drifts: [WaitRecord], optedOut: Set<String> = []) -> (id: String, steps: [AnalyzerTrigger.Step])? {
        guard let to = loss.places.first(where: { $0.isDistraction && !optedOut.contains($0.bundleId ?? "") }) else { return nil }
        if wait(during: loss, drifts: drifts) != nil { return nil }
        var steps: [AnalyzerTrigger.Step] = []
        if let opening = loss.opening, opening.target != to.target, !optedOut.contains(opening.bundleId ?? "") {
            steps.append(.init(label: opening.name, kind: opening.isSite ? .site : .app))
        } else if let before = loss.before, !optedOut.contains(before.bundleId ?? "") {
            steps.append(.init(label: before.name, kind: before.isSite ? .site : .app))
        }
        steps.append(.init(label: to.name, kind: to.isSite ? .site : .app))
        return (steps.map(\.label).joined(separator: ">"), steps)
    }

    /// The drifted wait a lost-focus moment overlaps, if any.
    static func wait(during loss: AnalyzerLoss, drifts: [WaitRecord]) -> WaitRecord? {
        drifts.first { wait in
            let end = wait.start.addingTimeInterval(wait.seconds)
            return loss.start < end && wait.start < loss.end
        }
    }

    static func drifts(_ waits: [WaitRecord]) -> [WaitRecord] { waits.filter { $0.drifted && $0.to != nil } }

    /// The days without the lost-focus moments of patterns the user said are
    /// fine: those aren't lost focus for them, here or in the causes.
    static func without(fine: Set<String>, days: [AnalyzerDay], waits: [WaitRecord], optedOut: Set<String> = []) -> [AnalyzerDay] {
        guard !fine.isEmpty else { return days }
        let drifts = drifts(waits)
        return days.map { day in
            var day = day
            day.losses = day.losses.filter { loss in
                if let wait = wait(during: loss, drifts: drifts) {
                    return !fine.contains(AnalyzerLessonRules.waitID(tool: wait.tool, site: wait.to ?? ""))
                }
                guard let pattern = pattern(of: loss, drifts: drifts, optedOut: optedOut) else { return true }
                return !fine.contains(pattern.id)
            }
            return day
        }
    }

    /// The triggers to show, most time first, and the ones left out because
    /// the user said that pattern is fine (`taught`, every moment counted).
    static func build(days: [AnalyzerDay], waits: [WaitRecord], ruledOut: Set<String>, optedOut: Set<String> = [],
                      lessons: AnalyzerLessons = AnalyzerLessons(), calendar: Calendar = .current) -> (shown: [AnalyzerTrigger], taught: [AnalyzerTrigger]) {
        let fine = lessons.fineSet
        let dayStarts = days.map { calendar.startOfDay(for: $0.day) }
        var found: [String: AnalyzerTrigger] = [:]

        func add(id: String, steps: [AnalyzerTrigger.Step], start: Date, seconds: TimeInterval, cause: AnalyzerCause?) {
            guard let dayIndex = dayStarts.firstIndex(of: calendar.startOfDay(for: start)) else { return }
            var trigger = found[id] ?? AnalyzerTrigger(id: id, steps: steps, moments: [], perDay: Array(repeating: 0, count: days.count), cause: cause)
            // In a pattern that's fine, every moment is: none is ruled out one by one.
            let moment = AnalyzerTrigger.Moment(start: start, seconds: seconds, isRuledOut: !fine.contains(id) && ruledOut.contains(key(start)))
            trigger.moments.append(moment)
            if !moment.isRuledOut { trigger.perDay[dayIndex] += 1 }
            found[id] = trigger
        }

        let drifts = drifts(waits)
        for wait in drifts {
            let to = wait.to ?? ""
            add(id: AnalyzerLessonRules.waitID(tool: wait.tool, site: to),
                steps: [.init(label: wait.tool, kind: .wait), .init(label: to, kind: .site)],
                start: wait.start, seconds: wait.drift, cause: .habit)
        }
        for day in days {
            for loss in day.losses {
                guard let pattern = pattern(of: loss, drifts: drifts, optedOut: optedOut) else { continue }
                add(id: pattern.id, steps: pattern.steps, start: loss.start, seconds: loss.seconds, cause: loss.cause)
            }
        }
        func ordered(_ triggers: [AnalyzerTrigger]) -> [AnalyzerTrigger] {
            triggers.map { trigger in
                var trigger = trigger
                trigger.moments.sort { $0.start > $1.start }
                return trigger
            }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
        }
        let open = found.values.filter { !fine.contains($0.id) }.map { trigger in
            var trigger = trigger
            trigger.isAsking = lessons.asks(about: trigger)
            return trigger
        }
        let shown = ordered(open.filter { $0.count >= fewestTimes || $0.isAsking })
        return (Array(shown.prefix(self.shown)), ordered(found.values.filter { fine.contains($0.id) }))
    }

    /// A pattern's steps, read back from its id: for one that's fine and
    /// hasn't come up in the period.
    static func steps(of id: String) -> [AnalyzerTrigger.Step] {
        if id.hasPrefix(AnalyzerLessonRules.waitPrefix) {
            let parts = id.dropFirst(AnalyzerLessonRules.waitPrefix.count).split(separator: ">", maxSplits: 1).map(String.init)
            return [.init(label: parts.first ?? "", kind: .wait), .init(label: parts.count > 1 ? parts[1] : "", kind: .site)]
        }
        return id.split(separator: ">").map { .init(label: String($0), kind: $0.contains(".") ? .site : .app) }
    }

    /// The same triggers over the last `days` days only: their moments, a bar
    /// a day, and only those still a pattern there, most time first.
    static func recent(_ triggers: [AnalyzerTrigger], days: Int, now: Date, calendar: Calendar = .current) -> [AnalyzerTrigger] {
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -days, to: today) else { return triggers }
        return triggers.compactMap { trigger in
            var trigger = trigger
            trigger.moments = trigger.moments.filter { $0.start >= from && $0.start < today }
            trigger.perDay = (0..<days).map { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: from) else { return 0 }
                return trigger.counted.filter { calendar.isDate($0.start, inSameDayAs: day) }.count
            }
            return trigger.count >= fewestTimes || trigger.isAsking ? trigger : nil
        }
        .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
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

    /// Takes the marks off these moments: a pattern put back counts in full.
    static func clear(_ moments: [AnalyzerTrigger.Moment], _ defaults: UserDefaults = UITestMode.defaults) {
        let set = load(defaults).subtracting(moments.map(\.id))
        defaults.set(Array(set).sorted(), forKey: AnalyzerTriggers.ruledOutKey)
    }

    static func erase(_ defaults: UserDefaults = UITestMode.defaults) {
        defaults.removeObject(forKey: AnalyzerTriggers.ruledOutKey)
    }
}
