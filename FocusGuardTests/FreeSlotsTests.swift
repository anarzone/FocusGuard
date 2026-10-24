import XCTest
@testable import FocusGuard

final class FreeSlotsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// 23 Oct 2026 at `hour`:`minute`, a Friday.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 23) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func find(busy: [DateInterval] = [], from: Date, to: Date, count: Int = 3) -> [Date] {
        FreeSlots.find(busy: busy, in: DateInterval(start: from, end: to), length: 50 * 60, count: count,
                       breakLength: 10 * 60, calendar: calendar)
    }

    func testSpreadsSessionsAcrossAnEmptyDay() {
        XCTAssertEqual(find(from: at(9, 15), to: at(19)), [at(9, 30), at(13), at(16, 30)])
    }

    func testStepsAroundMeetings() {
        let busy = [DateInterval(start: at(9, 30), end: at(10)),
                    DateInterval(start: at(12, 30), end: at(14)),
                    DateInterval(start: at(16), end: at(17, 30))]
        XCTAssertEqual(find(busy: busy, from: at(9, 15), to: at(19)), [at(10), at(14), at(17, 30)])
    }

    func testAMeetingEndingAsASessionStartsIsntInTheWay() {
        let busy = [DateInterval(start: at(9), end: at(10))]
        XCTAssertEqual(find(busy: busy, from: at(9), to: at(11), count: 1), [at(10)])
    }

    func testFallsBackToCloserSessionsWhenTheDayIsShort() {
        // Too little day to keep them a third of it apart: a break apart instead.
        XCTAssertEqual(find(from: at(15), to: at(18, 30)), [at(15), at(16), at(17)])
    }

    func testSessionsMustEndBeforeTheWindowDoes() {
        XCTAssertEqual(find(from: at(18), to: at(19)), [at(18)])
        XCTAssertEqual(find(from: at(18, 20), to: at(19)), [])
    }

    func testAFullCalendarLeavesNothing() {
        let busy = [DateInterval(start: at(8), end: at(20))]
        XCTAssertEqual(find(busy: busy, from: at(9), to: at(19)), [])
    }

    func testOverlappingAndAllDayLongEventsAreFine() {
        let busy = [DateInterval(start: at(9), end: at(12)), DateInterval(start: at(11), end: at(13)),
                    DateInterval(start: at(0, 0, day: 22), end: at(9, 30))]
        XCTAssertEqual(find(busy: busy, from: at(9), to: at(15), count: 1), [at(13)])
    }

    func testCandidatesSitOnTheHalfHourGrid() {
        let starts = FreeSlots.candidates(busy: [], in: DateInterval(start: at(9, 7), end: at(11)),
                                          length: 25 * 60, grid: 30 * 60, calendar: calendar)
        XCTAssertEqual(starts, [at(9, 30), at(10), at(10, 30)])
    }
}
