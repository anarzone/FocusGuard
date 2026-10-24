import XCTest
@testable import FocusGuard

/// What the morning plan and the evening wrap-up say.
final class HabitCopyTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 23) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Morning plan

    func testMorningPlanWithTheCalendar() throws {
        let busy = [DateInterval(start: at(9, 30), end: at(10))]
        let plan = try XCTUnwrap(MorningPlan.make(now: at(9), focusedMinutes: 0, goalMinutes: 240, sessionMinutes: 90,
                                                  busy: busy, calendar: calendar))
        XCTAssertEqual(plan.slots.count, 3)
        XCTAssertEqual(plan.title, "3 sessions today?")
        XCTAssertEqual(plan.body(locale: locale, calendar: calendar),
                       "Free slots at 10:00, 13:30 and 17:00 would cover your 4h goal.")
    }

    func testMorningPlanWithoutTheCalendarSaysSessionsNotFreeSlots() throws {
        let plan = try XCTUnwrap(MorningPlan.make(now: at(9), focusedMinutes: 0, goalMinutes: 240, sessionMinutes: 50,
                                                  busy: nil, calendar: calendar))
        XCTAssertFalse(plan.fromCalendar)
        XCTAssertEqual(plan.body(locale: locale, calendar: calendar),
                       "Sessions at 9:30, 13:00 and 16:30 would add 2h 30m toward your 4h goal.")
    }

    func testMorningPlanCountsWhatsAlreadyFocused() throws {
        let plan = try XCTUnwrap(MorningPlan.make(now: at(11), focusedMinutes: 200, goalMinutes: 240,
                                                  sessionMinutes: 50, busy: [], calendar: calendar))
        XCTAssertEqual(plan.title, "A session today?")
        XCTAssertEqual(plan.body(locale: locale, calendar: calendar),
                       "A free slot at 11:30 would cover the rest of your 4h goal.")
    }

    func testNoMorningPlanOnceTheGoalIsMetOrNothingFits() {
        XCTAssertNil(MorningPlan.make(now: at(9), focusedMinutes: 240, goalMinutes: 240, sessionMinutes: 50,
                                      busy: nil, calendar: calendar))
        XCTAssertNil(MorningPlan.make(now: at(9), focusedMinutes: 0, goalMinutes: 240, sessionMinutes: 50,
                                      busy: [DateInterval(start: at(8), end: at(20))], calendar: calendar))
        XCTAssertNil(MorningPlan.make(now: at(18, 30), focusedMinutes: 0, goalMinutes: 240, sessionMinutes: 50,
                                      busy: nil, calendar: calendar))
    }

    // MARK: - Evening wrap-up

    func testWrapUpShortOfTheGoal() {
        let wrapUp = EveningWrapUp(focusedMinutes: 220, goalMinutes: 240, streak: 0,
                                   best: .init(name: "Comeback Run", start: at(14, 5), end: at(14, 55)),
                                   tomorrowStart: at(10, day: 24))
        XCTAssertEqual(wrapUp.title, "Today: 3h 40m focused")
        XCTAssertEqual(wrapUp.body(locale: locale, calendar: calendar),
                       "20 minutes short of your 4h goal. Best stretch: Comeback Run, 14:05–14:55. "
                       + "Best time to start tomorrow: 10:00.")
    }

    func testWrapUpOverTheGoalCountsTheStreak() {
        let wrapUp = EveningWrapUp(focusedMinutes: 265, goalMinutes: 240, streak: 5,
                                   best: .init(name: "Steady Run", start: at(9), end: at(10)), tomorrowStart: nil)
        XCTAssertEqual(wrapUp.title, "Goal hit: 4h 25m focused")
        XCTAssertEqual(wrapUp.body(locale: locale, calendar: calendar),
                       "25 minutes over your 4h goal. That's 5 days in a row.")
    }

    func testWrapUpRightOnTheGoalAndFarShort() {
        XCTAssertEqual(EveningWrapUp(focusedMinutes: 240, goalMinutes: 240, streak: 1, best: nil, tomorrowStart: nil)
            .body(locale: locale, calendar: calendar), "Right on your 4h goal.")
        XCTAssertEqual(EveningWrapUp(focusedMinutes: 30, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil)
            .body(locale: locale, calendar: calendar), "3h 30m short of your 4h goal.")
    }

    func testBestStartIsTheFreeSlotNearestThePeakHour() {
        let now = at(21)
        // No calendar: the peak hour itself.
        XCTAssertEqual(EveningWrapUp.bestStart(peakHour: 10, tomorrowBusy: nil, sessionMinutes: 50,
                                               now: now, calendar: calendar), at(10, day: 24))
        // 09:30–11:00 is taken: 11:00 is nearer 10:00 than 08:30.
        let busy = [DateInterval(start: at(9, 30, day: 24), end: at(11, day: 24))]
        XCTAssertEqual(EveningWrapUp.bestStart(peakHour: 10, tomorrowBusy: busy, sessionMinutes: 50,
                                               now: now, calendar: calendar), at(11, day: 24))
        // Nothing to go on yet.
        XCTAssertNil(EveningWrapUp.bestStart(peakHour: nil, tomorrowBusy: [], sessionMinutes: 50,
                                             now: now, calendar: calendar))
    }
}
