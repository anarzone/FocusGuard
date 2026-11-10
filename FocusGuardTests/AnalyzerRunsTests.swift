import XCTest
@testable import FocusGuard

/// "While your tools worked": the runs a project's tools timed this week,
/// the waits on them, and what the Analyzer's headline says about them.
@MainActor
final class AnalyzerRunsTests: XCTestCase {
    typealias F = CoachFixture
    typealias Copy = AnalyzerRunsCopy
    private let calendar = CoachFixture.calendar
    /// Sunday evening: the 7 days are Monday (day 0) to Sunday (day 6).
    private let now = CoachFixture.at(6, 18)

    private func run(_ day: Int, _ hour: Int, _ minutes: Double, tool: String = "Claude Code", project: String? = "Curiplay",
                     asked: Bool = false) -> RunRecord {
        RunRecord(start: F.at(day, hour), tool: tool, project: project, seconds: minutes * 60, asked: asked)
    }

    /// A wait on `run`: they left a minute in for `site`, and came back
    /// `late` minutes after it had finished (nil: before it did).
    private func wait(on run: RunRecord, to site: String = "x.com", late: Double? = nil, drifted: Bool = true) -> WaitRecord {
        let away = run.seconds - 60 + (late ?? 0) * 60
        return WaitRecord(start: run.start.addingTimeInterval(60), tool: run.tool, project: run.project, seconds: away,
                          drift: drifted ? away : 0, to: drifted ? site : nil, exact: true, worked: run.seconds, ran: run.start,
                          late: late.map { $0 * 60 })
    }

    private func make(_ runs: [RunRecord], _ waits: [WaitRecord] = []) -> AnalyzerRuns {
        AnalyzerRuns.make(runs: runs, waits: waits, now: now, calendar: calendar)
    }

    /// Five runs on Curiplay over two days: one left alone, one that sat 6
    /// min, one left for and returned to in time, a question that sat 2 min
    /// on YouTube, and one that sat 4 min.
    private func curiplay(tool second: String = "Claude Code") throws -> AnalyzerRuns.Project {
        let runs = [run(1, 10, 4), run(1, 11, 10, tool: second), run(1, 13, 6), run(1, 14, 8, asked: true), run(2, 10, 12)]
        let waits = [wait(on: runs[1], late: 6), wait(on: runs[2]), wait(on: runs[3], to: "youtube.com", late: 2), wait(on: runs[4], late: 4)]
        return try XCTUnwrap(make(runs, waits).projects.first)
    }

    // MARK: The runs and their waits

    func testAWaitIsPutOnItsRunByTheRunsStart() throws {
        let runs = [run(1, 10, 4), run(1, 11, 10)]
        let project = try XCTUnwrap(make(runs, [wait(on: runs[1], late: 5)]).projects.first)
        XCTAssertEqual(project.runs.map(\.late), [0, 300])
        XCTAssertEqual(project.runs.map(\.to), [nil, "x.com"])
        XCTAssertEqual(project.worked, 14 * 60)
        XCTAssertEqual(project.late, 300)
        XCTAssertEqual(project.drifts, 1)
        XCTAssertEqual(project.lateRuns, 1)
    }

    func testAWaitTheyStayedWithTheWorkForIsNoDistraction() throws {
        let runs = [run(1, 10, 4), run(1, 11, 10), run(1, 12, 5)]
        let project = try XCTUnwrap(make(runs, [wait(on: runs[1], drifted: false)]).projects.first)
        XCTAssertEqual(project.drifts, 0)
        XCTAssertEqual(project.late, 0)
    }

    func testADriftThatEndedBeforeTheFinishIsNotLate() throws {
        let runs = [run(1, 10, 4), run(1, 11, 10)]
        let project = try XCTUnwrap(make(runs, [wait(on: runs[1])]).projects.first)
        XCTAssertEqual(project.drifts, 1)
        XCTAssertEqual(project.lateRuns, 0)
        XCTAssertEqual(project.runs[1].to, "x.com")
    }

    func testTwoToolsStartingTogetherKeepTheirOwnWaits() throws {
        let runs = [run(1, 10, 4), run(1, 10, 9, tool: "Codex")]
        let project = try XCTUnwrap(make(runs, [wait(on: runs[1], late: 3)]).projects.first)
        XCTAssertEqual(project.runs.first { $0.tool == "Codex" }?.late, 180)
        XCTAssertEqual(project.runs.first { $0.tool == "Claude Code" }?.drifted, false)
    }

