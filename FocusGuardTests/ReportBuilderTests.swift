import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class ReportBuilderTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var builder: ReportBuilder!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        builder = ReportBuilder(context: context)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        builder = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func insertEvent(start: Date, end: Date, classification: Classification?, app: String = "App", url: String? = nil) {
        let e = ActivityEvent(
            startedAt: start,
            endedAt: end,
            bundleIdentifier: "com.\(app.lowercased())",
            appName: app,
            windowTitle: nil,
            url: url
        )
        e.classification = classification
        context.insert(e)
        Persistence.save(context)
    }

    // MARK: - Breakdown

    func test_breakdownSumsByClassification() {
        let now = Date()
        insertEvent(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-300), classification: .focus)        // 5m
        insertEvent(start: now.addingTimeInterval(-300), end: now.addingTimeInterval(-180), classification: .neutral)      // 2m
        insertEvent(start: now.addingTimeInterval(-180), end: now,                          classification: .distraction)  // 3m

        let result = builder.breakdown(from: now.addingTimeInterval(-700), to: now)
        XCTAssertEqual(result.focus, 300, accuracy: 1)         // 5m
        XCTAssertEqual(result.neutral, 120, accuracy: 1)        // 2m
        XCTAssertEqual(result.distraction, 180, accuracy: 1)    // 3m
    }

    func test_breakdownClipsEventsToWindow() {
        let now = Date()
        // Event spans before AND after the window — should be clipped.
        insertEvent(
            start: now.addingTimeInterval(-1000),
            end:   now.addingTimeInterval(+1000),
            classification: .focus
        )
        let result = builder.breakdown(from: now.addingTimeInterval(-100), to: now)
        XCTAssertEqual(result.focus, 100, accuracy: 1)
    }

    func test_breakdownTreatsNilClassificationAsNeutral() {
        let now = Date()
        insertEvent(start: now.addingTimeInterval(-60), end: now, classification: nil)
        let result = builder.breakdown(from: now.addingTimeInterval(-120), to: now)
        XCTAssertEqual(result.neutral, 60, accuracy: 1)
        XCTAssertEqual(result.focus, 0)
        XCTAssertEqual(result.distraction, 0)
    }

    // MARK: - Top distractions

    func test_topDistractionsExcludesNonDistractions() {
        let now = Date()
        insertEvent(start: now.addingTimeInterval(-300), end: now, classification: .focus, app: "Xcode")
        insertEvent(start: now.addingTimeInterval(-300), end: now, classification: .distraction, app: "Twitter", url: "https://twitter.com/")

        let entries = builder.topDistractions(from: now.addingTimeInterval(-400), to: now, limit: 5)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.subtitle, "twitter.com")
    }

    func test_topDistractionsGroupsByHost() {
        let now = Date()
        insertEvent(start: now.addingTimeInterval(-200), end: now.addingTimeInterval(-100),
                    classification: .distraction, app: "Chrome", url: "https://www.youtube.com/a")
        insertEvent(start: now.addingTimeInterval(-100), end: now,
                    classification: .distraction, app: "Chrome", url: "https://www.youtube.com/b")

        let entries = builder.topDistractions(from: now.addingTimeInterval(-300), to: now, limit: 5)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.seconds ?? -1, 200, accuracy: 1)
    }

    func test_topDistractionsLimitRespected() {
        let now = Date()
        for (i, host) in ["a.com", "b.com", "c.com"].enumerated() {
            let s = now.addingTimeInterval(TimeInterval(-300 + i * 60))
            let e = s.addingTimeInterval(60)
            insertEvent(start: s, end: e, classification: .distraction, app: "Chrome",
                        url: "https://\(host)/")
        }
        let entries = builder.topDistractions(from: now.addingTimeInterval(-400), to: now, limit: 2)
        XCTAssertEqual(entries.count, 2)
    }

    // MARK: - Timeline

    func test_timelineNoCrashWithEmptyEvents() {
        // The crash bug we fixed: previously `for m in startMin...endMin` could
        // trap when startMin > endMin. With no events, we just want zeros.
        let now = Date()
        let points = builder.timeline(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(points.count, 60)
        XCTAssertTrue(points.allSatisfy { $0.focus == 0 && $0.neutral == 0 && $0.distraction == 0 })
    }

    func test_timelineDistributesAcrossMinutes() {
        let now = Date()
        // Single 5-minute focus event right at the start of the window.
        insertEvent(
            start: now.addingTimeInterval(-300),
            end:   now,
            classification: .focus
        )
        let points = builder.timeline(from: now.addingTimeInterval(-300), to: now)
        XCTAssertEqual(points.count, 5)
        XCTAssertTrue(points.allSatisfy { $0.focus > 0 })
    }
}
