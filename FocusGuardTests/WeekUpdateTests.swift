import XCTest
@testable import FocusGuard

/// Your week: every line follows from the sessions by fixed rules, and the
/// chart's totals match Today and Reports.
final class WeekUpdateTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Monday 2 November 2026, 00:00 UTC.
    private let monday = Date(timeIntervalSince1970: 1_793_577_600)

    private var interval: DateInterval { DateInterval(start: monday, duration: 7 * 86_400) }

    private func entry(day: Int = 0, hour: Double = 9, minutes: Double = 60, goal: String? = nil, project: String? = nil,
                       state: WorkLogEntry.State = .open, mostly: String? = nil, live: Bool = false) -> WorkLogEntry {
        let start = monday.addingTimeInterval(Double(day) * 86_400 + hour * 3600)
        let end = start.addingTimeInterval(minutes * 60)
        return WorkLogEntry(id: UUID(), start: start, end: live ? nil : end, name: "Session", focusRate: 0.9, hasRate: true,
                            title: goal ?? "Mostly \(mostly ?? "")", hasGoal: goal != nil, project: project,
                            state: live ? .live : state, note: nil, apps: mostly ?? "", focused: minutes * 60,
                            focusSpans: [DateInterval(start: start, end: end)], mostly: mostly)
    }

    private func model(_ entries: [WorkLogEntry]) -> WorkLogModel {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.start) }
        let days = grouped.keys.sorted(by: >).map { WorkLogDay(day: $0, entries: grouped[$0] ?? []) }
        var byProject: [String?: TimeInterval] = [:]
        for entry in entries { byProject[entry.project, default: 0] += entry.focused }
        let projects = byProject.map { WorkLogProject(name: $0.key, seconds: $0.value) }
            .sorted { a, b in
                if (a.name == nil) != (b.name == nil) { return b.name == nil }
                return a.seconds > b.seconds
            }
        let sheetDays = (0..<5).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        let rows = projects.map { project in
            Timesheet.Row(project: project.name, seconds: sheetDays.map { day in
                entries.filter { $0.project == project.name && calendar.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.focused }
            })
        }
        return WorkLogModel(interval: interval, days: days, projects: projects, timesheet: Timesheet(days: sheetDays, rows: rows))
    }

    // MARK: - Lines

    func testGoalsGroupByTheirNewestVerdict() {
        let update = WeekUpdateBuilder.build(model([
            entry(day: 0, goal: "Ship pricing", state: .verdict(.partly)),
            entry(day: 2, goal: "ship pricing", state: .verdict(.done)),
            entry(day: 1, goal: "Onboarding", state: .verdict(.done)),
            entry(day: 3, goal: "Onboarding", state: .verdict(.partly)),
            entry(day: 3, hour: 14, goal: "Write docs"),
        ]), calendar: calendar)
        XCTAssertEqual(update.done.map(\.text), ["ship pricing"])
        XCTAssertEqual(update.done.first?.seconds, 7200)
        XCTAssertEqual(Set(update.going.map(\.text)), ["Onboarding", "Write docs"])
        XCTAssertTrue(update.isReady)
    }

    func testARunningSessionKeepsItsGoalGoing() {
        let update = WeekUpdateBuilder.build(model([
            entry(day: 0, goal: "Ship pricing", state: .verdict(.done)),
            entry(day: 1, goal: "Ship pricing", live: true),
        ]), calendar: calendar)
        XCTAssertTrue(update.done.isEmpty)
        XCTAssertEqual(update.going.map(\.text), ["Ship pricing"])
    }

    func testTimeWithoutAGoalIsAskedAboutOnlyOnceItAddsUp() {
        let small = WeekUpdateBuilder.build(model([entry(minutes: 29, mostly: "github.com")]), calendar: calendar)
        XCTAssertTrue(small.check.isEmpty)
        let big = WeekUpdateBuilder.build(model([entry(minutes: 20, mostly: "github.com"), entry(day: 3, minutes: 10, mostly: "github.com")]), calendar: calendar)
        XCTAssertEqual(big.check.map(\.text), ["github.com?"])
        XCTAssertEqual(big.check.first?.days.count, 2)
        XCTAssertFalse(big.isReady)
    }

    func testAGuessGoesByItsProjectBeforeItsApp() {
        let update = WeekUpdateBuilder.build(model([entry(project: "Acme", mostly: "github.com")]), calendar: calendar)
        XCTAssertEqual(update.check.map(\.text), ["Acme?"])
    }

    func testARunningSessionWithoutAGoalIsNotAskedAbout() {
        let update = WeekUpdateBuilder.build(model([entry(mostly: "github.com", live: true)]), calendar: calendar)
        XCTAssertTrue(update.check.isEmpty)
    }

    func testDecisionsMoveAGuess() {
        let entries = [entry(minutes: 125, mostly: "github.com")]
        let kept = WeekUpdateBuilder.build(model(entries), decisions: ["time:github.com": .kept(name: nil)], calendar: calendar)
        XCTAssertEqual(kept.also.map(\.text), ["github.com"])
        XCTAssertTrue(kept.isReady)
        let renamed = WeekUpdateBuilder.build(model(entries), decisions: ["time:github.com": .kept(name: "Code review")], calendar: calendar)
        XCTAssertEqual(renamed.also.map(\.text), ["Code review"])
        let left = WeekUpdateBuilder.build(model(entries), decisions: ["time:github.com": .left], calendar: calendar)
        XCTAssertTrue(left.lines.isEmpty)
        XCTAssertEqual(left.leftOut.count, 1)
        XCTAssertTrue(left.isReady)
    }

    func testGuessesStayOutOfWhatsCopiedUntilKept() {
        let entries = [entry(goal: "Ship pricing", state: .verdict(.done)), entry(day: 1, minutes: 125, mostly: "github.com")]
        let open = WeekUpdateBuilder.build(model(entries), calendar: calendar).text(interval: interval)
        XCTAssertTrue(open.contains("- Ship pricing (1h)"), open)
        XCTAssertFalse(open.contains("github.com"), open)
        let kept = WeekUpdateBuilder.build(model(entries), decisions: ["time:github.com": .kept(name: "Code review")], calendar: calendar)
            .text(interval: interval)
        XCTAssertTrue(kept.contains("Also this week\n- Code review (2h 05m)"), kept)
    }

    func testEvidenceSaysOnlyWhatsKnown() {
        var task = TaskItem(id: "ENG-142", title: "Ship pricing", list: "ENG", due: nil, created: nil)
        task.source = .linear
        let session = entry(goal: "Ship pricing", state: .verdict(.done))
        let update = WeekUpdateBuilder.build(model([session]), links: [session.id: TaskLink(task: task, linkedAt: session.start, ticked: true)], calendar: calendar)
        let texts = update.done.first?.evidence.map(\.text) ?? []
        XCTAssertEqual(texts.first, "Ticked off in Linear")
        XCTAssertTrue(texts.contains("Marked done in Monday's session"), "\(texts)")
        XCTAssertTrue(texts.contains("1 session with this goal, 1h focused"), "\(texts)")
        let plain = WeekUpdateBuilder.build(model([entry(goal: "Write docs")]), calendar: calendar)
        XCTAssertFalse(plain.going.first?.evidence.contains { $0.kind == .task } ?? true)
        XCTAssertEqual(plain.going.first?.evidence.first?.text, "Not marked done yet, so it stays under Still going")
    }

    func testDayLettersAreNeverNumbers() {
        XCTAssertEqual(WeekVerdict.dayLetter(monday.addingTimeInterval(12 * 3600), locale: Locale(identifier: "en_GB")), "M")
        XCTAssertFalse(WeekVerdict.dayLetter(monday.addingTimeInterval(12 * 3600), locale: Locale(identifier: "az_AZ")).contains { $0.isNumber })
    }

    // MARK: - Standup

    /// Wednesday, 10:00.
    private var wednesday: Date { monday.addingTimeInterval(2 * 86_400 + 10 * 3600) }

    func testStandupSaysWhatsBehindAndAhead() {
        var task = TaskItem(id: "ENG-151", title: "Add password reset", list: "ENG", due: nil, created: nil)
        task.source = .linear
        let meeting = NextMeeting(id: "m", title: "Design review", start: wednesday.addingTimeInterval(3600))
        let standup = WeekStandup.make(model: model([
            entry(day: 1, goal: "Fix login", state: .verdict(.done)),
            entry(day: 1, hour: 11, goal: "Onboarding", state: .verdict(.partly)),
            entry(day: 0, goal: "Old goal", state: .verdict(.partly)),
        ]), isCurrent: true, tasks: [task], meetings: [meeting], now: wednesday, calendar: calendar)
        XCTAssertEqual(standup.lastTitle, "Yesterday")
        XCTAssertEqual(standup.last.map(\.text), ["Fix login", "Onboarding"])
        XCTAssertEqual(standup.last.first?.from, "Marked done, 1h")
        XCTAssertEqual(standup.nextTitle, "Today")
        XCTAssertEqual(standup.next.map(\.text).prefix(2), ["Onboarding", "Add password reset"])
        XCTAssertEqual(standup.next[1].from, "Next on Linear")
        XCTAssertTrue(standup.next[2].text.hasPrefix("Design review at "), standup.next[2].text)
    }

    func testStandupOnAMondayGoesBackToLastWeek() {
        let friday = entry(day: -3, goal: "Ship it", state: .verdict(.done))
        let last = WorkLogModel(interval: DateInterval(start: monday.addingTimeInterval(-7 * 86_400), duration: 7 * 86_400),
                                days: [WorkLogDay(day: calendar.startOfDay(for: friday.start), entries: [friday])],
                                projects: [], timesheet: Timesheet(days: [], rows: []))
        let standup = WeekStandup.make(model: .empty(interval), earlier: last, isCurrent: true,
                                       now: monday.addingTimeInterval(9 * 3600), calendar: calendar)
        XCTAssertEqual(standup.last.map(\.text), ["Ship it"])
        XCTAssertNotEqual(standup.lastTitle, "Yesterday")
    }

    func testAGoalFinishedTodayIsNotStillOpen() {
        let standup = WeekStandup.make(model: model([
            entry(day: 1, goal: "Onboarding", state: .verdict(.partly)),
            entry(day: 2, hour: 8, goal: "onboarding", state: .verdict(.done)),
        ]), isCurrent: true, now: wednesday, calendar: calendar)
        XCTAssertTrue(standup.next.isEmpty, "\(standup.next)")
    }

    func testAPastWeekHasNoTodayOrTasks() {
        var task = TaskItem(id: "1", title: "A task", list: "", due: nil, created: nil)
        task.source = .linear
        let standup = WeekStandup.make(model: model([entry(day: 4, goal: "Onboarding", state: .verdict(.partly))]), isCurrent: false,
                                       tasks: [task], now: monday.addingTimeInterval(10 * 86_400), calendar: calendar)
        XCTAssertEqual(standup.nextTitle, "Next")
        XCTAssertEqual(standup.next.map(\.text), ["Onboarding"])
    }

    func testStandupTextDoesntClaimNothingIsBlocked() {
        let standup = WeekStandup(lastDay: monday, lastTitle: "Yesterday", last: [.init(text: "Ship it", from: "")],
                                  nextTitle: "Today", next: [.init(text: "Fix it", from: "")])
        XCTAssertEqual(standup.text(blockers: []), "*Yesterday*\n• Ship it\n\n*Today*\n• Fix it\n")
        XCTAssertTrue(standup.text(blockers: ["Waiting on legal"]).hasSuffix("*Blocked*\n• Waiting on legal\n"))
    }

    func testSessionsWithoutGoalsStillGiveAStandupLine() {
        let standup = WeekStandup.make(model: model([entry(day: 1, minutes: 90, mostly: "Xcode")]), isCurrent: true, now: wednesday, calendar: calendar)
        XCTAssertEqual(standup.last.first?.text, "1 session, 1h 30m focused")
    }

    func testBlockersStayUntilTakenOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WeekUpdateTests.blockers"))
        defaults.removePersistentDomain(forName: "WeekUpdateTests.blockers")
        let store = WeekBlockerStore(defaults: defaults)
        store.add("  Waiting on legal ")
        store.add("Waiting on legal")
        store.add("   ")
        XCTAssertEqual(store.blockers, ["Waiting on legal"])
        store.remove("Waiting on legal")
        XCTAssertTrue(store.blockers.isEmpty)
    }

    func testTimesheetHoursMatchTheExport() {
        XCTAssertEqual(Timesheet.hours(9600), "2.67")
        XCTAssertEqual(Timesheet.hours(0), "")
    }

    // MARK: - The store

    func testDecisionsStayWithTheirWeek() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WeekUpdateTests"))
        defaults.removePersistentDomain(forName: "WeekUpdateTests")
        let store = WeekEditStore(defaults: defaults)
        store.set(.kept(name: "Code review"), line: "time:github.com", week: monday)
        XCTAssertEqual(store.decisions(week: monday)["time:github.com"], .kept(name: "Code review"))
        XCTAssertTrue(store.decisions(week: monday.addingTimeInterval(7 * 86_400)).isEmpty)
        store.set(nil, line: "time:github.com", week: monday)
        XCTAssertTrue(store.decisions(week: monday).isEmpty)
    }

    func testOnlyRecentWeeksAreKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WeekUpdateTests.old"))
        defaults.removePersistentDomain(forName: "WeekUpdateTests.old")
        let store = WeekEditStore(defaults: defaults)
        for week in 0...WeekEditStore.weeksKept {
            store.set(.left, line: "a", week: monday.addingTimeInterval(Double(week) * 7 * 86_400))
        }
        XCTAssertTrue(store.decisions(week: monday).isEmpty, "The oldest week should go")
        XCTAssertFalse(store.decisions(week: monday.addingTimeInterval(7 * 86_400)).isEmpty)
    }

    // MARK: - The chart

    func testTheFourthProjectAndUnnamedTimeGoUnderOther() {
        let overview = WeekOverview.make(model: model([
            entry(day: 0, minutes: 240, project: "A"), entry(day: 1, minutes: 120, project: "B"), entry(day: 2, minutes: 60, project: "C"),
            entry(day: 3, minutes: 30, project: "D"), entry(day: 4, minutes: 15),
        ]), report: nil, goal: { _ in 4 * 3600 }, weekendsCount: false, calendar: calendar)
        XCTAssertEqual(overview.series.map(\.title), ["A", "B", "C", "Other"])
        XCTAssertEqual(overview.series.last?.seconds, 45 * 60)
        XCTAssertNil(overview.series.last?.slot)
        XCTAssertEqual(overview.days.count, 5)
        XCTAssertTrue(overview.days[0].metGoal)
        XCTAssertFalse(overview.days[1].metGoal)
    }

    func testAProjectKeepsItsColourWhenItsRankChanges() {
        XCTAssertEqual(WeekOverview.assignSlots(["A", "B", "C"], remembered: [:]), ["A": 0, "B": 1, "C": 2])
        XCTAssertEqual(WeekOverview.assignSlots(["B", "A", "D"], remembered: ["A": 0, "B": 1, "C": 2]), ["A": 0, "B": 1, "D": 2])
        XCTAssertEqual(WeekOverview.assignSlots(["A", "B"], remembered: ["A": 1, "B": 1]), ["A": 1, "B": 0])
        XCTAssertEqual(WeekOverview.assignSlots(["A"], remembered: ["A": 9]), ["A": 0])
    }

    func testAnEmptyWeekStillDrawsItsDays() {
        let overview = WeekOverview.make(model: .empty(interval), report: nil, goal: { _ in 3600 }, weekendsCount: false, calendar: calendar)
        XCTAssertEqual(overview.days.count, 5)
        XCTAssertTrue(overview.series.isEmpty)
        XCTAssertNil(overview.change)
        XCTAssertEqual(overview.focused, 0)
    }

    func testDotsLeaveOutWeekendsThatDontCount() {
        var entries = [entry(day: 0, minutes: 240)]
        entries.append(entry(day: 5, minutes: 60))
        var sheetDays = (0..<5).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        sheetDays.append(monday.addingTimeInterval(5 * 86_400))
        let base = model(entries)
        let withSaturday = WorkLogModel(interval: interval, days: base.days, projects: base.projects,
                                        timesheet: Timesheet(days: sheetDays, rows: [Timesheet.Row(project: nil, seconds: [14400, 0, 0, 0, 0, 3600])]))
        let off = WeekOverview.make(model: withSaturday, report: nil, goal: { _ in 3600 }, weekendsCount: false, calendar: calendar)
        XCTAssertEqual(off.days.count, 6)
        XCTAssertEqual(off.goalDays.count, 5)
        let on = WeekOverview.make(model: withSaturday, report: nil, goal: { _ in 3600 }, weekendsCount: true, calendar: calendar)
        XCTAssertEqual(on.goalDays.count, 6)
    }
}