    func testTwoDriftsOnOneRunAddUpAndNameWhereItSat() throws {
        let runs = [run(1, 10, 10)]
        let waits = [wait(on: runs[0]), wait(on: runs[0], to: "youtube.com", late: 3)]
        let only = try XCTUnwrap(make(runs, waits).projects.first?.runs.first)
        XCTAssertEqual(only.late, 180)
        XCTAssertEqual(only.to, "youtube.com", "The one it sat finished for")
    }

    func testRunsFallIntoTheLastSevenDays() throws {
        let summary = make([run(-1, 10, 5), run(0, 10, 5), run(3, 9, 5), run(3, 15, 5), run(6, 10, 5)])
        XCTAssertEqual(summary.firstDay, F.at(0, 0))
        let project = try XCTUnwrap(summary.projects.first)
        XCTAssertEqual(project.runs.count, 4, "The one before the week is left out")
        XCTAssertEqual(project.days.map(\.count), [1, 0, 0, 2, 0, 0, 1])
        XCTAssertEqual(project.runs.map(\.id), [1, 2, 3, 4])
    }

    func testTimedProjectsComeFirstByToolTimeThenTheOnesThatCantBeTimed() {
        let runs = [run(1, 10, 20), run(1, 11, 30, project: "FocusGuard"), run(1, 12, 3, project: nil)]
        let untimed = [WaitRecord(start: F.at(2, 9), tool: "Aider", project: "dotfiles", seconds: 240, drift: 180, to: "youtube.com"),
                       WaitRecord(start: F.at(3, 9), tool: "Aider", project: "dotfiles", seconds: 200, drift: 0)]
        let summary = make(runs, untimed)
        XCTAssertEqual(summary.projects.map(\.name), ["FocusGuard", "Curiplay", "Other", "dotfiles"])
        let dotfiles = summary.projects[3]
        XCTAssertFalse(dotfiles.isTimed)
        XCTAssertEqual(dotfiles.untimed, 2)
        XCTAssertEqual(dotfiles.untimedDrifted, 1)
        XCTAssertEqual(dotfiles.untimedTool, "Aider")
        XCTAssertEqual(summary.runCount, 3)
    }

    func testThreeRunsMakeItWorthShowing() {
        XCTAssertFalse(make([run(1, 10, 5), run(1, 11, 5)]).isWorthShowing)
        XCTAssertTrue(make([run(1, 10, 5), run(1, 11, 5), run(2, 11, 5, project: "FocusGuard")]).isWorthShowing)
        XCTAssertFalse(AnalyzerRuns().isWorthShowing)
    }

    func testTheUsualTimesAreTheMiddleOnes() throws {
        let project = try curiplay()
        XCTAssertEqual(project.usualRun, 8 * 60, "Of 4, 6, 8, 10 and 12 min")
        XCTAssertEqual(project.usualLate, 4 * 60, "Of 2, 4 and 6 min: the runs it didn't sit on don't count")
        XCTAssertEqual(AnalyzerRuns.median([60, 120]), 90)
        XCTAssertEqual(AnalyzerRuns.median([]), 0)
    }

    func testWhatAProjectKnowsOfItsWeek() throws {
        let project = try curiplay()
        XCTAssertEqual(project.worked, 40 * 60)
        XCTAssertEqual(project.late, 12 * 60)
        XCTAssertEqual(project.drifts, 4)
        XCTAssertEqual(project.lateRuns, 3)
        XCTAssertEqual(project.asked, 1)
        XCTAssertEqual(project.askedAway, 1)
        XCTAssertEqual(project.askedLate, 120)
        XCTAssertEqual(project.tools, ["Claude Code"])
        XCTAssertEqual(project.sites, ["x.com", "youtube.com"])
        XCTAssertEqual(project.pair?.tool, "Claude Code")
        XCTAssertEqual(project.pair?.site, "x.com")
    }

    func testItOpensOnTheDayTheAnswersSatLongest() throws {
        XCTAssertEqual(try curiplay().defaultDay, 1, "8 min on Tuesday, 4 on Wednesday")
        let calm = try XCTUnwrap(make([run(0, 10, 5), run(4, 10, 5), run(2, 10, 5)]).projects.first)
        XCTAssertEqual(calm.defaultDay, 4, "Nothing sat: the latest day with a run")
        XCTAssertEqual(AnalyzerRuns.Project(name: "Empty").defaultDay, 6)
    }

    func testTheChartsMinuteMarksAreAFewRoundOnes() {
        XCTAssertEqual(AnalyzerRuns.gridMinutes(most: 50), [], "Under a minute or so there's nothing to mark")
        XCTAssertEqual(AnalyzerRuns.gridMinutes(most: 5 * 60), [2, 4])
        XCTAssertEqual(AnalyzerRuns.gridMinutes(most: 14 * 60), [5, 10])
        XCTAssertEqual(AnalyzerRuns.gridMinutes(most: 3600), [30])
    }

