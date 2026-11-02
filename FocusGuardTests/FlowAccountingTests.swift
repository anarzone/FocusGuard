import SwiftData
import XCTest
@testable import FocusGuard

/// The same time on every page: Today, Reports (kept day summaries and all),
/// Apps & Sites and the menu agree with each other and with the raw events.
/// The numbers go through `StatsStore`, as the pages do.
@MainActor
final class FlowAccountingTests: XCTestCase {
    private typealias Rig = FlowRig
    private let calendar = Calendar.current
    private var container: ModelContainer!
    private var context: ModelContext!
    /// Noon today; yesterday and last month are in reach whatever today is.
    private lazy var now = calendar.startOfDay(for: .now).addingTimeInterval(12 * 3600)
    private lazy var today = calendar.startOfDay(for: now)

    override func setUpWithError() throws {
        container = try Rig.makeContainer()
        context = container.mainContext
    }

    private func at(daysAgo: Int = 0, _ hours: Double) -> Date {
        (calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today).addingTimeInterval(hours * 3600)
    }

    private func raw(from: Date, to: Date) -> BreakdownSnapshot {
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>())
        var tally = ClassificationTally()
        for event in events {
            let seconds = min(event.endedAt, to).timeIntervalSince(max(event.startedAt, from))
            if seconds > 0 { tally.add(seconds, event.classification ?? .neutral) }
        }
        return BreakdownSnapshot(focus: tally.focus, neutral: tally.neutral, distraction: tally.distraction)
    }

    /// A morning of everything: in a session and out of one, an app, a site,
    /// and a browser with no page known.
    private func fillToday() throws -> Session {
        let session = Session(startedAt: at(9), status: .completed, plannedDurationMinutes: 50)
        session.endedAt = at(9.75)
        session.autoName = "Steady Run"
        context.insert(session)
        ActivityEvent.add(to: context, .focus, from: at(9), seconds: 30 * 60, session: session)
        ActivityEvent.add(to: context, .distraction, from: at(9.5), seconds: 10 * 60, app: Rig.safari,
                          url: "https://www.x.com/home", session: session)
        ActivityEvent.add(to: context, .neutral, from: at(9 + 40.0 / 60), seconds: 5 * 60, app: Rig.notes, session: session)
        ActivityEvent.add(to: context, .focus, from: at(10), seconds: 10 * 60)
        ActivityEvent.add(to: context, .focus, from: at(10.25), seconds: 5 * 60, app: Rig.safari, url: "https://github.com/x")
        ActivityEvent.add(to: context, .neutral, from: at(10.5), seconds: 5 * 60, app: Rig.safari)
        try context.save()
        return session
    }

    func testTodaysPagesAgreeWithTheEvents() async throws {
        _ = try fillToday()
        // Yesterday's, so finished days go through the kept summaries too.
        ActivityEvent.add(to: context, .focus, from: at(daysAgo: 1, 9), seconds: 60 * 60)
        ActivityEvent.add(to: context, .distraction, from: at(daysAgo: 1, 10), seconds: 15 * 60, app: Rig.feed)
        try context.save()
        let stats = StatsStore(container: container)
        let truth = raw(from: today, to: now)

        let page = await stats.todayPage(day: now, now: now)
        XCTAssertEqual(page.model.focused, truth.focus, accuracy: 0.5)
        XCTAssertEqual(page.model.drifted, truth.distraction, accuracy: 0.5)
        XCTAssertEqual(page.model.focusedInSessions, 30 * 60, accuracy: 0.5)
        XCTAssertEqual(page.model.focusRate, FocusRate.of(focused: truth.focus, drifted: truth.distraction), accuracy: 0.001)

        let menu = await stats.menuStats(now: now, includeStreak: false)
        XCTAssertEqual(menu.today.focus, truth.focus, accuracy: 0.5)
        XCTAssertEqual(menu.today.neutral, truth.neutral, accuracy: 0.5)
        XCTAssertEqual(menu.today.distraction, truth.distraction, accuracy: 0.5)

        let insights = await stats.today(now: now)
        XCTAssertEqual(insights.focused, truth.focus, accuracy: 0.5)
        XCTAssertEqual(insights.focusRate, page.model.focusRate, accuracy: 0.001)

        // Reports for this week and this month hold today and whatever
        // earlier days are in them.
        for period in [ReportPeriod.week, .month] {
            let interval = period.interval(offset: 0, now: now)
            let periodTruth = raw(from: interval.start, to: now)
            let report = await stats.reports(period: period, offset: 0, now: now, historyStart: nil, weekendsCount: true)
            XCTAssertEqual(report.data.breakdown.focus, periodTruth.focus, accuracy: 0.5, "\(period)")
            XCTAssertEqual(report.data.breakdown.neutral, periodTruth.neutral, accuracy: 0.5, "\(period)")
            XCTAssertEqual(report.data.breakdown.distraction, periodTruth.distraction, accuracy: 0.5, "\(period)")
        }

        // Apps & Sites, by way of the rows with sessions split out.
        let usage = await stats.appUsage(from: today, to: now, limit: 40)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.seconds }, truth.total, accuracy: 0.5)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.inSession }, 45 * 60, accuracy: 0.5)
    }

    /// A browser with no page known (a new tab, or one it couldn't read) is
    /// real time: the rows split a browser into its sites and keep the rest.
    func testAppsAndSitesKeepsABrowsersTimeWithNoPage() async throws {
        _ = try fillToday()
        let stats = StatsStore(container: container)
        let truth = raw(from: today, to: now)
        let rows = await stats.usageRows(from: today, to: now, limit: 40)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.seconds }, truth.total, accuracy: 0.5)
        let noPage = try XCTUnwrap(rows.first { $0.id == Rig.safari.bundleId })
        XCTAssertEqual(noPage.seconds, 5 * 60, accuracy: 0.5)
        XCTAssertEqual(noPage.classification, .neutral, "how that time counted, not the sites'")
        XCTAssertNil(noPage.host)
    }

    /// An event ends exactly where the next begins (#81), so nothing can be
    /// added per event: the bars and the goal count what Today counts.
    func testReportsBarsMatchTodayWithManyShortEvents() async throws {
        // Just short of a 4-hour goal, in 120 stretches of 2 minutes.
        for stretch in 0..<119 {
            ActivityEvent.add(to: context, .focus, from: at(6).addingTimeInterval(TimeInterval(stretch) * 120), seconds: 120,
                              title: "Window \(stretch)")
        }
        ActivityEvent.add(to: context, .focus, from: at(6).addingTimeInterval(119 * 120), seconds: 60)
        try context.save()
        let stats = StatsStore(container: container)
        let goal: TimeInterval = 4 * 3600

        let page = await stats.todayPage(day: now, now: now)
        XCTAssertEqual(page.model.focused, goal - 60, accuracy: 0.5, "one minute short")

        let days = DaySummaries(context: context, now: now) { DaySummary.make(days: $0, context: self.context) }
        let report = ReportsModelBuilder.build(period: .week, offset: 0, context: context, now: now, weekendsCount: true,
                                               goal: { _ in goal }, summaries: days)
        let bar = try XCTUnwrap(report.data.buckets.first { $0.interval.start == today })
        XCTAssertEqual(report.data.breakdown.focus, page.model.focused, accuracy: 0.5, "the totals agree")
        XCTAssertEqual(bar.focus, page.model.focused, accuracy: 1, "the bar")
        XCTAssertEqual(report.goal.met, 0, "not met on Today")
    }

    /// The rate shown on a session's row comes from the same seconds.
    func testASessionsRateIsItsFocusOverFocusPlusDrift() throws {
        let session = Session(startedAt: at(9), status: .completed)
        session.endedAt = at(10)
        context.insert(session)
        // 30 minutes of focus in one go; 30 of drift flicking between 100 pages.
        ActivityEvent.add(to: context, .focus, from: at(9), seconds: 30 * 60, session: session)
        for page in 0..<100 {
            ActivityEvent.add(to: context, .distraction, from: at(9.5).addingTimeInterval(TimeInterval(page) * 18), seconds: 18,
                              app: Rig.feed, title: "Page \(page)", session: session)
        }
        // And the other way round: focus in 100 short stretches.
        let other = Session(startedAt: at(10), status: .completed)
        other.endedAt = at(11)
        context.insert(other)
        for stretch in 0..<100 {
            ActivityEvent.add(to: context, .focus, from: at(10).addingTimeInterval(TimeInterval(stretch) * 9), seconds: 9,
                              title: "File \(stretch)", session: other)
        }
        ActivityEvent.add(to: context, .distraction, from: at(10.25), seconds: 15 * 60, app: Rig.feed, session: other)
        try context.save()

        let row = TodayModelBuilder.item(for: session, now: now)
        let otherRow = TodayModelBuilder.item(for: other, now: now)
        let summary = MenuInsightsBuilder.summary(for: session, now: now)
        XCTAssertEqual(row.rate, 0.5, accuracy: 0.005)
        XCTAssertEqual(otherRow.rate, 0.5, accuracy: 0.005)
        XCTAssertEqual(summary.focusShare, 0.5, accuracy: 0.005)
    }

    /// The ring's cells each go to whatever was most of a minute. Focus 40 s,
    /// drift 20 s, every minute: every cell's focus, and still a 67% rate on
    /// the recap, the break screen and the session-over page.
    func testTheRecapsRateIsTheSessionsRate() throws {
        let session = Session(startedAt: at(9), status: .completed, plannedDurationMinutes: 30)
        session.endedAt = at(9.5)
        context.insert(session)
        for minute in 0..<30 {
            let start = at(9).addingTimeInterval(TimeInterval(minute) * 60)
            ActivityEvent.add(to: context, .focus, from: start, seconds: 40, session: session)
            ActivityEvent.add(to: context, .distraction, from: start.addingTimeInterval(40), seconds: 20, app: Rig.feed, session: session)
        }
        try context.save()

        let recap = SessionRecap(session: session, bestZoneToday: 0)
        let row = TodayModelBuilder.item(for: session, now: now)
        XCTAssertEqual(row.rate, 2.0 / 3, accuracy: 0.02)
        XCTAssertEqual(Double(recap.timeline.focusPercent), row.rate * 100, accuracy: 3)
    }

    // MARK: - Week and month boundaries

    func testAnEventAcrossAWeekOrMonthBoundaryIsCountedOnceEitherSide() throws {
        let calendar = Calendar.fixed("UTC")
        let now = calendar.at(2026, 11, 2, 12)     // A Monday, the 2nd.
        // Sunday 1 Nov 23:30 to Monday 2 Nov 00:30.
        ActivityEvent.add(to: context, .focus, from: calendar.at(2026, 11, 1, 23, 30), seconds: 3600)
        // Saturday 31 Oct 23:30 to Sunday 1 Nov 00:30.
        ActivityEvent.add(to: context, .distraction, from: calendar.at(2026, 10, 31, 23, 30), seconds: 3600, app: Rig.feed)
        try context.save()
        let days = DaySummaries(context: context, now: now, calendar: calendar) {
            DaySummary.make(days: $0, context: self.context, calendar: calendar)
        }

        for build in [{ (period: ReportPeriod, offset: Int) in
            ReportDataBuilder.build(period: period, offset: offset, context: self.context, now: now, calendar: calendar)
        }, { (period: ReportPeriod, offset: Int) in
            ReportDataBuilder.build(period: period, offset: offset, days: days) ?? .empty
        }] {
            let thisWeek = build(.week, 0)
            let lastWeek = build(.week, 1)
            XCTAssertEqual(thisWeek.breakdown.focus, 30 * 60, accuracy: 0.1)
            XCTAssertEqual(lastWeek.breakdown.focus, 30 * 60, accuracy: 0.1)
            XCTAssertEqual(lastWeek.breakdown.distraction, 60 * 60, accuracy: 0.1)

            let thisMonth = build(.month, 0)
            let lastMonth = build(.month, 1)
            XCTAssertEqual(thisMonth.breakdown.focus, 60 * 60, accuracy: 0.1)
            XCTAssertEqual(thisMonth.breakdown.distraction, 30 * 60, accuracy: 0.1)
            XCTAssertEqual(lastMonth.breakdown.distraction, 30 * 60, accuracy: 0.1)
        }
    }

    // MARK: - Deleted sessions

    func testDeletingASessionKeepsItsTimeEverywhere() async throws {
        let session = try fillToday()
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: Classifier(context: context))
        let manager = SessionManager(context: context, tracker: tracker)
        let stats = StatsStore(container: container)
        let before = await stats.todayPage(day: now, now: now)
        let reportBefore = await stats.reports(period: .week, offset: 0, now: now, historyStart: nil, weekendsCount: true)
        XCTAssertEqual(before.model.sessions.count, 1)
        XCTAssertEqual(reportBefore.data.sessionCount, 1)

        manager.delete(session)
        try context.save()

        let after = await stats.todayPage(day: now, now: now)
        let reportAfter = await stats.reports(period: .week, offset: 0, now: now, historyStart: nil, weekendsCount: true)
        XCTAssertEqual(after.model.focused, before.model.focused, accuracy: 0.5)
        XCTAssertEqual(after.model.drifted, before.model.drifted, accuracy: 0.5)
        XCTAssertEqual(after.model.sessions.count, 0)
        XCTAssertEqual(after.model.focusedInSessions, 0, accuracy: 0.5, "no session holds it now")
        XCTAssertEqual(reportAfter.data.breakdown.focus, reportBefore.data.breakdown.focus, accuracy: 0.5)
        XCTAssertEqual(reportAfter.data.sessionCount, 0)
        XCTAssertEqual(reportAfter.data.buckets.map(\.focus), reportBefore.data.buckets.map(\.focus))
    }

    // MARK: - Focus rate's edges

    func testNoClassifiedTimeHasNoRateAndAllDriftIsZero() throws {
        ActivityEvent.add(to: context, .neutral, from: at(9), seconds: 30 * 60, app: Rig.notes)
        try context.save()
        let neutral = TodayModelBuilder.build(day: now, context: context, now: now)
        XCTAssertFalse(neutral.hasRate, "other apps don't make a rate")
        XCTAssertEqual(neutral.focusRate, 0)

        ActivityEvent.add(to: context, .distraction, from: at(10), seconds: 30 * 60, app: Rig.feed)
        try context.save()
        let drift = TodayModelBuilder.build(day: now, context: context, now: now)
        XCTAssertTrue(drift.hasRate)
        XCTAssertEqual(drift.focusRate, 0, "all drift")

        XCTAssertEqual(FocusRate.percent(focused: 0, drifted: 0), 0)
        XCTAssertEqual(FocusRate.percent(focused: 100, drifted: 0), 100)
        XCTAssertEqual(FocusRate.of(focused: -5, drifted: -5), 0)
    }

    /// A session only in neutral apps has nothing to rate, and its name says
    /// so ("Quiet"). It shows "–": 0% is for a session that was all drift.
    func testASessionWithNothingClassifiedIsntShownAsZeroPercent() throws {
        let session = Session(startedAt: at(9), status: .completed)
        session.endedAt = at(9.5)
        context.insert(session)
        ActivityEvent.add(to: context, .neutral, from: at(9), seconds: 30 * 60, app: Rig.notes, session: session)
        try context.save()
        let row = TodayModelBuilder.item(for: session, now: now)
        XCTAssertEqual(SessionNamer.pattern(of: SessionTimeline.segments(from: session.events)), .quiet)
        XCTAssertFalse(row.hasRate)
        XCTAssertFalse(MenuInsightsBuilder.summary(for: session, now: now).hasRate)
        let recap = SessionRecap(session: session, bestZoneToday: 0)
        XCTAssertFalse(recap.timeline.hasFocusRate)
        XCTAssertNil(recap.timeline.knownFocusPercent)
        XCTAssertNil(AppState.completionPercent(of: session))
        XCTAssertEqual(FinishedSession(name: "Quiet Run", minutes: 30, focusPercent: nil).detail, "· 30 min")

        // All drift is a figure, and it's 0%.
        ActivityEvent.add(to: context, .distraction, from: at(9.5), seconds: 60, app: Rig.feed, session: session)
        try context.save()
        XCTAssertTrue(TodayModelBuilder.item(for: session, now: now).hasRate)
        XCTAssertEqual(AppState.completionPercent(of: session), 0)
    }

    func testAutomaticNamesFollowTheSameRate() {
        func name(focus: TimeInterval, drift: TimeInterval) -> SessionNamer.Pattern {
            SessionNamer.pattern(of: [.init(classification: .focus, seconds: focus), .init(classification: .distraction, seconds: drift),
                                      .init(classification: .neutral, seconds: 10_000)])
        }
        // Neutral time is left out: 90% of focus + drift, however much neutral there is.
        XCTAssertEqual(name(focus: 900, drift: 100), .lockedIn)
        XCTAssertEqual(name(focus: 30, drift: 20), .quiet, "under a minute of either")
    }

    // MARK: - Names in rows

    func testAHostWithWwwInsideItKeepsItsName() {
        var hosts = HostCache()
        XCTAssertEqual(hosts.host(of: "https://www.x.com/"), "x.com")
        XCTAssertEqual(hosts.host(of: "https://awww.space/"), "awww.space")
    }

    // MARK: - Empty

    func testNoDataAtAll() async throws {
        let stats = StatsStore(container: container)
        let page = await stats.todayPage(day: now, now: now)
        XCTAssertFalse(page.hasSessions, "the first-day page")
        XCTAssertEqual(page.streak, 0)
        XCTAssertEqual(page.model.focused, 0)
        XCTAssertFalse(page.model.hasRate)
        XCTAssertTrue(page.model.sessions.isEmpty)
        XCTAssertTrue(page.model.topApps.isEmpty)
        XCTAssertNil(page.model.trackingStarted)

        for period in [ReportPeriod.week, .month] {
            for offset in [0, 1, 12] {
                let report = await stats.reports(period: period, offset: offset, now: now, historyStart: nil, weekendsCount: false)
                XCTAssertEqual(report.data.breakdown.focus, 0)
                XCTAssertEqual(report.data.sessionCount, 0)
                XCTAssertTrue(report.highlights.isEmpty)
                XCTAssertNil(report.bestWeekNote)
                XCTAssertFalse(report.data.buckets.isEmpty)
            }
        }
        let rows = await stats.usageRows(from: today, to: now, limit: 40)
        XCTAssertTrue(rows.isEmpty)
        let week = await stats.week(streak: 0, now: now)
        XCTAssertNil(week.bestDay)
        XCTAssertEqual(week.focusRate, 0)
    }

    func testOneSessionWithNoEvents() throws {
        let session = Session(startedAt: at(9), status: .completed)
        session.endedAt = at(9, plus: 5)
        context.insert(session)
        try context.save()
        let model = TodayModelBuilder.build(day: now, context: context, now: now)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].rate, 0)
        XCTAssertTrue(model.sessions[0].runs.isEmpty)
        XCTAssertEqual(model.sessions[0].shape, TodayModelBuilder.shape(of: .quiet))
    }

    private func at(_ hours: Double, plus seconds: TimeInterval) -> Date { at(hours).addingTimeInterval(seconds) }

    func testYearsOfDataAddUpAndFormatInReadableUnits() throws {
        let calendar = Calendar.fixed("UTC")
        let now = calendar.at(2026, 11, 2, 12)
        // Three years of a whole day's focus a day: the extreme for every counter.
        for back in 1...(3 * 365) {
            let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)) ?? now
            ActivityEvent.add(to: context, .focus, from: day.addingTimeInterval(6 * 3600), seconds: 12 * 3600)
        }
        try context.save()
        let days = DaySummaries(context: context, now: now, calendar: calendar) {
            DaySummary.make(days: $0, context: self.context, calendar: calendar)
        }
        let month = try XCTUnwrap(ReportDataBuilder.build(period: .month, offset: 1, days: days))
        XCTAssertEqual(month.breakdown.focus, 31 * 12 * 3600, accuracy: 1)

        XCTAssertEqual(WindowFormat.hm(month.breakdown.focus), "372h")
        XCTAssertEqual(WindowFormat.hm(3 * 365 * 12 * 3600 + 300), "13,140h 05m")
        XCTAssertEqual(AppUsageEntry.format(seconds: 13_140 * 3600), "13,140h")
    }
}
