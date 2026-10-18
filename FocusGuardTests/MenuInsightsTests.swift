import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class MenuInsightsTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    @discardableResult
    private func event(_ start: Date, _ seconds: TimeInterval, _ c: Classification,
                       app: String = "Xcode", bundle: String = "com.apple.dt.Xcode", url: String? = nil,
                       session: Session? = nil) -> ActivityEvent {
        let e = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(seconds),
                              bundleIdentifier: bundle, appName: app, url: url, session: session)
        e.classification = c
        context.insert(e)
        return e
    }

    private var morning: Date { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now)! }

    func testMergedSpansJoinSameKindAcrossSmallGaps() {
        let t = morning
        let events = [
            event(t, 59, .focus),
            event(t.addingTimeInterval(61), 59, .focus),          // 1 s gap: merges
            event(t.addingTimeInterval(200), 30, .distraction),
            event(t.addingTimeInterval(400), 60, .focus),         // 170 s gap: new span
        ]
        let spans = MenuInsightsBuilder.mergedSpans(events, from: Calendar.current.startOfDay(for: t))
        XCTAssertEqual(spans.map(\.kind), [.focus, .drift, .focus])
        XCTAssertEqual(spans[0].end.timeIntervalSince(spans[0].start), 121, accuracy: 0.5)
    }

    func testUsageRowsSplitBrowsersIntoSites() {
        let t = morning
        event(t, 600, .focus)
        event(t.addingTimeInterval(700), 300, .distraction, app: "Safari", bundle: "com.apple.Safari",
              url: "https://www.youtube.com/watch?v=1")
        event(t.addingTimeInterval(1100), 120, .focus, app: "Safari", bundle: "com.apple.Safari",
              url: "https://github.com/anarzone")
        Persistence.save(context)

        let rows = MenuInsightsBuilder.usageRows(context: context, from: t, to: t.addingTimeInterval(3600), limit: 10)
        XCTAssertEqual(rows.map(\.name), ["Xcode", "youtube.com", "github.com"])
        XCTAssertEqual(rows[1].host, "youtube.com")
        XCTAssertEqual(rows[1].classification, .distraction)
        XCTAssertNil(rows[0].host)
    }

    func testSessionSummaryFocusShare() {
        let t = morning
        let session = Session(startedAt: t, label: "Deep work", plannedDurationMinutes: 25)
        context.insert(session)
        event(t, 299, .focus, session: session)                  // 300 s
        event(t.addingTimeInterval(300), 99, .distraction, session: session)  // 100 s
        session.endedAt = t.addingTimeInterval(400)
        Persistence.save(context)

        let summary = MenuInsightsBuilder.summary(for: session, now: t.addingTimeInterval(400))
        XCTAssertEqual(summary.focusShare, 0.75, accuracy: 0.001)
        XCTAssertEqual(summary.minutes, 6)
        XCTAssertFalse(summary.isRunning)
    }

    func testDeletingASessionKeepsItsActivity() {
        let t = morning
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context),
                                      classifier: Classifier(context: context))
        let manager = SessionManager(context: context, tracker: tracker)
        let session = Session(startedAt: t, label: "Old")
        session.endedAt = t.addingTimeInterval(60)
        context.insert(session)
        event(t, 59, .focus, session: session)
        Persistence.save(context)

        manager.delete(session)

        XCTAssertEqual(Persistence.fetch(context, FetchDescriptor<Session>()).count, 0)
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.session)
    }

    func testSiteCategoryIsTheOneCoveringMostTime() {
        let t = morning
        // 5 min distracting, then a 1 min stray neutral event, then 2 min distracting.
        event(t, 300, .distraction, app: "Safari", bundle: "com.apple.Safari", url: "https://www.youtube.com/a")
        event(t.addingTimeInterval(300), 60, .neutral, app: "Safari", bundle: "com.apple.Safari", url: "https://www.youtube.com/b")
        event(t.addingTimeInterval(360), 120, .distraction, app: "Safari", bundle: "com.apple.Safari", url: "https://www.youtube.com/c")
        Persistence.save(context)

        for _ in 0..<5 { // fetch order isn't fixed; the answer must be
            let rows = MenuInsightsBuilder.usageRows(context: context, from: t, to: t.addingTimeInterval(3600), limit: 5)
            XCTAssertEqual(rows.first?.host, "youtube.com")
            XCTAssertEqual(rows.first?.classification, .distraction)
        }
    }

    func testTallyPrefersDriftOnTies() {
        var tally = ClassificationTally()
        tally.add(60, .focus)
        tally.add(60, .distraction)
        XCTAssertEqual(tally.dominant, .distraction)
        tally.add(1, .focus)
        XCTAssertEqual(tally.dominant, .focus)
    }
}
