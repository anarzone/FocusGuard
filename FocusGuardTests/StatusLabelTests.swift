import XCTest
@testable import FocusGuard

final class StatusLabelTests: XCTestCase {
    func testMinutesRoundUpSoTimeLeftNeverReadsZero() {
        XCTAssertEqual(AppState.minutesRoundedUp(0), 0)
        XCTAssertEqual(AppState.minutesRoundedUp(1), 1)
        XCTAssertEqual(AppState.minutesRoundedUp(60), 1)
        XCTAssertEqual(AppState.minutesRoundedUp(61), 2)
        XCTAssertEqual(AppState.minutesRoundedUp(24 * 60 - 5), 24)
    }

    func testText() {
        XCTAssertEqual(StatusLabel(minutes: 24, dimmed: false, kind: .sessionLeft).text, "24m")
        XCTAssertEqual(StatusLabel(minutes: 90, dimmed: false, kind: .sessionLeft).text, "1h 30m")
    }

    func testAccessibilityText() {
        XCTAssertEqual(StatusLabel(minutes: 1, dimmed: false, kind: .sessionLeft).accessibilityText, "1 minute left")
        XCTAssertEqual(StatusLabel(minutes: 24, dimmed: true, kind: .sessionLeft).accessibilityText, "24 minutes left, paused")
        XCTAssertEqual(StatusLabel(minutes: 6, dimmed: false, kind: .breakLeft).accessibilityText, "6 minutes of break left")
    }
}
