import XCTest
@testable import FocusGuard

/// When the habit notifications may go out.
final class HabitTimingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// 23 Oct 2026 is a Friday, the 24th a Saturday.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 23) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func morning(_ now: Date, sent: String? = nil, enabled: Bool = true, available: Bool = true,
                         weekends: Bool = false) -> Bool {
        HabitsCoordinator.morningPlanDue(now: now, lastSentDay: sent, enabled: enabled, available: available,
                                         weekendsCount: weekends, calendar: calendar)
    }

    func testMorningPlanGoesOutOnceBetweenNineAndNoon() {
        XCTAssertFalse(morning(at(8, 59)))
        XCTAssertTrue(morning(at(9)))
        XCTAssertTrue(morning(at(11, 59)))
        XCTAssertFalse(morning(at(12)))
        XCTAssertFalse(morning(at(9, 30), sent: "2026-10-23"))
        XCTAssertTrue(morning(at(9, 30), sent: "2026-10-22"))
    }

    func testMorningPlanWaitsForTheUserAndHonoursTheSwitch() {
        XCTAssertFalse(morning(at(10), available: false))
        XCTAssertFalse(morning(at(10), enabled: false))
    }

    func testMorningPlanSkipsWeekendsUnlessTheyCount() {
        XCTAssertFalse(morning(at(10, day: 24)))
        XCTAssertTrue(morning(at(10, day: 24), weekends: true))
    }

    func testWrapUpComesAfterNineOnceTheDayIsQuiet() {
        func due(_ now: Date, last: Date?, sent: String? = nil, enabled: Bool = true) -> Bool {
            HabitsCoordinator.wrapUpDue(now: now, lastSentDay: sent, enabled: enabled, lastActivity: last, calendar: calendar)
        }
        XCTAssertFalse(due(at(20, 59), last: at(18)))
        XCTAssertTrue(due(at(21), last: at(20, 30)))
        XCTAssertFalse(due(at(21), last: at(20, 45)))
        XCTAssertFalse(due(at(22), last: at(18), sent: "2026-10-23"))
        XCTAssertFalse(due(at(22), last: at(18), enabled: false))
        XCTAssertTrue(due(at(22), last: nil))
    }

    func testAutoStartOffersAreSpacedAndPausable() {
        let now = at(10)
        XCTAssertTrue(HabitsCoordinator.mayOffer(now: now, lastOfferAt: .distantPast, pausedUntil: .distantPast))
        XCTAssertFalse(HabitsCoordinator.mayOffer(now: now, lastOfferAt: at(9, 45), pausedUntil: .distantPast))
        XCTAssertTrue(HabitsCoordinator.mayOffer(now: now, lastOfferAt: at(9, 30), pausedUntil: .distantPast))
        XCTAssertFalse(HabitsCoordinator.mayOffer(now: now, lastOfferAt: .distantPast, pausedUntil: at(11)))
    }

    func testDayKeysAndLists() {
        XCTAssertEqual(HabitFormat.dayKey(at(23, 59), calendar: calendar), "2026-10-23")
        XCTAssertEqual(HabitFormat.list(["10:00"]), "10:00")
        XCTAssertEqual(HabitFormat.list(["10:00", "14:00", "17:30"]), "10:00, 14:00 and 17:30")
        XCTAssertEqual(HabitFormat.amount(minutes: 45), "45 minutes")
        XCTAssertEqual(HabitFormat.amount(minutes: 1), "1 minute")
        XCTAssertEqual(HabitFormat.amount(minutes: 80), "1h 20m")
    }
}
