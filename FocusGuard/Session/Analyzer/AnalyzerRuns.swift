import Foundation

/// What happened while the tools worked, over the last 7 days, a project at
/// a time: how long each tool really ran (`RunRecord`, the tool's own word)
/// and how long its answer sat while the user was on a distraction (the
/// waits on those runs). Nothing here is a guess: a run with no wait on it
/// just has no distraction to its name.
struct AnalyzerRuns: Equatable {
    /// Runs in the week before there's anything worth a headline.
    static let enoughRuns = 3

    /// One run, and what the user did while it went.
    struct Run: Equatable, Identifiable {
        let id: Int
        let start: Date
        let tool: String
        let seconds: TimeInterval
        /// It stopped to ask the user something, rather than finishing.
        let asked: Bool
        /// The distraction they left for while it went: "x.com". Nil: none.
        var to: String?
        /// How long its answer sat while they were on that distraction.
        var late: TimeInterval = 0

        var drifted: Bool { to != nil }
    }

    struct Project: Equatable, Identifiable {
        let name: String
        /// Its runs this week, oldest first. Empty: none of its tools says when it starts.
        var runs: [Run] = []
        /// The same runs, in each of the 7 days, oldest day first.
        var days: [[Run]] = Array(repeating: [], count: 7)
        /// Waits on a tool that doesn't say when it starts, and how many ended on a distraction.
        var untimed = 0
        var untimedDrifted = 0
        var untimedTool: String?
        /// Its next open task, when one fits the project.
        var next: String?

        var id: String { name }
        var isTimed: Bool { !runs.isEmpty }
        /// How long the tools worked on it.
        var worked: TimeInterval { runs.reduce(0) { $0 + $1.seconds } }
        /// How long their answers sat while the user was on a distraction.
        var late: TimeInterval { runs.reduce(0) { $0 + $1.late } }
        /// What a run usually takes: the middle one.
        var usualRun: TimeInterval { AnalyzerRuns.median(runs.map(\.seconds)) }
        /// Runs the user left for a distraction during.
        var drifts: Int { runs.filter(\.drifted).count }
        /// Of those, the ones that finished while they were still on it.
        var lateRuns: Int { runs.filter { $0.late > 0 }.count }
        /// How long they usually stay after it has finished.
        var usualLate: TimeInterval { AnalyzerRuns.median(runs.map(\.late).filter { $0 > 0 }) }
        /// Runs that stopped to ask something.
        var asked: Int { runs.filter(\.asked).count }
        /// Of those, the ones whose question sat while they were on a distraction, and for how long.
        var askedAway: Int { runs.filter { $0.asked && $0.late > 0 }.count }
        var askedLate: TimeInterval { runs.filter(\.asked).reduce(0) { $0 + $1.late } }
        /// The tools that ran on it, most runs first.
        var tools: [String] { AnalyzerRuns.ranked(runs.map(\.tool)) }
        /// Where the drifts went, most often first.
        var sites: [String] { AnalyzerRuns.ranked(runs.compactMap(\.to)) }
        /// The day to open on: the one whose answers sat longest, else the
        /// latest with a run.
        var defaultDay: Int {
            let late = days.map { $0.reduce(0) { $0 + $1.late } }
            if let most = late.max(), most > 0, let day = late.lastIndex(of: most) { return day }
            return days.lastIndex { !$0.isEmpty } ?? days.count - 1
        }
        /// The tool and the site most often left for: what a hold would be on.
        var pair: (tool: String, site: String)? {
            let pairs = runs.compactMap { run in run.to.map { "\(run.tool)\u{1F}\($0)" } }
            guard let top = AnalyzerRuns.ranked(pairs).first else { return nil }
            let parts = top.components(separatedBy: "\u{1F}")
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// The first of the 7 days.
    var firstDay: Date?
    /// Timed projects first, most tool time first; then the ones that can't be timed.
    var projects: [Project] = []

    var runCount: Int { projects.reduce(0) { $0 + $1.runs.count } }
    /// Enough runs this week to say something about them.
    var isWorthShowing: Bool { runCount >= Self.enoughRuns }

    /// - Parameters:
    ///   - runs: the week's runs, as the tools timed them.
    ///   - waits: the week's waits. One on a run names it by its start (`ran`).
    static func make(runs: [RunRecord], waits: [WaitRecord], now: Date = .now, calendar: Calendar = .current) -> AnalyzerRuns {
        var summary = AnalyzerRuns()
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        summary.firstDay = first
        let other = String(localized: "Other", comment: "Analyzer: waits with no project")

        var onRun: [String: [WaitRecord]] = [:]
        for wait in waits {
            guard let ran = wait.ran else { continue }
            onRun[key(wait.tool, ran), default: []].append(wait)
        }

        var byProject: [String: Project] = [:]
        for (index, record) in runs.sorted(by: { $0.start < $1.start }).enumerated() {
            let day = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: record.start)).day ?? -1
            guard (0..<7).contains(day) else { continue }
            var run = Run(id: index, start: record.start, tool: record.tool, seconds: record.seconds, asked: record.asked)
            let drifted = (onRun[key(record.tool, record.start)] ?? []).filter(\.drifted)
            if !drifted.isEmpty {
                run.late = drifted.reduce(0) { $0 + ($1.late ?? 0) }
                // The site it sat finished for, else the first one left for.
                let stayed = drifted.max { ($0.late ?? 0) < ($1.late ?? 0) }
                run.to = (stayed?.late ?? 0) > 0 ? stayed?.to : drifted.first?.to
                if run.to == nil { run.to = drifted.compactMap(\.to).first }
            }
            let name = record.project ?? other
            var project = byProject[name] ?? Project(name: name)
            project.runs.append(run)
            project.days[day].append(run)
            byProject[name] = project
        }

