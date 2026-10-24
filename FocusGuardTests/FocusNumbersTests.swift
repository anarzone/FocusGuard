import XCTest
import SwiftData
@testable import FocusGuard

/// "How focused was I?": focused time, focus rate, sessions and the best
/// stretch, for today, yesterday and this week.
@MainActor
final class FocusNumbersTests: XCTestCase {
    private var container: ModelContainer!
    private let calendar = Calendar.current
    private lazy var noon = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

    override func setUpWithError() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func at(daysAgo: Int, hour: Double) -> Date {
        calendar.startOfDay(for: noon).addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
    }

    @discardableResult
    private func session(daysAgo: Int, hour: Double) -> Session {
        let session = Session(startedAt: at(daysAgo: daysAgo, hour: hour), plannedDurationMinutes: 50)
        container.mainContext.insert(session)
        return session
    }

    private func event(daysAgo: Int, from hour: Double, minutes: Double, _ kind: Classification, in session: Session? = nil) {
        let start = at(daysAgo: daysAgo, hour: hour)
        let event = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                                  bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", session: session)
        event.classification = kind
        container.mainContext.insert(event)
    }

    func testToday() throws {
        let morning = session(daysAgo: 0, hour: 9)
        event(daysAgo: 0, from: 9, minutes: 40, .focus, in: morning)
        event(daysAgo: 0, from: 9 + 40.0 / 60, minutes: 10, .distraction, in: morning)
        event(daysAgo: 0, from: 10, minutes: 30, .neutral)
        session(daysAgo: 0, hour: 11)
        event(daysAgo: 1, from: 9, minutes: 60, .focus)
        try container.mainContext.save()

        let today = FocusNumbers.summary(.today, context: container.mainContext, now: noon)
        XCTAssertEqual(today.focused, 40 * 60, accuracy: 1)
        XCTAssertEqual(today.drifted, 10 * 60, accuracy: 1)
        XCTAssertEqual(today.other, 30 * 60, accuracy: 1)
        XCTAssertEqual(today.sessions, 2)
        // Other time is left out of the rate: 40 / (40 + 10).
        XCTAssertEqual(today.focusPercent, 80)
        XCTAssertEqual(today.bestStretch, 40 * 60, accuracy: 2)
        XCTAssertEqual(FocusNumbers.sentence(for: today), "Today so far: 40m focused, 80% focus rate, 2 sessions.")
    }

    func testYesterdayAndThisWeek() throws {
        event(daysAgo: 0, from: 9, minutes: 30, .focus)
        event(daysAgo: 1, from: 9, minutes: 90, .focus)
        session(daysAgo: 1, hour: 9)
        try container.mainContext.save()

        let yesterday = FocusNumbers.summary(.yesterday, context: container.mainContext, now: noon)
        XCTAssertEqual(yesterday.focused, 90 * 60, accuracy: 1)
        XCTAssertEqual(yesterday.sessions, 1)
        XCTAssertEqual(FocusNumbers.sentence(for: yesterday), "Yesterday: 1h 30m focused, 100% focus rate, 1 session.")

        let week = FocusNumbers.summary(.thisWeek, context: container.mainContext, now: noon)
        let range = FocusNumbers.range(of: .thisWeek, now: noon, calendar: calendar)
        let yesterdayInWeek = range.contains(at(daysAgo: 1, hour: 9))
        XCTAssertEqual(week.focused, (yesterdayInWeek ? 120 : 30) * 60, accuracy: 1)
    }

    func testNothingTracked() {
        let today = FocusNumbers.summary(.today, context: container.mainContext, now: noon)
        XCTAssertEqual(today.focusRate, 0)
        XCTAssertEqual(FocusNumbers.sentence(for: today), "Nothing tracked today yet.")
    }

    func testBackgroundReadMatches() async throws {
        event(daysAgo: 0, from: 9, minutes: 25, .focus)
        try container.mainContext.save()
        let summary = await FocusNumbers.summary(.today, container: container, now: noon)
        XCTAssertEqual(summary.focused, 25 * 60, accuracy: 1)
    }
}
