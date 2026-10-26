import XCTest
import SwiftData
@testable import FocusGuard

/// The main window's numbers and words: Today's goal split and headline,
/// the streak line, and Reports' history clip, goal days and highlights.
@MainActor
final class WindowModelTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var calendar: Calendar!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        calendar.locale = Locale(identifier: "en_GB")
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    /// Friday 2026-10-23 19:08 UTC.
    private var friday: Date { date(2026, 10, 23, 19, 8) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @discardableResult
    private func event(_ start: Date, _ minutes: Double, _ c: Classification, session: Session? = nil,
                       app: String = "Xcode", url: String? = nil) -> ActivityEvent {
        let e = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(minutes * 60 - 1),
                              bundleIdentifier: "com.example.\(app)", appName: app, url: url, session: session)
        e.classification = c
        context.insert(e)
        return e
    }

    private func session(_ start: Date, minutes: Double, name: String? = nil) -> Session {
        let s = Session(startedAt: start, status: .completed, plannedDurationMinutes: Int(minutes))
        s.endedAt = start.addingTimeInterval(minutes * 60)
        s.autoName = name
        context.insert(s)
        return s
    }

    // MARK: - Today

    func testTodaySplitsFocusInAndBetweenSessions() {
        let morning = session(date(2026, 10, 23, 9), minutes: 50, name: "Locked-in Deep Dive")
        event(date(2026, 10, 23, 9), 40, .focus, session: morning)
        event(date(2026, 10, 23, 9, 40), 10, .distraction, session: morning, app: "Chrome", url: "https://x.com/home")
        event(date(2026, 10, 23, 13), 30, .focus)          // between sessions
        event(date(2026, 10, 23, 13, 30), 20, .neutral)
        Persistence.save(context)

        let model = TodayModelBuilder.build(day: friday, context: context, now: friday, calendar: calendar)
        XCTAssertEqual(model.focused, 70 * 60, accuracy: 5)
        XCTAssertEqual(model.focusedInSessions, 40 * 60, accuracy: 5)
        XCTAssertEqual(model.focusedBetweenSessions, 30 * 60, accuracy: 5)
        XCTAssertEqual(model.drifted, 10 * 60, accuracy: 5)
        // Neutral time doesn't count against the rate.
        XCTAssertEqual(model.focusRate, 70.0 / 80.0, accuracy: 0.01)
        XCTAssertEqual(model.bestZoneSession, "Locked-in Deep Dive")
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].apps.first?.name, "Xcode")
        XCTAssertEqual(model.sessions[0].runs.map(\.kind), [.focus, .drift])
    }

    func testStripCoversEightToEightAndStretches() {
        let day = calendar.startOfDay(for: friday)
        let plain = TodayModelBuilder.stripWindow(activity: [], dayStart: day, dayEnd: day.addingTimeInterval(86_400),
                                                  now: date(2026, 10, 23, 11), calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: plain.start), 8)
        XCTAssertEqual(calendar.component(.hour, from: plain.end), 20)

        let late = TodayModelBuilder.stripWindow(
            activity: [DaySpan(start: date(2026, 10, 23, 6, 30), end: date(2026, 10, 23, 7), kind: .focus)],
            dayStart: day, dayEnd: day.addingTimeInterval(86_400), now: date(2026, 10, 23, 21, 40), calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: late.start), 6)
        XCTAssertEqual(calendar.component(.hour, from: late.end), 22)
    }

    func testRunsMergeAndFoldTinyBits() {
        let segments: [SessionTimeline.Segment] = [
            .init(classification: .focus, seconds: 600),
            .init(classification: .focus, seconds: 600),
            .init(classification: .distraction, seconds: 10),   // under 2%: folds into focus
            .init(classification: .distraction, seconds: 420),
            .init(classification: .focus, seconds: 900),
        ]
        let runs = TodayModelBuilder.runs(of: segments)
        XCTAssertEqual(runs.map(\.kind), [.focus, .drift, .focus])
        XCTAssertEqual(runs[0].seconds, 1210, accuracy: 0.1)
    }

    func testHeadlineInASession() {
        let lead = TodayHeadline.make(.init(focused: 3 * 3600 + 23 * 60, goal: 4 * 3600, isToday: true,
                                            sessionLeft: 22 * 60, inSession: true, nextLength: 50))
        XCTAssertEqual(lead.lead, "37 minutes to your 4-hour goal.")
        XCTAssertEqual(lead.rest, "This session can cover most of it.")
    }

    func testHeadlineBetweenSessions() {
        let idle = TodayHeadline.make(.init(focused: 2 * 3600 + 58 * 60, goal: 4 * 3600, isToday: true, nextLength: 50))
        XCTAssertEqual(idle.lead, "An hour to your 4-hour goal.")
        XCTAssertEqual(idle.rest, "One 50-minute session now gets you nearly there.")

        let met = TodayHeadline.make(.init(focused: 4 * 3600 + 5 * 60, goal: 4 * 3600, isToday: true, nextLength: 50))
        XCTAssertEqual(met.lead, "Goal met: 4h 05m focused today.")

        let first = TodayHeadline.make(.init(focused: 0, goal: 4 * 3600, isToday: true, isFirstDay: true, nextLength: 50))
        XCTAssertEqual(first.lead, "Day one.")

        let pastDay = TodayHeadline.make(.init(focused: 3 * 3600, goal: 4 * 3600, isToday: false, nextLength: 50))
        XCTAssertEqual(pastDay.rest, "1h short of the goal.")
        XCTAssertEqual(TodayHeadline.goalName(225 * 60), "3h 45m goal")
        XCTAssertEqual(TodayHeadline.gap(130 * 60), "2h 10m")
    }

    func testStreakLineNamesTheDays() {
        // Four weekdays ending Thursday, seen on Friday.
        XCTAssertEqual(StreakWords.detail(count: 4, now: friday, weekendsCount: false, calendar: calendar),
                       "goal met Monday to Thursday")
        XCTAssertEqual(StreakWords.detail(count: 1, now: friday, weekendsCount: false, calendar: calendar),
                       "goal met yesterday")
        // On a Monday without weekends, the day before the streak's last is Friday.
        let monday = date(2026, 10, 26, 12)
        XCTAssertEqual(StreakWords.days(count: 2, now: monday, weekendsCount: false, calendar: calendar),
                       [date(2026, 10, 23), date(2026, 10, 22)])
        XCTAssertEqual(StreakWords.detail(count: 0, now: friday, weekendsCount: false, calendar: calendar),
                       "meet today's goal to start one")
    }

    // MARK: - Reports

    func testHistoryClipLeavesOutEarlierDays() {
        event(date(2026, 10, 5, 10), 60, .focus)      // before the clip
        event(date(2026, 10, 20, 10), 30, .focus)
        Persistence.save(context)

        let data = ReportDataBuilder.build(period: .month, offset: 0, context: context, now: friday,
                                           calendar: calendar, notBefore: date(2026, 10, 10))
        XCTAssertEqual(data.breakdown.focus, 30 * 60, accuracy: 5)
        XCTAssertTrue(data.buckets[4].isLocked)       // 5 October
        XCTAssertFalse(data.buckets[19].isLocked)     // 20 October
        // September is out of reach, so nothing to compare.
        XCTAssertEqual(data.previous.focus, 0)
    }

    func testGoalDaysCountWeekdaysAndTodayOnceMet() {
        let week = ReportPeriod.week.interval(offset: 0, now: friday, calendar: calendar)
        let buckets = ReportDataBuilder.bucketIntervals(period: .week, interval: week, events: [], now: friday, calendar: calendar)
        var filled = buckets
        for i in 0..<4 { filled[i].focus = 4.5 * 3600 }   // Mon–Thu met
        filled[4].focus = 3600                             // today, not yet
        let goal = ReportsModelBuilder.goalDays(filled, now: friday, calendar: calendar, weekendsCount: false, goal: 4 * 3600)
        XCTAssertEqual(goal.met, 4)
        XCTAssertEqual(goal.counted, 4)
        XCTAssertTrue(goal.misses.isEmpty)
    }

    func testMonthHeadlineNamesWhatTheMissesShare() {
        let fridays = [date(2026, 10, 2), date(2026, 10, 9), date(2026, 10, 16)]
        let words = ReportWords.monthHeadline(GoalDays(met: 13, counted: 16, misses: fridays),
                                              weekendsCount: false, isCurrent: true, calendar: calendar)
        XCTAssertEqual(words.lead, "Goal met on 13 of 16 weekdays so far.")
        XCTAssertEqual(words.rest, "All three misses were Fridays.")
        let one = ReportWords.monthHeadline(GoalDays(met: 3, counted: 4, misses: [fridays[0]]),
                                            weekendsCount: true, isCurrent: false, calendar: calendar)
        XCTAssertEqual(one.lead, "Goal met on 3 of 4 days.")
        XCTAssertEqual(one.rest, "The one miss was a Friday.")
    }

    func testMonthGridStartsOnTheRightWeekday() {
        let month = ReportPeriod.month.interval(offset: 0, now: friday, calendar: calendar)
        let buckets = ReportDataBuilder.bucketIntervals(period: .month, interval: month, events: [], now: friday, calendar: calendar)
        let grid = ReportsModelBuilder.monthGrid(interval: month, buckets: buckets, now: friday, calendar: calendar)
        // 1 October 2026 is a Thursday: three padding cells on a Monday-first grid.
        XCTAssertNil(grid[0][2].date)
        XCTAssertEqual(grid[0][3].date, date(2026, 10, 1))
        XCTAssertEqual(grid.count, 5)
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
    }

    func testBestWeekNoteNeedsThreeWeeksBeaten() {
        func weeks(_ hours: [Double]) -> [WeekTotal] {
            hours.enumerated().map { WeekTotal(start: date(2026, 9, 1).addingTimeInterval(Double($0.offset) * 7 * 86_400),
                                               focus: $0.element * 3600, isCurrent: $0.offset == hours.count - 1) }
        }
        XCTAssertEqual(ReportsModelBuilder.bestWeekNote(weeks([14, 15, 13, 16, 17, 16, 18, 20])), "your best week in two months")
        XCTAssertEqual(ReportsModelBuilder.bestWeekNote(weeks([25, 15, 13, 16, 20])), "your best week in 4 weeks")
        XCTAssertNil(ReportsModelBuilder.bestWeekNote(weeks([14, 21, 20])))
    }

    func testBestStretchAndPatternNote() {
        var heat = Array(repeating: Array(repeating: TimeInterval(0), count: 24), count: 7)
        heat[0][9] = 3000; heat[0][10] = 3000; heat[0][11] = 2000; heat[1][15] = 1000
        let stretch = ReportsModelBuilder.bestStretch(heat, length: 3)
        XCTAssertEqual(stretch?.start, 9)
        XCTAssertEqual(stretch?.share ?? 0, 8000.0 / 9000.0, accuracy: 0.001)

        let late = [date(2026, 10, 1, 16, 30), date(2026, 10, 2, 17), date(2026, 10, 5, 9)]
        XCTAssertEqual(ReportsModelBuilder.patternNote(patterns: [(.fading, 3)], fadingStarts: late, calendar: calendar),
                       "Fading sessions mostly start after 16:00.")
        XCTAssertEqual(ReportsModelBuilder.patternNote(patterns: [(.steady, 5), (.fading, 1)], fadingStarts: [], calendar: calendar),
                       "Most sessions went steady.")
    }

    func testSessionPatternComesFromItsName() {
        let s = session(date(2026, 10, 20, 9), minutes: 50, name: "Slow-start Deep Dive")
        XCTAssertEqual(ReportsModelBuilder.pattern(of: s), .slowStart)
        let unnamed = session(date(2026, 10, 20, 11), minutes: 30)
        event(date(2026, 10, 20, 11), 30, .focus, session: unnamed)
        Persistence.save(context)
        XCTAssertEqual(ReportsModelBuilder.pattern(of: unnamed), .lockedIn)
    }

    // MARK: - Words

    func testFormats() {
        XCTAssertEqual(WindowFormat.hm(4 * 3600 + 5 * 60), "4h 05m")
        XCTAssertEqual(WindowFormat.hm(47 * 60), "47m")
        XCTAssertEqual(WindowFormat.hm(4 * 3600), "4h")
        XCTAssertEqual(WindowFormat.minutesChange(52 * 60, 27 * 60), "+25m")
        XCTAssertEqual(WindowFormat.minutesChange(41 * 60, 49 * 60), "−8m")
        XCTAssertEqual(WindowFormat.minutesChange(13 * 60, nil), "new")
        XCTAssertEqual(ReportWords.driftChange(2 * 3600 + 14 * 60, 2 * 3600 + 40 * 60, against: "last week"),
                       "26 min less than last week")
        XCTAssertEqual(ReportWords.driftChange(8 * 3600, 9 * 3600 + 5 * 60, against: "September"),
                       "1h 05m less than September")
    }

    func testUpgradeSheetShowsEachAIFeatureOnceItShips() {
        let shown = Set(UpgradeFeature.shown.map(\.title))
        XCTAssertEqual(shown.contains("Smart categories"), FeatureFlags.smartCategories)
        XCTAssertEqual(shown.contains("Goals and debriefs"), FeatureFlags.debrief)
        XCTAssertEqual(shown.contains("Work log"), FeatureFlags.debrief)
        XCTAssertEqual(shown.contains("Weekly coach"), FeatureFlags.coach)
        XCTAssertTrue(UpgradeFeature.shown.contains { $0.title == "Block on the whole Mac" && $0.comingLater })
    }
}
