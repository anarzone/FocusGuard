import Foundation

/// The words on "While your tools worked", from plain values so they can be
/// tested: what the tools did on a project this week, and what the user did
/// while they did it. Every number in them is one the tools timed.
enum AnalyzerRunsCopy {
    typealias Project = AnalyzerRuns.Project
    typealias Run = AnalyzerRuns.Run

    /// One of the cards under the charts: a number and what it means.
    struct Tile: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
        let note: String
        /// The value is a sentence (a task's title), not a number.
        var isText = false
    }

    static func kicker(_ project: Project) -> String {
        String(localized: "While your tools worked · \(project.name)", comment: "Analyzer headline label, then the project")
    }

    /// Where the drifts went, the top two: "x.com or youtube.com".
    static func sites(_ project: Project) -> String {
        Array(project.sites.prefix(2)).formatted(.list(type: .or))
    }

    // MARK: Headline

    static func headline(_ project: Project, calm: Bool = false) -> String {
        let name = project.name
        if project.late > 0 {
            let time = AnalyzerFormat.compact(project.late)
            if calm {
                return String(localized: "\(time) back for \(name), in a week like this one",
                              comment: "Analyzer headline, what coming back on time is worth: a compact duration, then the project")
            }
            if project.tools.count == 1, let tool = project.tools.first {
                return String(localized: "\(tool) was done and waiting for you for \(time)",
                              comment: "Analyzer headline: the tool, then a compact duration")
            }
            return String(localized: "Your tools were done and waiting for you for \(time)",
                          comment: "Analyzer headline: a compact duration")
        }
        if project.drifts > 0 {
            return String(localized: "Nothing on \(name) sat finished while you were on a distraction",
                          comment: "Analyzer headline: the project. The user left during runs but was back before they finished")
        }
        let count = project.runs.count
        if count == 1 {
            return String(localized: "The one run on \(name) didn’t lose you to a distraction", comment: "Analyzer headline: the project")
        }
        return String(localized: "Not one of \(count) runs on \(name) lost you to a distraction",
                      comment: "Analyzer headline: how many runs (2 or more), then the project")
    }

    // MARK: Body

    static func body(_ project: Project, calm: Bool = false) -> String {
        if calm, project.late > 0 { return whatIf(project) }
        return [worked(project), left(project), stayed(project)].compactMap { $0 }.joined(separator: " ")
    }

    /// How much the tools did.
    static func worked(_ project: Project) -> String {
        let time = AnalyzerFormat.short(project.worked)
        let count = project.runs.count
        if count == 1 {
            return String(localized: "\(time) of tool work on \(project.name) this week, in one run.",
                          comment: "Analyzer: a duration, then the project")
        }
        let usual = AnalyzerFormat.short(project.usualRun)
        return String(localized: "\(time) of tool work on \(project.name) this week, in \(count) runs of about \(usual).",
                      comment: "Analyzer: a duration, the project, how many runs (2 or more), then what a run usually takes")
    }

    /// How often the user left for a distraction while a run went. Nil: never.
    static func left(_ project: Project) -> String? {
        let drifts = project.drifts
        guard drifts > 0 else { return nil }
        let sites = sites(project)
        if drifts == 1 {
            return String(localized: "Once you left for \(sites) while a run was going.", comment: "Analyzer: the site or two sites")
        }
        return String(localized: "\(drifts) times you left for \(sites) while a run was going.",
                      comment: "Analyzer: how many times (2 or more), then the site or two sites")
    }

    /// What happened when the run finished while they were away. Nil: they never left.
    static func stayed(_ project: Project) -> String? {
        let drifts = project.drifts, lateRuns = project.lateRuns
        guard drifts > 0 else { return nil }
        let usual = AnalyzerFormat.short(project.usualLate)
        switch (lateRuns, drifts) {
        case (0, 1):
            return String(localized: "You were off it by the time it finished.", comment: "Analyzer: after 'Once you left for x.com while a run was going.'")
        case (0, _):
            return String(localized: "Each time you were off it by the time it finished.", comment: "Analyzer: after 'N times you left for x.com while a run was going.'")
        case (1, 1):
            return String(localized: "It finished while you were there, and you stayed \(usual) more.",
                          comment: "Analyzer: after 'Once you left for x.com while a run was going.' A duration")
        case (1, _):
            return String(localized: "Once it finished while you were there, and you stayed \(usual) more.",
                          comment: "Analyzer: after 'N times you left for x.com while a run was going.' A duration")
        case _ where lateRuns == drifts:
            return String(localized: "Every time it finished while you were there, and you stayed about \(usual) more.",
                          comment: "Analyzer: after 'N times you left for x.com while a run was going.' A duration")
        default:
            return String(localized: "\(lateRuns) times it finished while you were there, and you stayed about \(usual) more.",
                          comment: "Analyzer: after 'N times you left for x.com while a run was going.' How many times (2 or more), then a duration")
        }
    }

    /// What the week looks like when they come back as a run finishes.
    static func whatIf(_ project: Project) -> String {
        let more = project.usualRun > 0 ? Int(project.late / project.usualRun) : 0
        let worth: String
        switch more {
        case 0:
            worth = String(localized: "That’s what coming back when it finishes is worth.", comment: "Analyzer: under the time the user would get back")
        case 1:
            worth = String(localized: "That’s what coming back when it finishes is worth: room for one more run like these.",
                           comment: "Analyzer: under the time the user would get back")
        default:
            worth = String(localized: "That’s what coming back when it finishes is worth: room for about \(more) more runs like these.",
                           comment: "Analyzer: under the time the user would get back. How many runs (2 or more)")
        }
        return worth + " " + String(localized: "FocusGuard tells you the moment it finishes, so you don’t have to keep checking.",
                                    comment: "Analyzer: about the card that shows when a tool finishes while the user is on a distraction")
    }

    // MARK: Numbers

    /// "12 runs", "1 run".
    static func runCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 run", comment: "Analyzer: one run of a tool")
            : String(localized: "\(count) runs", comment: "Analyzer: how many runs of a tool (0, or 2 or more)")
    }

    /// Under the number of runs: what one usually takes.
    static func runsLabel(_ project: Project) -> String {
        let usual = AnalyzerFormat.short(project.usualRun)
        return project.runs.count == 1
            ? String(localized: "run, \(usual) long", comment: "Analyzer, under the number 1: a duration")
            : String(localized: "runs, about \(usual) each", comment: "Analyzer, under a number of runs: what one usually takes")
    }

    /// "41m working · 12m waiting for you".
    static func split(worked: TimeInterval, late: TimeInterval) -> String {
        let work = AnalyzerFormat.compact(worked)
        if late <= 0 {
            return String(localized: "\(work) working · no waiting", comment: "Analyzer: how long the tools worked; no answer sat finished")
        }
        return String(localized: "\(work) working · \(AnalyzerFormat.compact(late)) waiting for you",
                      comment: "Analyzer: how long the tools worked, then how long their answers sat finished")
    }

    /// Why a project has no times, and what's known of it anyway.
    static func untimed(_ project: Project) -> String {
        let counts = String(localized: "Waits: \(project.untimed) · ended on a distraction: \(project.untimedDrifted)",
                            comment: "Analyzer: waits on a tool that can't be timed, then how many ended on a distraction")
        guard let tool = project.untimedTool else { return counts }
        return String(localized: "\(tool) doesn’t tell FocusGuard when it starts or finishes, so its runs aren’t timed.",
                      comment: "Analyzer: the tool") + " " + counts
    }

    /// A day in a few words, for the bar's tooltip: "Tuesday · 4 runs · 41m working · 12m waiting for you".
    static func day(_ name: String, runs: [Run]) -> String {
        guard !runs.isEmpty else {
            return name + " · " + String(localized: "No runs", comment: "Analyzer: a day no tool ran on")
        }
        let worked = runs.reduce(0) { $0 + $1.seconds }, late = runs.reduce(0) { $0 + $1.late }
        return [name, runCount(runs.count), split(worked: worked, late: late)].joined(separator: " · ")
    }

    // MARK: One run

    /// What happened on one run, in two short sentences.
    static func story(_ run: Run, clock: String) -> String {
        let time = AnalyzerFormat.exact(run.seconds)
        let first = run.asked
            ? String(localized: "\(clock) · \(run.tool) stopped after \(time) to ask you something.",
                     comment: "Analyzer, one run: the time of day, the tool, then how long it worked")
            : String(localized: "\(clock) · \(run.tool) worked for \(time).",
                     comment: "Analyzer, one run: the time of day, the tool, then how long it worked")
        return first + " " + meanwhile(run)
    }

    private static func meanwhile(_ run: Run) -> String {
        guard let site = run.to else {
            return run.asked ? String(localized: "No distraction got in the way.", comment: "Analyzer, one run that stopped to ask something")
                : String(localized: "No distraction during this one.", comment: "Analyzer, one run")
        }
        guard run.late > 0 else {
            return String(localized: "You left for \(site) and were off it before it needed you.", comment: "Analyzer, one run: the site")
        }
        let late = AnalyzerFormat.exact(run.late)
        if run.asked {
            return String(localized: "You were on \(site), and its question waited \(late). Nothing moved until you answered.",
                          comment: "Analyzer, one run that stopped to ask something: the site, then a duration")
        }
        return String(localized: "You left for \(site) and stayed \(late) after it had finished.",
                      comment: "Analyzer, one run: the site, then a duration")
    }

    /// Under the chart before a run is picked.
    static func hint(_ project: Project) -> String {
        project.late > 0
            ? String(localized: "Each bar is one run. The orange on top is how long it sat finished while you were on a distraction. Click a run to see what happened.",
                     comment: "Analyzer: how to read the chart of runs")
            : String(localized: "Each bar is one run. Click one to see what happened.", comment: "Analyzer: how to read the chart of runs")
    }

    static func emptyDay(_ project: Project) -> String {
        String(localized: "No tool worked on \(project.name) that day.", comment: "Analyzer: the project")
    }

    // MARK: Tiles

    static func tiles(_ project: Project) -> [Tile] {
        var tiles: [Tile] = []
        if project.drifts > 0 { tiles.append(leaving(project)) }
        if project.asked > 0 { tiles.append(asking(project)) }
        if let next = project.next {
            let note = String(localized: "Read it while the next run goes. FocusGuard puts it on the card when you leave for a distraction.",
                              comment: "Analyzer: under the project's next open task")
            tiles.append(Tile(id: "next", title: String(localized: "Next on \(project.name)", comment: "Analyzer tile: the project's next open task"),
                              value: next, note: note, isText: true))
        }
        return tiles
    }

    private static func leaving(_ project: Project) -> Tile {
        let title = String(localized: "When you leave for \(sites(project))", comment: "Analyzer tile: the site or two sites")
        let value = String(localized: "\(project.lateRuns) of \(project.drifts)")
        let run = AnalyzerFormat.short(project.usualRun)
        let note: String
        if project.lateRuns == 0 {
            note = project.drifts == 1
                ? String(localized: "You were off it before the run finished.", comment: "Analyzer tile note, under '0 of 1'")
                : String(localized: "Each time you were off it before the run finished.", comment: "Analyzer tile note, under '0 of 3'")
        } else {
            let more = AnalyzerFormat.short(project.usualLate)
            note = String(localized: "That’s how often it had finished and you were still there, usually for \(more) more. A run itself takes about \(run).",
                          comment: "Analyzer tile note, under '3 of 5': how long the user stays after a run finished, then what a run takes")
        }
        return Tile(id: "leaving", title: title, value: value, note: note)
    }

    private static func asking(_ project: Project) -> Tile {
        let title = String(localized: "It stopped to ask you", comment: "Analyzer tile and legend: a tool needed the user's answer")
        let value = String(localized: "\(project.asked)×", comment: "How many times a trigger happened: 14×")
        let note: String
        if project.askedAway == 0 {
            note = String(localized: "Not once were you on a distraction when it asked.", comment: "Analyzer tile note")
        } else {
            let late = AnalyzerFormat.short(project.askedLate)
            note = String(localized: "\(project.askedAway)× you were on a distraction when it asked: \(late) with nothing moving until you answered. FocusGuard tells you the moment it asks.",
                          comment: "Analyzer tile note: how many times, then a duration")
        }
        return Tile(id: "asking", title: title, value: value, note: note)
    }
}
