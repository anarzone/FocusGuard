import XCTest
@testable import FocusGuard

final class ReadyDialTests: XCTestCase {
    // MARK: - Dial

    func testAnglesSnapToFiveMinutesOnATwoHourTurn() {
        XCTAssertEqual(DialMath.minutes(atDegrees: 90, previous: 50, continuing: false), 30)   // 3 o'clock
        XCTAssertEqual(DialMath.minutes(atDegrees: 180, previous: 50, continuing: false), 60)  // 6 o'clock
        XCTAssertEqual(DialMath.minutes(atDegrees: 152, previous: 50, continuing: false), 50)  // 50.7 → 50
        XCTAssertEqual(DialMath.minutes(atDegrees: 4, previous: 50, continuing: false), 5)     // never 0
    }

    func testPointsMeasureClockwiseFromTwelve() {
        let size: CGFloat = 168
        XCTAssertEqual(DialMath.snap(DialMath.rawMinutes(at: CGPoint(x: 160, y: 84), in: size, previous: 50, continuing: false)), 30)
        XCTAssertEqual(DialMath.snap(DialMath.rawMinutes(at: CGPoint(x: 8, y: 84), in: size, previous: 50, continuing: false)), 90)
    }

    func testDraggingPastTwelvePinsToTheNearerEnd() {
        // Sweeping clockwise past the top from 115 holds at two hours...
        XCTAssertEqual(DialMath.minutes(atDegrees: 20, previous: 115, continuing: true), 120)
        // ...and anticlockwise past it from 10 holds at five minutes.
        XCTAssertEqual(DialMath.minutes(atDegrees: 340, previous: 10, continuing: true), 5)
        // A fresh press goes straight where it lands.
        XCTAssertEqual(DialMath.minutes(atDegrees: 300, previous: 10, continuing: false), 100)
    }

    func testOnlyPressesOnTheRingStartADrag() {
        let size: CGFloat = 168, line: CGFloat = 13
        XCTAssertTrue(DialMath.isOnRing(CGPoint(x: 84, y: 12), size: size, lineWidth: line))
        XCTAssertFalse(DialMath.isOnRing(CGPoint(x: 84, y: 84), size: size, lineWidth: line))
    }

    func testLongSessionsLapTheRing() {
        XCTAssertEqual(DialMath.laps(for: 50).full, 0)
        XCTAssertEqual(DialMath.laps(for: 120).full, 0)
        XCTAssertEqual(DialMath.laps(for: 120).degrees, 360)
        XCTAssertEqual(DialMath.laps(for: 150).full, 1)
        XCTAssertEqual(DialMath.laps(for: 150).degrees, 90)
        XCTAssertEqual(DialMath.laps(for: 62.5).degrees, 187.5)   // follows the pointer between marks
    }

    func testDialTracksThePointerBetweenMarksAndSnapsOnTheNearest() {
        XCTAssertEqual(DialMath.rawMinutes(atDegrees: 152, previous: 50, continuing: true), 50.667, accuracy: 0.01)
        XCTAssertEqual(DialMath.snap(50.667), 50)
        XCTAssertEqual(DialMath.snap(52.6), 55)
        XCTAssertEqual(DialMath.rawMinutes(atDegrees: 20, previous: 117.5, continuing: true), 120)
    }

    // MARK: - Ruler

    func testDraggingLeftBringsLongerLengthsIn() {
        let ppm = RulerMath.pointsPerMinute
        XCTAssertEqual(RulerMath.value(start: 50, translation: -10 * ppm), 60, accuracy: 0.001)
        XCTAssertEqual(RulerMath.value(start: 50, translation: 10 * ppm), 40, accuracy: 0.001)
    }

    func testRulerClampsToFiveMinutesAndEightHours() {
        XCTAssertEqual(RulerMath.value(start: 10, translation: 1000), 5)
        XCTAssertEqual(RulerMath.value(start: 470, translation: -1000), 480)
        XCTAssertEqual(RulerMath.snap(52.4), 50)
        XCTAssertEqual(RulerMath.snap(52.6), 55)
        XCTAssertEqual(RulerMath.snap(1), 5)
    }

    func testRulerLabelsPresetsTheHourAndWholeHours() {
        XCTAssertEqual(RulerMath.label(for: 25), "25")
        XCTAssertEqual(RulerMath.label(for: 60), "60")
        XCTAssertEqual(RulerMath.label(for: 90), "90")
        XCTAssertEqual(RulerMath.label(for: 180), "3h")
        XCTAssertNil(RulerMath.label(for: 30))
        XCTAssertNil(RulerMath.label(for: 150))
    }

    // MARK: - Day strip

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let day = Date(timeIntervalSince1970: 1_799_971_200)  // a UTC midnight
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    func testStripDefaultsToEightToSix() {
        let window = DayStrip.window(dayStart: day, firstActivity: at(9.5), until: at(11), calendar: calendar)
        XCTAssertEqual(window.start, at(8))
        XCTAssertEqual(window.end, at(18))
    }

    func testStripStretchesToEarlyStartsAndThePreviewedSession() {
        let window = DayStrip.window(dayStart: day, firstActivity: at(6.4), until: at(19.2), calendar: calendar)
        XCTAssertEqual(window.start, at(6))
        XCTAssertEqual(window.end, at(20))
    }

    func testStripStopsAtMidnight() {
        let window = DayStrip.window(dayStart: day, firstActivity: nil, until: at(25), calendar: calendar)
        XCTAssertEqual(window.end, at(24))
    }
}
