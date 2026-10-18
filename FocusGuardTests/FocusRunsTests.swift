import XCTest
@testable import FocusGuard

final class FocusRunsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Spans laid end to end, each `(classification, seconds)`.
    private func spans(_ parts: [(Classification, TimeInterval)]) -> (spans: [FocusRuns.Span], end: Date) {
        var cursor = t0
        var out: [FocusRuns.Span] = []
        for (c, seconds) in parts {
            out.append(.init(start: cursor, end: cursor.addingTimeInterval(seconds), classification: c))
            cursor = cursor.addingTimeInterval(seconds)
        }
        return (out, cursor)
    }

    func testShortBlipKeepsTheRun() {
        let (s, end) = spans([(.focus, 600), (.neutral, 20), (.focus, 300)])
        let runs = FocusRuns.compute(s, now: end)
        XCTAssertEqual(runs.current, 920, accuracy: 0.001)
        XCTAssertEqual(runs.longest, 920, accuracy: 0.001)
    }

    func testDriftBreaksTheRunAfterTenSeconds() {
        let (s, end) = spans([(.focus, 600), (.distraction, 15), (.focus, 120)])
        let runs = FocusRuns.compute(s, now: end)
        XCTAssertEqual(runs.current, 120, accuracy: 0.001)
        XCTAssertEqual(runs.longest, 600, accuracy: 0.001)
        XCTAssertEqual(runs.lastEnded, 600, accuracy: 0.001)
    }

    func testDriftingNowShowsNoCurrentRun() {
        let (s, end) = spans([(.focus, 360), (.distraction, 42)])
        let runs = FocusRuns.compute(s, now: end)
        XCTAssertEqual(runs.current, 0)
        XCTAssertEqual(runs.lastEnded, 360, accuracy: 0.001)
    }

    func testLongNeutralStretchBreaksTheRun() {
        let (s, end) = spans([(.focus, 300), (.neutral, 45), (.focus, 60)])
        let runs = FocusRuns.compute(s, now: end)
        XCTAssertEqual(runs.current, 60, accuracy: 0.001)
        XCTAssertEqual(runs.longest, 300, accuracy: 0.001)
    }

    func testIdleGapBreaksTheRun() {
        let a = FocusRuns.Span(start: t0, end: t0.addingTimeInterval(300), classification: .focus)
        let b = FocusRuns.Span(start: t0.addingTimeInterval(400), end: t0.addingTimeInterval(460), classification: .focus)
        let runs = FocusRuns.compute([b, a], now: t0.addingTimeInterval(460))
        XCTAssertEqual(runs.current, 60, accuracy: 0.001)
        XCTAssertEqual(runs.longest, 300, accuracy: 0.001)
    }

    func testEmpty() {
        XCTAssertEqual(FocusRuns.compute([], now: t0), .empty)
    }
}