        // Waits on a tool that never said it was working: its runs can't be timed.
        for wait in waits where !wait.exact {
            let name = wait.project ?? other
            var project = byProject[name] ?? Project(name: name)
            project.untimed += 1
            if wait.drifted { project.untimedDrifted += 1 }
            byProject[name] = project
        }
        for name in byProject.keys {
            let tools = waits.filter { !$0.exact && ($0.project ?? other) == name }.map(\.tool)
            byProject[name]?.untimedTool = ranked(tools).first
        }

        let timed = byProject.values.filter(\.isTimed).sorted {
            let a = $0.worked + $0.late, b = $1.worked + $1.late
            return a != b ? a > b : $0.name < $1.name
        }
        let untimed = byProject.values.filter { !$0.isTimed && $0.untimed > 0 }.sorted {
            $0.untimed != $1.untimed ? $0.untimed > $1.untimed : $0.name < $1.name
        }
        summary.projects = timed + untimed
        return summary
    }

    /// A run by its tool and its start, to the second: how a wait names the run it was on.
    private static func key(_ tool: String, _ start: Date) -> String {
        "\(tool)|\(Int(start.timeIntervalSinceReferenceDate.rounded(.down)))"
    }

    /// The minute marks a chart of runs up to `most` long gets: a few round
    /// ones below its top. None when everything is under about a minute.
    static func gridMinutes(most seconds: TimeInterval) -> [Int] {
        let top = seconds / 60
        guard top >= 1.2 else { return [] }
        let step = [1, 2, 5, 10, 15, 30, 60, 120, 240].first { top / Double($0) <= 3.5 } ?? 480
        return stride(from: step, to: Int((top * 0.95).rounded(.up)), by: step).map { $0 }
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Each name once, the most frequent first, ties by name.
    static func ranked(_ names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// The hold on a site while a tool works, as the headline's button shows it.
enum AnalyzerRunsHold: Equatable {
    case none
    /// A test of it is running.
    case testing
    case kept(minutes: Int)
}

extension AnalyzerState {
    /// Whether `site` is already held while `tool` works: kept, or under test.
    func hold(tool: String, site: String) -> AnalyzerRunsHold {
        for kept in kept {
            if case let .holdInWait(heldTool, heldSite, seconds) = kept.fix.change, heldTool == tool, heldSite == site {
                return .kept(minutes: max(1, seconds / 60))
            }
        }
        if case let .holdInWait(heldTool, heldSite, _)? = experiment?.fix.change, heldTool == tool, heldSite == site {
            return .testing
        }
        return .none
    }
}
