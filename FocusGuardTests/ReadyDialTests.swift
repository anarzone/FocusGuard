import XCTest
@testable import FocusGuard

final class ReadyDialTests: XCTestCase {
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

    // MARK: - Now row

    func testNowRowSaysTheAppNameOnceWhenThereIsNothingElse() {
        func snapshot(title: String?, url: String? = nil) -> ActivitySnapshot {
            ActivitySnapshot(bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude",
                             windowTitle: title, url: url, classification: .focus, observedAt: .now)
        }
        XCTAssertNil(snapshot(title: "Claude").distinctDetail)
        XCTAssertNil(snapshot(title: " claude ").distinctDetail)
        XCTAssertNil(snapshot(title: nil).distinctDetail)                 // never the bundle id
        XCTAssertEqual(snapshot(title: "FocusGuard — Claude").distinctDetail, "FocusGuard — Claude")
        XCTAssertEqual(snapshot(title: "Docs", url: "https://developer.spotify.com/dashboard").distinctDetail,
                       "developer.spotify.com/dashboard")
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

    func testLateNightActivityDoesntStretchTheStripToMidnight() {
        // Working past midnight: 00:40 belongs to last night, not this morning.
        let night = DayStrip.window(dayStart: day, firstActivity: nil, until: at(11), calendar: calendar)
        XCTAssertEqual(night.start, at(8))
        // An early start from 4 AM on still stretches it.
        let early = DayStrip.window(dayStart: day, firstActivity: at(5.5), until: at(11), calendar: calendar)
        XCTAssertEqual(early.start, at(5))
        let tooEarly = DayStrip.window(dayStart: day, firstActivity: at(3.5), until: at(11), calendar: calendar)
        XCTAssertEqual(tooEarly.start, at(8))
    }

    func testStripStopsAtMidnight() {
        let window = DayStrip.window(dayStart: day, firstActivity: nil, until: at(25), calendar: calendar)
        XCTAssertEqual(window.end, at(24))
    }
}
