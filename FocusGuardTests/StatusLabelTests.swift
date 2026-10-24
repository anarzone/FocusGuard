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

    func testPassShowsTheSiteAndMinutesAndSeconds() {
        let pass = StatusLabel.pass(name: "x.com", secondsLeft: 112)
        XCTAssertEqual(pass.text, "x.com 1:52")
        XCTAssertTrue(pass.showsDot)
        XCTAssertFalse(StatusLabel(minutes: 24, dimmed: false, kind: .sessionLeft).showsDot)
        XCTAssertEqual(StatusLabel.pass(name: "x.com", secondsLeft: 9).text, "x.com 0:09")
    }

    func testPassAccessibilityText() {
        XCTAssertEqual(StatusLabel.pass(name: "x.com", secondsLeft: 112).accessibilityText,
                       "x.com allowed for 1 minute 52 seconds")
        XCTAssertEqual(StatusLabel.pass(name: "Discord", secondsLeft: 120).accessibilityText,
                       "Discord allowed for 2 minutes")
        XCTAssertEqual(StatusLabel.pass(name: "x.com", secondsLeft: 1).accessibilityText,
                       "x.com allowed for 1 second")
    }
}
