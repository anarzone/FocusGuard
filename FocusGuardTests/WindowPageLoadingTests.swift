import XCTest
import SwiftData
@testable import FocusGuard

/// The window's pages load on `StatsStore` through quicker paths (one read
/// per report, finished days from kept totals, cached hours and hosts).
/// They must give the same numbers as the plain builders.
@MainActor
final class WindowPageLoadingTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    /// Ten weeks of mixed days, with late events running past midnight and
    /// browser time on a few sites. Nothing after `now`.
    private func seed(now: Date) throws {
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let day: [(hour: Int, minutes: Double, kind: Classification, url: String?)] = [
            (9, 50, .focus, nil), (10, 15, .distraction, "https://www.youtube.com/watch?v=1"),
            (11, 20, .distraction, "https://x.com/home"), (14, 30, .neutral, nil),
            (15, 45, .focus, "https://github.com/anarzone/FocusGuard"), (23, 90, .focus, nil),
        ]
        for back in 0..<70 {
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            for (hour, minutes, kind, url) in day {
                guard let start = calendar.date(byAdding: .hour, value: hour, to: date) else { continue }
                let end = start.addingTimeInterval(minutes * 60)
                guard end <= now else { continue }
                let event = ActivityEvent(startedAt: start, endedAt: end,
                                          bundleIdentifier: url == nil ? "com.apple.dt.Xcode" : "com.google.Chrome",
                                          appName: url == nil ? "Xcode" : "Google Chrome")
                event.url = url
                event.classification = kind
                context.insert(event)
            }
        }
        try context.save()
    }

    private func assertClose(_ a: BreakdownSnapshot, _ b: BreakdownSnapshot, _ label: String) {
        XCTAssertEqual(a.focus, b.focus, accuracy: 0.01, label)
        XCTAssertEqual(a.neutral, b.neutral, accuracy: 0.01, label)
        XCTAssertEqual(a.distraction, b.distraction, accuracy: 0.01, label)
    }

    func testReportsFromTheStatsStoreMatchTheDirectBuild() async throws {
        let now = Date.now
        try seed(now: now)
        let store = StatsStore(container: container)

        for (period, offset) in [(ReportPeriod.week, 0), (.week, 1), (.week, 4), (.month, 0), (.month, 1)] {
            let label = "\(period.rawValue) \(offset)"
            let fast = await store.reports(period: period, offset: offset, now: now, historyStart: nil, weekendsCount: false)
            let direct = ReportsModelBuilder.build(period: period, offset: offset, context: ModelContext(container), now: now)

            assertClose(fast.data.breakdown, direct.data.breakdown, label)
            assertClose(fast.data.previous, direct.data.previous, label)
            XCTAssertEqual(fast.trend.map(\.start), direct.trend.map(\.start), label)
            for (a, b) in zip(fast.trend, direct.trend) { XCTAssertEqual(a.focus, b.focus, accuracy: 0.01, label) }
            for (a, b) in zip(fast.heat.joined(), direct.heat.joined()) { XCTAssertEqual(a, b, accuracy: 0.01, label) }
            XCTAssertEqual(fast.data.heatHours, direct.data.heatHours, label)
            XCTAssertEqual(fast.data.apps.map(\.id), direct.data.apps.map(\.id), label)
            XCTAssertEqual(fast.data.distractions.map(\.name), direct.data.distractions.map(\.name), label)
            XCTAssertEqual(fast.data.buckets.map(\.focus), direct.data.buckets.map(\.focus), label)
        }
    }

    func testReadingOnceGivesTheSameTotalsAsReadingAgain() throws {
        let now = Date.now
        try seed(now: now)
        let context = ModelContext(container)
        let reports = ReportBuilder(context: context)
        let to = now, from = now.addingTimeInterval(-9 * 86_400)
        // A wider read than the range, as the report does.
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>())

        assertClose(ReportBuilder.breakdown(events, from: from, to: to), reports.breakdown(from: from, to: to), "breakdown")
        XCTAssertEqual(ReportBuilder.topApps(events, from: from, to: to, limit: 10).map(\.seconds),
                       reports.topApps(from: from, to: to, limit: 10).map(\.seconds))
        XCTAssertEqual(ReportBuilder.topDistractions(events, from: from, to: to).map(\.name),
                       reports.topDistractions(from: from, to: to).map(\.name))
        XCTAssertEqual(MenuInsightsBuilder.usageRows(events: events, from: from, to: to, limit: 8),
                       MenuInsightsBuilder.usageRows(context: context, from: from, to: to, limit: 8))
    }

    func testHourCursorMatchesTheCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        var cursor = HourCursor(calendar: calendar)
        // Across the October clock change, minute by minute through a few hours.
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 10))!
        for minute in stride(from: 0, to: 6 * 60, by: 7) {
            let date = start.addingTimeInterval(TimeInterval(minute * 60))
            let slot = cursor.slot(at: date)
            XCTAssertEqual(slot.start, calendar.dateInterval(of: .hour, for: date)?.start)
            XCTAssertEqual(slot.hour, calendar.component(.hour, from: date))
            XCTAssertEqual(slot.row, (calendar.component(.weekday, from: date) - 2 + 7) % 7)
        }
    }

    func testHostCacheStripsWwwOnce() {
        var hosts = HostCache()
        XCTAssertEqual(hosts.host(of: "https://www.youtube.com/watch?v=1"), "youtube.com")
        XCTAssertEqual(hosts.host(of: "https://www.youtube.com/watch?v=1"), "youtube.com")
        XCTAssertNil(hosts.host(of: "not a url"))
    }
}
