import XCTest
@testable import FocusGuard

final class SessionClockTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(SessionClock.format(44 * 60 + 12), "44:12")
        XCTAssertEqual(SessionClock.format(59.2), "1:00")      // rounds up: never shows 0 early
        XCTAssertEqual(SessionClock.format(0), "0:00")
        XCTAssertEqual(SessionClock.format(3909), "1:05:09")
    }

    func testSweepWrapsEachMinute() {
        XCTAssertEqual(SessionClock.sweep(elapsed: 0), 0)
        XCTAssertEqual(SessionClock.sweep(elapsed: 30), 0.5, accuracy: 0.001)
        XCTAssertEqual(SessionClock.sweep(elapsed: 90), 0.5, accuracy: 0.001)
    }
}
