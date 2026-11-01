import XCTest
@testable import FocusGuard

/// The daily goal, and a weekday's own goal beside it.
final class FocusGoalTests: XCTestCase {
    typealias F = CoachFixture
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let calendar = CoachFixture.calendar
    /// Monday 19 Oct 2026, and the Friday of that week.
    private let monday = CoachFixture.at(0, 12)
    private let friday = CoachFixture.at(4, 12)

    override func setUp() {
        super.setUp()
        suiteName = "FocusGoalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_withoutAWeekdaysOwnGoal_everyDayUsesTheDailyGoal() {
        XCTAssertEqual(FocusGoal.minutes(on: friday, defaults, calendar: calendar), 240)
        defaults.set(180, forKey: SettingsKeys.Goal.dailyFocusMinutes)
        XCTAssertEqual(FocusGoal.minutes(on: friday, defaults, calendar: calendar), 180)
        XCTAssertEqual(FocusGoal.seconds(on: monday, defaults, calendar: calendar), 3 * 3600)
        XCTAssertTrue(FocusGoal.weekdayGoals(defaults, calendar: calendar).isEmpty)
    }

    func test_aWeekdaysOwnGoal_appliesOnThatWeekdayOnly() {
        FocusGoal.setMinutes(120, forWeekday: 6, defaults)
        XCTAssertEqual(FocusGoal.minutes(on: friday, defaults, calendar: calendar), 120)
        XCTAssertEqual(FocusGoal.minutes(on: monday, defaults, calendar: calendar), 240)
        XCTAssertEqual(FocusGoal.minutes(on: friday.addingTimeInterval(7 * 86_400), defaults, calendar: calendar), 120)
        XCTAssertEqual(FocusGoal.weekdayGoals(defaults, calendar: calendar), [.init(weekday: 6, minutes: 120)])
        // The daily goal moving leaves Friday's own alone.
        defaults.set(300, forKey: SettingsKeys.Goal.dailyFocusMinutes)
        XCTAssertEqual(FocusGoal.minutes(on: friday, defaults, calendar: calendar), 120)
    }

    func test_puttingTheDailyGoalBack_clearsTheSetting() {
        FocusGoal.setMinutes(120, forWeekday: 6, defaults)
        FocusGoal.setMinutes(90, forWeekday: 2, defaults)
        FocusGoal.setMinutes(nil, forWeekday: 6, defaults)
        XCTAssertEqual(FocusGoal.weekdayMinutes(defaults), [2: 90])
        FocusGoal.setMinutes(nil, forWeekday: 2, defaults)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.Goal.weekdayFocusMinutes))
    }

    func test_ownGoalsStayInTheGoalRange() {
        FocusGoal.setMinutes(5, forWeekday: 2, defaults)
        FocusGoal.setMinutes(900, forWeekday: 3, defaults)
        FocusGoal.setMinutes(60, forWeekday: 9, defaults)
        XCTAssertEqual(FocusGoal.weekdayMinutes(defaults), [2: 15, 3: 720])
    }

    func test_weekdayGoalsComeInWeekOrder() {
        FocusGoal.setMinutes(60, forWeekday: 1, defaults)     // Sunday
        FocusGoal.setMinutes(120, forWeekday: 6, defaults)    // Friday
        // The fixture's week starts on Monday, so Sunday comes last.
        XCTAssertEqual(FocusGoal.weekdayGoals(defaults, calendar: calendar).map(\.weekday), [6, 1])
        XCTAssertEqual(FocusGoal.pluralWeekday(6, locale: CoachFixture.locale, calendar: calendar), "Fridays")
    }

    // MARK: - Where the goal is read

    private var fridayTwoHours: (Date) -> TimeInterval {
        { [calendar] in calendar.component(.weekday, from: $0) == 6 ? 2 * 3600 : 4 * 3600 }
    }

    func test_reportsGoalDays_measureEachDayAgainstItsOwnGoal() {
        let saturday = F.at(5, 12)
        let week = ReportPeriod.week.interval(offset: 0, now: saturday, calendar: calendar)
        var days = ReportDataBuilder.bucketIntervals(period: .week, interval: week, events: [], now: saturday, calendar: calendar)
        for i in 0..<4 { days[i].focus = 4.5 * 3600 }   // Mon–Thu
        days[4].focus = 2.5 * 3600                      // Friday

        let sameGoal = ReportsModelBuilder.goalDays(days, now: saturday, calendar: calendar, weekendsCount: false, goal: 4 * 3600)
        XCTAssertEqual(sameGoal.met, 4)
        XCTAssertEqual(sameGoal.misses, [F.at(4, 0)])

        let ownGoal = ReportsModelBuilder.goalDays(days, now: saturday, calendar: calendar, weekendsCount: false, goal: fridayTwoHours)
        XCTAssertEqual(ownGoal.met, 5)
        XCTAssertEqual(ownGoal.counted, 5)
        XCTAssertTrue(ownGoal.misses.isEmpty)
    }

    func test_monthGridRings_fillToEachDaysOwnGoal() {
        let month = ReportPeriod.month.interval(offset: 0, now: friday, calendar: calendar)
        let buckets = ReportDataBuilder.bucketIntervals(period: .month, interval: month, events: [], now: friday, calendar: calendar)
        let cells = ReportsModelBuilder.monthGrid(interval: month, buckets: buckets, now: friday, calendar: calendar,
                                                  goal: fridayTwoHours).flatMap { $0 }
        XCTAssertEqual(cells.first { $0.date == F.at(4, 0) }?.goal, 2 * 3600)
        XCTAssertEqual(cells.first { $0.date == F.at(3, 0) }?.goal, 4 * 3600)
        XCTAssertEqual(cells.first { $0.date == nil }?.goal, 0)
    }

    func test_coachWeekStats_countEachDaysOwnGoal() {
        var f = CoachFixture()
        for day in 0..<4 { f.session(day, 9, 0, [(.focus, 200, "a")]) }
        f.session(4, 9, 0, [(.focus, 130, "a")])
        let stats = CoachWeekStats.make(f.data(), before: .empty(DateInterval(start: F.at(-7, 0), end: F.at(0, 0))),
                                        goal: { [calendar] in calendar.component(.weekday, from: $0) == 6 ? 2 * 3600 : 3 * 3600 },
                                        weekendsCount: false, calendar: calendar)
        XCTAssertEqual(stats.goalDays, 5)
    }
}
