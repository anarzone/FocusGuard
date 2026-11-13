import Foundation

/// What the user's corrections taught the Analyzer, so the same thing isn't
/// counted again tomorrow: patterns that are fine for them ("youtube.com
/// after Xcode"), patterns they said aren't a rule, and what they called
/// work in a session.
struct AnalyzerLessons: Codable, Equatable, Sendable {
    /// "It's for work", said about one site or app.
    struct WorkAnswer: Codable, Equatable, Sendable, Identifiable {
        /// The site's host, or the app's bundle id.
        let key: String
        var name: String
        let isSite: Bool
        /// The days it was said on, oldest first, each once.
        var days: [Date]
        /// Answered: counted as work, or "Keep asking". Never suggested again.
        var settled = false
        /// The answer was "Count it as work".
        var countedAsWork = false

        var id: String { key }
    }

    /// Trigger ids that are fine: "Xcode>youtube.com", "wait:Claude Code>x.com".
    var fine: [String] = []
    /// Asked about once, and the answer was "just those times".
    var declined: [String] = []
    var work: [WorkAnswer] = []

    var isEmpty: Bool { fine.isEmpty && declined.isEmpty && work.isEmpty }
    var fineSet: Set<String> { Set(fine) }
    /// The fine ones that are a site while a tool works: no drift card for those.
    var fineWaits: Set<String> { Set(fine.filter { $0.hasPrefix(AnalyzerLessonRules.waitPrefix) }) }

    /// The waits as the user sees them: one that went to a site that's fine
    /// while that tool works was no drift, as it won't be from now on.
    func settled(_ waits: [WaitRecord]) -> [WaitRecord] {
        let fine = fineWaits
        guard !fine.isEmpty else { return waits }
        return waits.map { wait in
            guard let to = wait.to, fine.contains(AnalyzerLessonRules.waitID(tool: wait.tool, site: to)) else { return wait }
            var stayed = WaitRecord(start: wait.start, tool: wait.tool, project: wait.project, seconds: wait.seconds, drift: 0)
            stayed.exact = wait.exact
            stayed.worked = wait.worked
            stayed.ran = wait.ran
            return stayed
        }
    }

    /// Whether to ask if the whole pattern is fine: the user ruled out enough
    /// of its moments, and hasn't answered about it before.
    func asks(about trigger: AnalyzerTrigger) -> Bool {
        guard !fine.contains(trigger.id), !declined.contains(trigger.id) else { return false }
        return trigger.moments.filter(\.isRuledOut).count >= AnalyzerLessonRules.asksAfter
    }

    /// "Yes, it's fine".
    mutating func teach(_ id: String) {
        declined.removeAll { $0 == id }
        if !fine.contains(id) { fine.append(id) }
    }

    /// "No, just those times": it won't ask about this one again.
    mutating func decline(_ id: String) {
        if !declined.contains(id) { declined.append(id) }
    }

    /// "Put it back": the pattern counts again, and can be asked about again.
    mutating func forget(_ id: String) {
        fine.removeAll { $0 == id }
        declined.removeAll { $0 == id }
    }

    /// "It's for work" was said in a session.
    mutating func saidForWork(key: String, name: String, isSite: Bool, at now: Date, calendar: Calendar = .current) {
        guard !key.isEmpty else { return }
        let day = calendar.startOfDay(for: now)
        if let index = work.firstIndex(where: { $0.key == key }) {
            if !name.isEmpty { work[index].name = name }
            if !work[index].days.contains(day) { work[index].days.append(day) }
            work[index].days = Array(work[index].days.suffix(AnalyzerLessonRules.daysKept))
        } else {
            work.append(WorkAnswer(key: key, name: name.isEmpty ? key : name, isSite: isSite, days: [day]))
        }
    }

    /// What to suggest counting as work: said on enough days, not answered yet.
    /// One at a time, the one said most recently.
    func workSuggestion(isStillCaught: (WorkAnswer) -> Bool = { _ in true }) -> WorkAnswer? {
        work.filter { !$0.settled && $0.days.count >= AnalyzerLessonRules.workDays && isStillCaught($0) }
            .max { ($0.days.last ?? .distantPast) < ($1.days.last ?? .distantPast) }
    }

    mutating func settleWork(_ key: String, countedAsWork: Bool = false) {
        guard let index = work.firstIndex(where: { $0.key == key }) else { return }
        work[index].settled = true
        work[index].countedAsWork = countedAsWork
    }

    /// Said for work on enough days, and not answered yet: count it as work
    /// now. Two separate days of "It's for work" are the user's own word.
    func dueAsWork(_ key: String) -> WorkAnswer? {
        work.first { $0.key == key && !$0.settled && $0.days.count >= AnalyzerLessonRules.workDays }
    }

    /// "Put it back": caught again, and never counted as work on its own again.
    mutating func uncountWork(_ key: String) {
        guard let index = work.firstIndex(where: { $0.key == key }) else { return }
        work[index].settled = true
        work[index].countedAsWork = false
    }

    /// What was sorted as work from here, latest first.
    var countedAsWork: [WorkAnswer] { work.filter(\.countedAsWork).reversed() }
}

enum AnalyzerLessonRules {
    /// Moments ruled out in one pattern before it asks about the pattern.
    static let asksAfter = 2
    /// Days "It's for work" was said about one site before it suggests counting it as work.
    static let workDays = 2
    static let daysKept = 5
    static let waitPrefix = "wait:"

    /// The id of the trigger a wait on `tool` that went to `site` belongs to.
    static func waitID(tool: String, site: String) -> String { "\(waitPrefix)\(tool)>\(site)" }
}