    // MARK: The hold, as the button shows it

    func testTheHoldIsKeptUnderTestOrNotThere() {
        let fix = AnalyzerFix(cause: .habit, change: .holdInWait(tool: "Claude Code", site: "x.com", seconds: 120), measure: .longestStretch)
        var state = AnalyzerState()
        XCTAssertEqual(state.hold(tool: "Claude Code", site: "x.com"), .none)
        state.experiment = AnalyzerExperiment(fix: fix, plan: "", seed: 1, startedAt: now, slots: [])
        XCTAssertEqual(state.hold(tool: "Claude Code", site: "x.com"), .testing)
        XCTAssertEqual(state.hold(tool: "Codex", site: "x.com"), .none, "Another tool's wait isn't part of it")
        XCTAssertEqual(state.hold(tool: "Claude Code", site: "youtube.com"), .none)
        state.experiment = nil
        state.kept = [AnalyzerKept(fix: fix, plan: "", undo: .nothing, day: now)]
        XCTAssertEqual(state.hold(tool: "Claude Code", site: "x.com"), .kept(minutes: 2))
    }

    // MARK: The words

    func testTheHeadlineSaysHowLongTheAnswersSat() throws {
        let project = try curiplay()
        XCTAssertEqual(Copy.kicker(project), "While your tools worked · Curiplay")
        XCTAssertEqual(Copy.headline(project), "Claude Code was done and waiting for you for 12m")
        XCTAssertEqual(Copy.headline(project, calm: true), "12m back for Curiplay, in a week like this one")
        XCTAssertEqual(Copy.headline(try curiplay(tool: "Codex")), "Your tools were done and waiting for you for 12m")
    }

    func testAWeekNothingSatGetsAHeadlineThatSaysSo() throws {
        let runs = [run(1, 10, 4), run(1, 11, 10), run(2, 11, 6)]
        let back = try XCTUnwrap(make(runs, [wait(on: runs[1])]).projects.first)
        XCTAssertEqual(Copy.headline(back), "Nothing on Curiplay sat finished while you were on a distraction")
        XCTAssertEqual(Copy.headline(back, calm: true), Copy.headline(back), "There's no what-if without something that sat")
        let clean = try XCTUnwrap(make(runs).projects.first)
        XCTAssertEqual(Copy.headline(clean), "Not one of 3 runs on Curiplay lost you to a distraction")
        let one = try XCTUnwrap(make([run(1, 10, 4)]).projects.first)
        XCTAssertEqual(Copy.headline(one), "The one run on Curiplay didn’t lose you to a distraction")
    }

    func testTheBodyCountsTheRunsTheLeavingAndTheStaying() throws {
        XCTAssertEqual(Copy.body(try curiplay()),
                       "40 min of tool work on Curiplay this week, in 5 runs of about 8 min. "
                       + "4 times you left for x.com or youtube.com while a run was going. "
                       + "3 times it finished while you were there, and you stayed about 4 min more.")
        let runs = [run(1, 10, 4), run(1, 11, 10), run(2, 11, 6)]
        XCTAssertEqual(Copy.body(try XCTUnwrap(make(runs).projects.first)), "20 min of tool work on Curiplay this week, in 3 runs of about 6 min.")
        XCTAssertEqual(Copy.body(try XCTUnwrap(make([run(1, 10, 4)]).projects.first)), "4 min of tool work on Curiplay this week, in one run.")
    }

    func testWhatHappenedAtTheFinishIsSaidForEachCount() throws {
        let runs = [run(1, 10, 4), run(1, 11, 10), run(2, 11, 6)]
        func stayed(_ waits: [WaitRecord]) throws -> String? { Copy.stayed(try XCTUnwrap(make(runs, waits).projects.first)) }
        func left(_ waits: [WaitRecord]) throws -> String? { Copy.left(try XCTUnwrap(make(runs, waits).projects.first)) }
        XCTAssertNil(try stayed([]))
        XCTAssertNil(try left([]))
        XCTAssertEqual(try left([wait(on: runs[0])]), "Once you left for x.com while a run was going.")
        XCTAssertEqual(try stayed([wait(on: runs[0])]), "You were off it by the time it finished.")
        XCTAssertEqual(try stayed([wait(on: runs[0]), wait(on: runs[1])]), "Each time you were off it by the time it finished.")
        XCTAssertEqual(try stayed([wait(on: runs[0], late: 3)]), "It finished while you were there, and you stayed 3 min more.")
        XCTAssertEqual(try stayed([wait(on: runs[0], late: 3), wait(on: runs[1])]),
                       "Once it finished while you were there, and you stayed 3 min more.")
        XCTAssertEqual(try stayed([wait(on: runs[0], late: 3), wait(on: runs[1], late: 5)]),
                       "Every time it finished while you were there, and you stayed about 4 min more.")
        XCTAssertEqual(try stayed([wait(on: runs[0], late: 3), wait(on: runs[1], late: 5), wait(on: runs[2])]),
                       "2 times it finished while you were there, and you stayed about 4 min more.")
    }

