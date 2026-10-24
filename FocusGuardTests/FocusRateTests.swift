import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class FocusRateTests: XCTestCase {
    func testRateIsFocusedOverFocusedPlusDrifted() {
        XCTAssertEqual(FocusRate.of(focused: 41 * 60, drifted: 6 * 60), 41.0 / 47, accuracy: 0.0001)
        XCTAssertEqual(FocusRate.percent(focused: 41 * 60, drifted: 6 * 60), 87)
        XCTAssertEqual(FocusRate.of(focused: 30, drifted: 0), 1)
        XCTAssertEqual(FocusRate.of(focused: 0, drifted: 30), 0)
    }

    func testNothingCountedIsZero() {
        XCTAssertEqual(FocusRate.of(focused: 0, drifted: 0), 0)
        XCTAssertEqual(FocusRate.percent(focused: 0, drifted: 0), 0)
        XCTAssertEqual(FocusRate.of(focused: -5, drifted: -5), 0)
    }

    func testBreakdownsLeaveNeutralTimeOut() {
        let breakdown = BreakdownSnapshot(focus: 95 * 60, neutral: 40 * 60, distraction: 120 * 60)
        XCTAssertEqual(breakdown.focusRate, 95.0 / 215, accuracy: 0.0001)
        XCTAssertEqual(breakdown.focusPercent, breakdown.focusRate)
        let day = DailyBreakdown(date: .now, focus: 30, neutral: 1000, distraction: 10)
        XCTAssertEqual(day.focusRate, 0.75, accuracy: 0.0001)
        let bucket = ReportBucket(id: .now, interval: DateInterval(start: .now, duration: 60), label: "Mon",
                                  focus: 90, drift: 10, other: 500, isFuture: false)
        XCTAssertEqual(bucket.focusRate, 0.9, accuracy: 0.0001)
    }

    func testSessionTimelineRateLeavesOtherCellsOut() {
        let grid = SessionTimeline.build(
            segments: [.init(classification: .focus, seconds: 8 * 60),
                       .init(classification: .neutral, seconds: 10 * 60),
                       .init(classification: .distraction, seconds: 2 * 60)],
            elapsed: 20 * 60, planned: nil, current: nil
        )
        XCTAssertEqual(grid.focusPercent, 80)
    }

    func testSessionSummaryLeavesNeutralTimeOut() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!
        let session = Session(startedAt: start)
        context.insert(session)
        for (offset, seconds, classification) in [(0.0, 299.0, Classification.focus),
                                                  (300, 99, .distraction),
                                                  (400, 599, .neutral)] {
            let event = ActivityEvent(startedAt: start.addingTimeInterval(offset),
                                      endedAt: start.addingTimeInterval(offset + seconds),
                                      bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", session: session)
            event.classification = classification
            context.insert(event)
        }
        session.endedAt = start.addingTimeInterval(1000)
        Persistence.save(context)

        let summary = MenuInsightsBuilder.summary(for: session, now: start.addingTimeInterval(1000))
        XCTAssertEqual(summary.focusShare, 0.75, accuracy: 0.001)   // 300 / (300 + 100)
    }
}
