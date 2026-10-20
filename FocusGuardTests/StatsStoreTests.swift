import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class StatsStoreTests: XCTestCase {
    private var container: ModelContainer!
    private let calendar = Calendar.current
    private lazy var noon = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

    override func setUpWithError() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func event(daysAgo: Int, from hour: Double, minutes: Double, _ kind: Classification) -> ActivityEvent {
        let start = calendar.startOfDay(for: noon).addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
        let event = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                                  bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        event.classification = kind
        container.mainContext.insert(event)
        return event
    }

    func testBackgroundNumbersMatchTheMainThreadOnes() async throws {
        event(daysAgo: 1, from: 10, minutes: 30, .focus)
        event(daysAgo: 0, from: 10, minutes: 20, .focus)
        event(daysAgo: 0, from: 10.5, minutes: 10, .distraction)
        try container.mainContext.save()

        let stats = StatsStore(container: container)
        let menu = await stats.menuStats(now: noon, includeStreak: true)
        XCTAssertEqual(menu.today.focus, 20 * 60, accuracy: 1)
        XCTAssertEqual(menu.today.distraction, 10 * 60, accuracy: 1)
        XCTAssertEqual(menu.spans.count, 2)
        XCTAssertEqual(menu.streak, StreakCalculator(context: container.mainContext).currentStreak(now: noon))

        let today = await stats.today(now: noon)
        let reference = MenuInsightsBuilder.today(context: container.mainContext, now: noon)
        XCTAssertEqual(today.focused, reference.focused, accuracy: 1)
        XCTAssertEqual(today.averageFocusRate ?? -1, reference.averageFocusRate ?? -1, accuracy: 0.0001)
    }

    func testReclassifiedPastDaysAreReadAgainOnceForgotten() async throws {
        let yesterday = event(daysAgo: 1, from: 10, minutes: 30, .focus)
        event(daysAgo: 0, from: 10, minutes: 20, .focus)
        try container.mainContext.save()

        let stats = StatsStore(container: container)
        let before = await stats.today(now: noon)
        XCTAssertEqual(before.averageFocusRate ?? -1, 1, accuracy: 0.0001)   // yesterday was all focus

        yesterday.classification = .distraction
        try container.mainContext.save()
        let cached = await stats.today(now: noon)
        XCTAssertEqual(cached.averageFocusRate ?? -1, 1, accuracy: 0.0001)   // finished days are kept…

        await stats.forgetPastDays()                                          // …until told they changed
        let after = await stats.today(now: noon)
        XCTAssertEqual(after.averageFocusRate ?? -1, 0, accuracy: 0.0001)
    }
}