    func testTheWhatIfSaysWhatTheTimeIsWorth() throws {
        let tells = " FocusGuard tells you the moment it finishes, so you don’t have to keep checking."
        XCTAssertEqual(Copy.body(try curiplay(), calm: true),
                       "That’s what coming back when it finishes is worth: room for one more run like these." + tells)
        let runs = [run(1, 10, 4), run(1, 11, 4), run(2, 11, 4)]
        let long = try XCTUnwrap(make(runs, [wait(on: runs[0], late: 9)]).projects.first)
        XCTAssertEqual(Copy.whatIf(long), "That’s what coming back when it finishes is worth: room for about 2 more runs like these." + tells)
        let short = try XCTUnwrap(make(runs, [wait(on: runs[0], late: 2)]).projects.first)
        XCTAssertEqual(Copy.whatIf(short), "That’s what coming back when it finishes is worth." + tells)
    }

    func testOneRunsStorySaysWhatTheToolAndTheUserDid() throws {
        let runs = try curiplay().runs
        XCTAssertEqual(Copy.story(runs[0], clock: "10:00"), "10:00 · Claude Code worked for 4 min. No distraction during this one.")
        XCTAssertEqual(Copy.story(runs[1], clock: "11:00"),
                       "11:00 · Claude Code worked for 10 min. You left for x.com and stayed 6 min after it had finished.")
        XCTAssertEqual(Copy.story(runs[2], clock: "13:00"),
                       "13:00 · Claude Code worked for 6 min. You left for x.com and were off it before it needed you.")
        XCTAssertEqual(Copy.story(runs[3], clock: "14:00"),
                       "14:00 · Claude Code stopped after 8 min to ask you something. "
                       + "You were on youtube.com, and its question waited 2 min. Nothing moved until you answered.")
        let asked = AnalyzerRuns.Run(id: 0, start: now, tool: "Codex", seconds: 250, asked: true)
        XCTAssertEqual(Copy.story(asked, clock: "9:05"), "9:05 · Codex stopped after 4m 10s to ask you something. No distraction got in the way.")
    }

    func testTheTilesSayHowOftenAndWhatsNext() throws {
        var project = try curiplay()
        var tiles = Copy.tiles(project)
        XCTAssertEqual(tiles.map(\.id), ["leaving", "asking"])
        XCTAssertEqual(tiles[0].title, "When you leave for x.com or youtube.com")
        XCTAssertEqual(tiles[0].value, "3 of 4")
        XCTAssertEqual(tiles[0].note, "That’s how often it had finished and you were still there, usually for 4 min more. A run itself takes about 8 min.")
        XCTAssertEqual(tiles[1].title, "It stopped to ask you")
        XCTAssertEqual(tiles[1].value, "1×")
        XCTAssertEqual(tiles[1].note, "1× you were on a distraction when it asked: 2 min with nothing moving until you answered. "
                       + "FocusGuard tells you the moment it asks.")

        project.next = "Fix the paywall copy"
        tiles = Copy.tiles(project)
        XCTAssertEqual(tiles.last?.title, "Next on Curiplay")
        XCTAssertEqual(tiles.last?.value, "Fix the paywall copy")
        XCTAssertEqual(tiles.last?.isText, true)

        let runs = [run(1, 10, 4), run(1, 11, 10, asked: true), run(2, 11, 6)]
        let back = Copy.tiles(try XCTUnwrap(make(runs, [wait(on: runs[0])]).projects.first))
        XCTAssertEqual(back.map(\.value), ["0 of 1", "1×"])
        XCTAssertEqual(back[0].note, "You were off it before the run finished.")
        let twice = Copy.tiles(try XCTUnwrap(make(runs, [wait(on: runs[0]), wait(on: runs[2])]).projects.first))
        XCTAssertEqual(twice[0].value, "0 of 2")
        XCTAssertEqual(twice[0].note, "Each time you were off it before the run finished.")
        XCTAssertEqual(back[1].note, "Not once were you on a distraction when it asked.")
        XCTAssertTrue(Copy.tiles(try XCTUnwrap(make([run(1, 10, 4)]).projects.first)).isEmpty, "Nothing to say: no tiles")
    }

