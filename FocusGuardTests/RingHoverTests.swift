import SwiftUI
import XCTest
@testable import FocusGuard

final class RingHoverTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// An event `seconds` long (stored as one second shorter, the way the
    /// tracker's 1 Hz samples land), starting `offset` seconds into the session.
    private func event(_ app: String, _ c: Classification, at offset: TimeInterval, _ seconds: TimeInterval,
                       url: String? = nil) -> ActivityEvent {
        let start = t0.addingTimeInterval(offset)
        let e = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(seconds - 1),
                              bundleIdentifier: "b.\(app)", appName: app, url: url)
        e.classification = c
        return e
    }

    private var events: [ActivityEvent] {
        [
            event("Xcode", .focus, at: 0, 600),
            event("Safari", .distraction, at: 600, 240, url: "https://www.youtube.com/watch?v=1"),
            event("Messages", .distraction, at: 840, 60),
            event("Xcode", .focus, at: 900, 300),
        ]
    }

    private func finished(_ cells: [SessionTimeline.Cell]) -> SessionTimeline {
        SessionTimeline(cells: cells, minutesPerCell: 1)
    }

    func testDriftArcFindsItsTimeAndApps() throws {
        let timeline = finished(Array(repeating: .focus, count: 10) + Array(repeating: .drift, count: 5)
                                + Array(repeating: .focus, count: 5))
        let stretch = try XCTUnwrap(SessionTimeline.stretch(cells: 10..<15, kind: .drift, in: timeline, events: events))
        XCTAssertEqual(stretch.start, t0.addingTimeInterval(600))
        XCTAssertEqual(stretch.end, t0.addingTimeInterval(900))
        XCTAssertEqual(stretch.minutes, 5)
        XCTAssertEqual(stretch.apps.map(\.name), ["youtube.com", "Messages"])
        XCTAssertEqual(stretch.apps.first?.seconds, 240)
        XCTAssertFalse(stretch.includesNow)
    }

    func testRepeatedAppsAddUpAndOnlyTopThreeShow() throws {
        let timeline = finished(Array(repeating: .focus, count: 20))
        let stretch = try XCTUnwrap(SessionTimeline.stretch(cells: 0..<20, kind: .focus, in: timeline, events: events))
        XCTAssertEqual(stretch.apps.first?.name, "Xcode")
        XCTAssertEqual(stretch.apps.first?.seconds, 900)
        XCTAssertLessThanOrEqual(stretch.apps.count, 3)
    }

    func testArcReachingNowEndsNow() throws {
        let cells: [SessionTimeline.Cell] = Array(repeating: .focus, count: 10) + Array(repeating: .drift, count: 5)
            + [.now(.focus)] + Array(repeating: .future, count: 9)
        let now = t0.addingTimeInterval(1_205)
        let stretch = try XCTUnwrap(SessionTimeline.stretch(cells: 15..<16, kind: .focus, in: finished(cells),
                                                            events: events, now: now))
        XCTAssertTrue(stretch.includesNow)
        XCTAssertEqual(stretch.end, now)
        XCTAssertEqual(stretch.apps.map(\.name), ["Xcode"])
    }

    func testNoEventsMeansNoDetail() {
        let timeline = finished([.focus, .focus])
        XCTAssertNil(SessionTimeline.stretch(cells: 0..<2, kind: .focus, in: timeline, events: []))
    }

    func testRingSegmentsRememberTheirCells() {
        let timeline = finished([.focus, .focus, .drift, .other, .other])
        let segments = timeline.ringSegments(progress: 1)
        XCTAssertEqual(segments.map(\.cells), [0..<2, 2..<3, 3..<5])
    }

    func testHitTestingFollowsTheRing() {
        let segments = finished([.focus, .drift]).ringSegments(progress: 1)
        // size 200, line 14 → radius 90 around (100, 100).
        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            SessionRingView<EmptyView>.segmentIndex(at: CGPoint(x: x, y: y), size: 200, lineWidth: 14, segments: segments)
        }
        XCTAssertEqual(hit(190, 100), 0)   // 3 o'clock, inside the first half
        XCTAssertEqual(hit(10, 100), 1)    // 9 o'clock, inside the second half
        XCTAssertNil(hit(100, 100))        // centre
        XCTAssertNil(hit(100, 60))         // inside the ring, off the band
    }
}
