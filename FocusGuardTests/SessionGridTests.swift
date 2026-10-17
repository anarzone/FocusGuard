import XCTest
@testable import FocusGuard

final class SessionGridTests: XCTestCase {
    private func seg(_ c: Classification, _ minutes: Double) -> SessionGrid.Segment {
        .init(classification: c, seconds: minutes * 60)
    }

    func testLiveSessionShowsNowAndFutureCells() {
        let grid = SessionGrid.build(
            segments: [seg(.focus, 17)],
            elapsed: 17.5 * 60,
            planned: 50 * 60,
            current: .focus
        )
        XCTAssertEqual(grid.cells.count, 50)
        XCTAssertEqual(grid.focusCells, 17)
        XCTAssertEqual(grid.cells[17], .now(.focus))
        XCTAssertEqual(grid.cells.filter { $0 == .future }.count, 32)
        XCTAssertEqual(grid.minutesPerCell, 1)
    }

    func testFinishedSessionCoversOnlyMinutesThatRan() {
        let grid = SessionGrid.build(
            segments: [seg(.focus, 10), seg(.distraction, 2), seg(.neutral, 1)],
            elapsed: 13 * 60,
            planned: 50 * 60,
            current: nil
        )
        XCTAssertEqual(grid.cells.count, 13)
        XCTAssertEqual(grid.focusCells, 10)
        XCTAssertEqual(grid.driftCells, 2)
        XCTAssertEqual(grid.otherCells, 1)
        XCTAssertEqual(grid.focusPercent, 77)
        XCTAssertFalse(grid.cells.contains(.future))
    }

    func testLongSessionsGroupMinutesToStayUnderCap() {
        let grid = SessionGrid.build(segments: [seg(.focus, 30)], elapsed: 30 * 60, planned: 90 * 60, current: .focus)
        XCTAssertEqual(grid.minutesPerCell, 2)
        XCTAssertEqual(grid.cells.count, 45)
        XCTAssertLessThanOrEqual(grid.cells.count, SessionGrid.maxCells)
    }

    func testOpenEndedGrowsByRowsOfTen() {
        let grid = SessionGrid.build(segments: [seg(.focus, 12)], elapsed: 12 * 60, planned: nil, current: .focus)
        XCTAssertEqual(grid.cells.count, 20)
    }

    func testPausedSessionKeepsFutureWithoutNowCell() {
        let grid = SessionGrid.build(segments: [seg(.focus, 5)], elapsed: 5 * 60, planned: 25 * 60, current: nil, live: true)
        XCTAssertEqual(grid.cells.count, 25)
        XCTAssertFalse(grid.cells.contains { if case .now = $0 { return true }; return false })
        XCTAssertEqual(grid.cells.filter { $0 == .future }.count, 20)
    }

    func testDriftWinsTies() {
        let cells = SessionGrid.classify([seg(.focus, 0.5), seg(.distraction, 0.5)], into: 1)
        XCTAssertEqual(cells, [.drift])
    }

    func testLongestFocusRun() {
        let grid = SessionGrid.build(
            segments: [seg(.focus, 3), seg(.distraction, 1), seg(.focus, 5), seg(.neutral, 1)],
            elapsed: 10 * 60, planned: nil, current: nil
        )
        XCTAssertEqual(grid.longestFocusRunMinutes, 5)
    }

    func testNoTrackedTimeReadsAsOther() {
        XCTAssertEqual(SessionGrid.classify([], into: 3), [.other, .other, .other])
    }

    func testFocusingGlyphProgressIsQuantised() {
        XCTAssertEqual(StatusGlyphState.focusing(elapsed: 100, planned: 3000), .focusing(progress: 0))
        XCTAssertEqual(StatusGlyphState.focusing(elapsed: 1500, planned: 3000), .focusing(progress: 0.5))
        XCTAssertEqual(StatusGlyphState.focusing(elapsed: 9000, planned: 3000), .focusing(progress: 1))
    }
}
