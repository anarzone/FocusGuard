import XCTest
@testable import FocusGuard

final class AutoStartDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var detector = AutoStartDetector()

    /// Feeds one sample a second from `from` to `to` seconds after t0.
    @discardableResult
    private func feed(_ app: String = "Xcode", _ classification: Classification = .focus,
                      from: Int, to: Int, eligible: Bool = true) -> [AutoStartOffer] {
        (from...to).compactMap {
            detector.observe(.init(appName: app, bundleId: "id.\(app)", classification: classification,
                                   at: t0.addingTimeInterval(TimeInterval($0)), eligible: eligible))
        }
    }

    func testOffersAfterFiveFocusedMinutesOnce() {
        XCTAssertTrue(feed(from: 0, to: 299).isEmpty)
        let offers = feed(from: 300, to: 900)
        XCTAssertEqual(offers.count, 1)
        let offer = offers[0]
        XCTAssertEqual(offer.since, t0)
        XCTAssertEqual(offer.bundleId, "id.Xcode")
        XCTAssertEqual(offer.focusSeconds(now: t0.addingTimeInterval(300)), 300)
        XCTAssertEqual(offer.title(now: t0.addingTimeInterval(300)), "You've been in Xcode 5 minutes")
        XCTAssertEqual(offer.title(now: t0.addingTimeInterval(720)), "You've been in Xcode 12 minutes")
        let body = offer.body(locale: Locale(identifier: "en_GB"), calendar: Calendar(identifier: .gregorian))
        XCTAssertTrue(body.hasPrefix("Start a session? It counts from "), body)
        XCTAssertTrue(body.hasSuffix(", when you opened Xcode."), body)
        XCTAssertTrue(detector.isOngoing(since: t0))
    }

    func testAShortGlanceElsewhereKeepsTheStretch() {
        feed(from: 0, to: 120)
        feed("Finder", .neutral, from: 121, to: 135)        // 15 s
        feed("Mail", .distraction, from: 136, to: 144)      // 9 s, 24 s away in all
        let offers = feed("Terminal", from: 145, to: 300)
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(offers.first?.since, t0)
        XCTAssertEqual(offers.first?.title(now: t0.addingTimeInterval(300)), "You've been focused for 5 minutes")
        XCTAssertEqual(offers.first?.appNames, ["Xcode", "Terminal"])
    }

    func testALongerDetourEndsIt() {
        feed(from: 0, to: 200)
        feed("Finder", .neutral, from: 201, to: 240)        // 40 s
        XCTAssertTrue(feed(from: 241, to: 500).isEmpty)
        XCTAssertEqual(feed(from: 501, to: 541).first?.since, t0.addingTimeInterval(241))

        detector.reset()
        feed(from: 0, to: 200)
        feed("YouTube", .distraction, from: 201, to: 215)   // 15 s of drift
        XCTAssertFalse(detector.isOngoing(since: t0))
    }

    func testSessionsBreaksAndCallsReset() {
        feed(from: 0, to: 250)
        feed(from: 251, to: 260, eligible: false)
        XCTAssertNil(detector.stretch)
        XCTAssertTrue(feed(from: 261, to: 500).isEmpty)
    }

    func testSleepEndsTheStretch() {
        feed(from: 0, to: 120)
        // The Mac slept; the next tick comes an hour later.
        XCTAssertTrue(feed(from: 3720, to: 3800).isEmpty)
        XCTAssertEqual(detector.stretch?.start, t0.addingTimeInterval(3720))
    }

    func testNeutralTimeAloneNeverStartsOne() {
        XCTAssertTrue(feed("Finder", .neutral, from: 0, to: 600).isEmpty)
        XCTAssertNil(detector.stretch)
    }
}
