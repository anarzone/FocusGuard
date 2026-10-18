import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class ReportDataTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var calendar: Calendar!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    /// Wednesday 2026-10-14 15:00 UTC.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15))! }

    private func event(_ start: Date, _ seconds: TimeInterval, _ c: Classification) {
        let e = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(seconds),
                              bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        e.classification = c
        context.insert(e)
    }

    func testPeriodIntervalsStepBack() {
        let week = ReportPeriod.week.interval(offset: 0, now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: week.start), 2)
        XCTAssertEqual(week.duration, 7 * 86_400, accuracy: 1)
        let lastWeek = ReportPeriod.week.interval(offset: 1, now: now, calendar: calendar)
        XCTAssertEqual(lastWeek.end, week.start)
        let month = ReportPeriod.month.interval(offset: 0, now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: month.start), 1)
    }

    func testBucketsPerPeriod() {
        let week = ReportPeriod.week.interval(offset: 0, now: now, calendar: calendar)
        let days = ReportDataBuilder.bucketIntervals(period: .week, interval: week, events: [], now: now, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.filter(\.isFuture).count, 4) // Thu–Sun

        let year = ReportPeriod.year.interval(offset: 0, now: now, calendar: calendar)
        XCTAssertEqual(ReportDataBuilder.bucketIntervals(period: .year, interval: year, events: [], now: now, calendar: calendar).count, 12)

        let day = ReportPeriod.day.interval(offset: 0, now: now, calendar: calendar)
        let hours = ReportDataBuilder.bucketIntervals(period: .day, interval: day, events: [], now: now, calendar: calendar)
        XCTAssertEqual(hours.count, 12) // 7 AM – 7 PM by default
    }

    func testBuildSplitsTimeIntoBucketsAndHeat() {
        let monday9 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        event(monday9, 3600, .focus)                                 // Mon 9–10 focus
        event(monday9.addingTimeInterval(3600), 1800, .distraction)  // Mon 10–10:30 drift
        Persistence.save(context)

        let data = ReportDataBuilder.build(period: .week, offset: 0, context: context, now: now, calendar: calendar)
        let monday = data.buckets[0]
        XCTAssertEqual(monday.focus, 3601, accuracy: 2)
        XCTAssertEqual(monday.drift, 1801, accuracy: 2)
        XCTAssertEqual(data.heat[0][9], 3600, accuracy: 2)   // Monday row, 9 AM
        XCTAssertEqual(data.heat[0][10], 1, accuracy: 2)     // spill-over second only
        XCTAssertEqual(data.goalPerBucket, FocusGoal.dailySeconds)
    }
}