    func testTheSmallLabels() throws {
        let project = try curiplay()
        XCTAssertEqual(Copy.runCount(1), "1 run")
        XCTAssertEqual(Copy.runCount(12), "12 runs")
        XCTAssertEqual(Copy.runsLabel(project), "runs, about 8 min each")
        XCTAssertEqual(Copy.runsLabel(try XCTUnwrap(make([run(1, 10, 4)]).projects.first)), "run, 4 min long")
        XCTAssertEqual(Copy.split(worked: 2400, late: 0), "40m working · no waiting")
        XCTAssertEqual(Copy.split(worked: 2400, late: 720), "40m working · 12m waiting for you")
        XCTAssertEqual(Copy.day("Tuesday", runs: project.days[1]), "Tuesday · 4 runs · 28m working · 8m waiting for you")
        XCTAssertEqual(Copy.day("Saturday", runs: []), "Saturday · No runs")
        XCTAssertEqual(Copy.emptyDay(project), "No tool worked on Curiplay that day.")
        XCTAssertTrue(Copy.hint(project).contains("orange"), "The orange is explained while there is some")
        XCTAssertEqual(Copy.hint(try XCTUnwrap(make([run(1, 10, 4)]).projects.first)), "Each bar is one run. Click one to see what happened.")
    }

    func testAProjectThatCantBeTimedSaysWhy() {
        var project = AnalyzerRuns.Project(name: "dotfiles")
        project.untimed = 2
        project.untimedDrifted = 1
        XCTAssertEqual(Copy.untimed(project), "Waits: 2 · ended on a distraction: 1")
        project.untimedTool = "Aider"
        XCTAssertEqual(Copy.untimed(project),
                       "Aider doesn’t tell FocusGuard when it starts or finishes, so its runs aren’t timed. Waits: 2 · ended on a distraction: 1")
    }

    // MARK: The charts' sizes

    func testABarSharesItsRoomBetweenWorkAndWaiting() {
        let even = AnalyzerRunsBar.widths(worked: 300, late: 300, most: 600, room: 102)
        XCTAssertEqual(even.work, 50, accuracy: 0.001)
        XCTAssertEqual(even.late, 50, accuracy: 0.001, "The 2pt gap between them is left out")
        let alone = AnalyzerRunsBar.widths(worked: 300, late: 0, most: 600, room: 100)
        XCTAssertEqual(alone.work, 50, accuracy: 0.001)
        XCTAssertEqual(alone.late, 0)
        XCTAssertEqual(AnalyzerRunsBar.widths(worked: 1, late: 0, most: 6000, room: 100).work, 3, "A short one can still be seen")
        XCTAssertEqual(AnalyzerRunsBar.widths(worked: 300, late: 0, most: 0, room: 100).work, 0)

        let stack = AnalyzerRunsStack.heights(worked: 300, late: 150, most: 600, room: 102)
        XCTAssertEqual(stack.work, 50, accuracy: 0.001)
        XCTAssertEqual(stack.late, 25, accuracy: 0.001)
        XCTAssertEqual(AnalyzerRunsStack.heights(worked: 0, late: 0, most: 600, room: 102).work, 0)
        XCTAssertEqual(AnalyzerRunsStack.heights(worked: 600, late: 1, most: 601, room: 102).late, 3)
    }

    func testRunsShareTheChartsWidthUntilTheyGetTooThin() {
        XCTAssertEqual(AnalyzerRunsPlot.columnWidth(room: 300, count: 3), 64, "A few runs don't stretch across it")
        XCTAssertEqual(AnalyzerRunsPlot.columnWidth(room: 300, count: 10), 30)
        XCTAssertEqual(AnalyzerRunsPlot.columnWidth(room: 300, count: 60), 14, "Then the chart scrolls")
        XCTAssertEqual(AnalyzerRunsPlot.timeStride(column: 64), 1)
        XCTAssertEqual(AnalyzerRunsPlot.timeStride(column: 14), 3)
    }

    func testADayIsNamedInTheCalendarsOwnTimeZone() {
        XCTAssertEqual(AnalyzerRunsSection.dayName(1, from: F.at(0, 0), calendar: calendar, locale: F.locale), "Tuesday")
        XCTAssertEqual(AnalyzerRunsSection.dayName(6, from: F.at(0, 0), short: true, calendar: calendar, locale: F.locale), "Sun")
        XCTAssertEqual(AnalyzerRunsSection.dayName(1, from: nil, calendar: calendar), "")
    }
}
