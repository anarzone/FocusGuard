import SwiftData
import XCTest
@testable import FocusGuard

/// Time's boundaries: midnight in a session, limits at 00:00, clock changes,
/// sleep and wake, a Mac asleep through a session's end.
@MainActor
final class FlowTimeTests: XCTestCase {
    private typealias Rig = FlowRig
    private typealias StubOverlay = EscalationEngineTests.StubOverlay
    private typealias Notifier = DailyLimitsEngineTests.RecordingNotifier

    // MARK: - Midnight in a session

    func testTheDaysSplitASessionThatRunsPastMidnight() throws {
        let calendar = Calendar.fixed("UTC")
        let container = try Rig.makeContainer()
        let context = container.mainContext
        let start = calendar.at(2026, 11, 2, 23, 50)
        let session = Session(startedAt: start, plannedDurationMinutes: 50)
        context.insert(session)
        ActivityEvent.add(to: context, .focus, from: start, seconds: 20 * 60, session: session)
        try context.save()
        let now = calendar.at(2026, 11, 3, 0, 10)

        let before = TodayModelBuilder.build(day: start, context: context, now: now, calendar: calendar)
        let after = TodayModelBuilder.build(day: now, context: context, now: now, calendar: calendar)
        XCTAssertEqual(before.focused, 10 * 60, accuracy: 0.1)
        XCTAssertEqual(after.focused, 10 * 60, accuracy: 0.1)
        XCTAssertEqual(after.focusedInSessions, 10 * 60, accuracy: 0.1)

        // A week's bars split it the same way.
        let report = ReportDataBuilder.build(period: .week, offset: 0, context: context, now: now, calendar: calendar)
        XCTAssertEqual(report.breakdown.focus, 20 * 60, accuracy: 0.1)
    }

    /// After midnight the session that's running stays on Today's list, in
    /// the window and the menu, and on the day it started.
    func testASessionStillRunningAfterMidnightStaysInTodaysList() throws {
        let calendar = Calendar.fixed("UTC")
        let container = try Rig.makeContainer()
        let context = container.mainContext
        let start = calendar.at(2026, 11, 2, 23, 50)
        let session = Session(startedAt: start, plannedDurationMinutes: 50)
        context.insert(session)
        ActivityEvent.add(to: context, .focus, from: start, seconds: 20 * 60, session: session)
        try context.save()

        let after = TodayModelBuilder.build(day: start.addingTimeInterval(20 * 60), context: context,
                                            now: start.addingTimeInterval(20 * 60), calendar: calendar)
        XCTAssertEqual(after.focusedInSessions, 10 * 60, accuracy: 0.1)
        XCTAssertEqual(after.sessions.map(\.id), [session.id])
        let menu = MenuInsightsBuilder.day(start.addingTimeInterval(20 * 60), context: context,
                                           now: start.addingTimeInterval(20 * 60), calendar: calendar, prior: [])
        XCTAssertEqual(menu.sessions.map(\.id), [session.id])
        XCTAssertEqual(menu.sessionSpans.first?.start, calendar.at(2026, 11, 3), "its stretch starts at midnight here")
        let before = TodayModelBuilder.build(day: start, context: context, now: start.addingTimeInterval(20 * 60), calendar: calendar)
        XCTAssertEqual(before.sessions.map(\.id), [session.id])

        // A later day has nothing to do with it once it's over.
        session.endedAt = start.addingTimeInterval(20 * 60)
        try context.save()
        let next = calendar.at(2026, 11, 4, 12)
        XCTAssertTrue(TodayModelBuilder.build(day: next, context: context, now: next, calendar: calendar).sessions.isEmpty)
        let afterEnd = TodayModelBuilder.build(day: start.addingTimeInterval(20 * 60), context: context, now: next, calendar: calendar)
        XCTAssertEqual(afterEnd.sessions.map(\.id), [session.id], "it ran into that day")
    }

    // MARK: - Limits at 00:00

    private func limitsEngine(_ context: ModelContext, overlay: StubOverlay, notifier: Notifier,
                              calendar: Calendar, policy: OverridePolicy = .standard, now: Date) -> DailyLimitsEngine {
        DailyLimitsEngine(context: context, notifier: notifier, overlay: overlay, policy: { policy },
                          calendar: calendar, now: now)
    }

    private func snapshot(_ url: String, at date: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: "com.apple.Safari", appName: "Safari", windowTitle: nil, url: url,
                         classification: .distraction, observedAt: date)
    }

    func testMidnightOnABlockedSiteLiftsTheBlockAndTheExtraTimeStartsOver() throws {
        let calendar = Calendar.fixed("UTC")
        let container = try Rig.makeContainer()
        let overlay = StubOverlay()
        let site = "https://youtube.com/watch"
        let late = calendar.at(2026, 11, 2, 23, 50)
        let engine = limitsEngine(container.mainContext, overlay: overlay, notifier: Notifier(), calendar: calendar, now: late)
        let limit = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 5, now: late))

        for second in 0...300 {
            let tick = late.addingTimeInterval(TimeInterval(second))
            engine.observe(snapshot: snapshot(site, at: tick), counting: true, now: tick)
        }
        XCTAssertEqual(overlay.current.map { if case .dailyLimit = $0.reason { true } else { false } }, true)
        XCTAssertTrue(engine.takeExtraTime(for: limit.id))
        XCTAssertEqual(engine.status(for: limit.id)?.extraLeft, 0)
        overlay.dismiss()

        // 00:00, still on the site.
        let midnight = calendar.at(2026, 11, 3, 0, 0, 1)
        engine.observe(snapshot: snapshot(site, at: midnight), counting: true, now: midnight)
        let status = try XCTUnwrap(engine.status(for: limit.id))
        XCTAssertEqual(status.used, 0, accuracy: 1, "usage starts over")
        XCTAssertEqual(status.extraMinutes, 0, "yesterday's extra time is gone")
        XCTAssertEqual(status.extraLeft, 1, "and today's is back")
        XCTAssertFalse(overlay.isPresenting)
    }

    func testAStrictChangeWaitingForTomorrowAppliesAtMidnightWithTheAppRunning() throws {
        let calendar = Calendar.fixed("UTC")
        let container = try Rig.makeContainer()
        let overlay = StubOverlay()
        let late = calendar.at(2026, 11, 2, 23, 59)
        let engine = limitsEngine(container.mainContext, overlay: overlay, notifier: Notifier(), calendar: calendar,
                                  policy: .strict, now: late)
        let limit = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 30, now: late))
        let gone = try XCTUnwrap(engine.addLimit(target: "reddit.com", isSite: true, minutes: 30, now: late))
        XCTAssertEqual(engine.setMinutes(10, for: limit.id), .fromTomorrow)
        XCTAssertEqual(engine.removeLimit(gone.id), .fromTomorrow)
        XCTAssertEqual(engine.status(for: limit.id)?.minutes, 30, "unchanged today")
        XCTAssertNotNil(engine.status(for: gone.id), "still there today")
        XCTAssertFalse(engine.takeExtraTime(for: limit.id), "Strict gives no extra time")

        let next = calendar.at(2026, 11, 3, 0, 0, 1)
        engine.observe(snapshot: nil, counting: false, now: next)
        XCTAssertEqual(engine.status(for: limit.id)?.minutes, 10)
        XCTAssertNil(engine.status(for: limit.id)?.pending)
        XCTAssertNil(engine.statuses.first { $0.target == "reddit.com" }, "the removal took effect")
    }

    /// Clock changes: the day is 23 or 25 hours and a limit still resets at
    /// its midnight, not 24 hours after the last one.
    func testLimitsResetAtMidnightOnClockChangeDays() throws {
        let calendar = Calendar.fixed("Europe/Berlin")
        let container = try Rig.makeContainer()
        for (day, next) in [(calendar.at(2026, 3, 29, 23, 59, 30), calendar.at(2026, 3, 30, 0, 0, 1)),
                            (calendar.at(2026, 10, 25, 23, 59, 30), calendar.at(2026, 10, 26, 0, 0, 1))] {
            let overlay = StubOverlay()
            let engine = limitsEngine(container.mainContext, overlay: overlay, notifier: Notifier(), calendar: calendar, now: day)
            let limit = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 30, now: day))
            for second in 0..<20 {
                let tick = day.addingTimeInterval(TimeInterval(second))
                engine.observe(snapshot: snapshot("https://youtube.com/", at: tick), counting: true, now: tick)
            }
            XCTAssertGreaterThan(engine.status(for: limit.id)?.used ?? 0, 10)
            engine.observe(snapshot: snapshot("https://youtube.com/", at: next), counting: true, now: next)
            XCTAssertEqual(engine.status(for: limit.id)?.used ?? -1, 0, accuracy: 1, "reset at \(next)")
            XCTAssertNotNil(engine.removeLimit(limit.id))
        }
    }

    // MARK: - Clock changes in the numbers

    func testAClockChangeDayAddsUpByRealSeconds() throws {
        let calendar = Calendar.fixed("Europe/Berlin")
        let container = try Rig.makeContainer()
        let context = container.mainContext
        // 01:30 to 03:30 on the clock: one real hour in spring, three in autumn.
        let spring = calendar.at(2026, 3, 29, 1, 30)
        ActivityEvent.add(to: context, .focus, from: spring, seconds: 3600)
        let autumn = calendar.at(2026, 10, 25, 1, 30)
        ActivityEvent.add(to: context, .focus, from: autumn, seconds: 3 * 3600)
        try context.save()

        let springDay = TodayModelBuilder.build(day: spring, context: context, now: calendar.at(2026, 3, 29, 23), calendar: calendar)
        XCTAssertEqual(springDay.focused, 3600, accuracy: 0.1)
        let autumnDay = TodayModelBuilder.build(day: autumn, context: context, now: calendar.at(2026, 10, 25, 23), calendar: calendar)
        XCTAssertEqual(autumnDay.focused, 3 * 3600, accuracy: 0.1)

        for now in [calendar.at(2026, 3, 30, 12), calendar.at(2026, 10, 26, 12)] {
            let direct = ReportDataBuilder.build(period: .week, offset: 1, context: context, now: now, calendar: calendar)
            XCTAssertEqual(direct.buckets.count, 7)
            for bucket in direct.buckets {
                XCTAssertEqual(bucket.interval.start, calendar.startOfDay(for: bucket.interval.start))
            }
            let days = DaySummaries(context: context, now: now, calendar: calendar) {
                DaySummary.make(days: $0, context: context, calendar: calendar)
            }
            let summed = try XCTUnwrap(ReportDataBuilder.build(period: .week, offset: 1, days: days))
            XCTAssertEqual(summed.breakdown.focus, direct.breakdown.focus, accuracy: 0.1)
            for (one, other) in zip(summed.buckets, direct.buckets) {
                XCTAssertEqual(one.focus, other.focus, accuracy: 0.1)
            }
            for (one, other) in zip(summed.heat.joined(), direct.heat.joined()) {
                XCTAssertEqual(one, other, accuracy: 0.1)
            }
        }
    }

    /// In a zone whose clocks change at midnight (Havana, Beirut, Santiago…)
    /// that day has no 00:00. Stepping a day at a time from it must not land
    /// on 01:00 for every day after it.
    func testDaysStillStartAtMidnightAfterAClockChangeAtMidnight() throws {
        let calendar = Calendar.fixed("America/Havana")
        let container = try Rig.makeContainer()
        let context = container.mainContext
        let now = calendar.at(2026, 3, 20, 12)
        // 8 March: 00:00 becomes 01:00. Half an hour of focus at 00:30 the day after.
        let later = calendar.at(2026, 3, 10, 0, 30)
        ActivityEvent.add(to: context, .focus, from: later, seconds: 30 * 60)
        try context.save()

        let month = ReportPeriod.month.interval(offset: 0, now: now, calendar: calendar)
        let buckets = ReportDataBuilder.bucketIntervals(period: .month, interval: month, events: [], now: now, calendar: calendar)
        let days = DaySummaries(context: context, now: now, calendar: calendar) {
            DaySummary.make(days: $0, context: context, calendar: calendar)
        }
        let summed = try XCTUnwrap(ReportDataBuilder.build(period: .month, offset: 0, days: days))
        let marchTenth = calendar.startOfDay(for: later)

        XCTAssertTrue(buckets.allSatisfy { $0.interval.start == calendar.startOfDay(for: $0.interval.start) },
                      "\(buckets.first { $0.interval.start != calendar.startOfDay(for: $0.interval.start) }?.interval.start as Any)")
        XCTAssertEqual(summed.buckets.first { $0.interval.start == marchTenth }?.focus ?? 0, 30 * 60, accuracy: 2)
        XCTAssertEqual(summed.breakdown.focus, 30 * 60, accuracy: 2)

        // A limit's change for "tomorrow" means tomorrow's midnight, and a
        // walk back from a day after the change finds each day's start.
        var day = calendar.at(2026, 3, 12)
        var starts: [Date] = []
        for _ in 0..<6 {
            day = calendar.startOfDay(-1, from: day)
            starts.append(day)
        }
        XCTAssertEqual(starts, [calendar.at(2026, 3, 11), calendar.at(2026, 3, 10), calendar.at(2026, 3, 9),
                                calendar.at(2026, 3, 8, 1), calendar.at(2026, 3, 7), calendar.at(2026, 3, 6)])
        XCTAssertEqual(calendar.startOfDay(1, from: calendar.at(2026, 3, 8, 1)), calendar.at(2026, 3, 9))
    }

    // MARK: - Sleep and wake

    /// The tracker's every-second pace in a session, as `start()` sets it up.
    /// Its first look reads the real front app, into this in-memory store;
    /// tests look only at the apps they drive.
    private func startInSession(_ rig: Rig) {
        rig.tracker.needsSecondTicks = { true }
        rig.tracker.start()
        XCTAssertEqual(rig.tracker.cadence, .everySecond)
    }

    func testSleepAndLockEndTheEventInASession() throws {
        let rig = try Rig()
        startInSession(rig)
        defer { rig.tracker.stop() }
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let start = Date()
        rig.stay(on: Rig.editor, from: start, for: 11)
        rig.tracker.enterSuspension(at: start.addingTimeInterval(10))
        // Locked: the login window takes the front.
        rig.look(at: Rig.lockScreen, start.addingTimeInterval(11))
        rig.look(at: Rig.lockScreen, start.addingTimeInterval(3600))
        rig.tracker.leaveSuspension(frontmost: Rig.editor.bundleId)
        rig.look(at: Rig.editor, start.addingTimeInterval(3610))
        rig.look(at: Rig.editor, start.addingTimeInterval(3620))
        let events = rig.events().filter { $0.bundleIdentifier == Rig.editor.bundleId }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].endedAt, start.addingTimeInterval(10), "ended when it locked")
        XCTAssertEqual(events[1].startedAt, start.addingTimeInterval(3610), "starts over when it's back")
    }

    /// Screens off without a lock, in a session, with recent input (say the
    /// display-sleep shortcut): nothing's recorded until they're back.
    func testScreensOffInASessionRecordNothingUntilTheyreBack() throws {
        let rig = try Rig()
        startInSession(rig)
        defer { rig.tracker.stop() }
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let start = Date()
        rig.stay(on: Rig.editor, from: start, for: 11)
        rig.tracker.enterSuspension(at: start.addingTimeInterval(10))
        // Four dark minutes; under the five that mean "away".
        rig.idle = 60
        rig.stay(on: Rig.editor, from: start.addingTimeInterval(11), for: 240)
        let events = rig.events().filter { $0.bundleIdentifier == Rig.editor.bundleId }
        XCTAssertEqual(events.first?.endedAt, start.addingTimeInterval(10))
        XCTAssertEqual(events.count, 1, "\(events.map(\.duration))")
    }

    // MARK: - A Mac asleep through the session's end

    func testASessionTheMacSleptThroughEndsWhenItWasPlannedTo() throws {
        let rig = try Rig()
        rig.sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        let start = Date().addingTimeInterval(-8 * 3600)
        session.startedAt = start
        ActivityEvent.add(to: rig.context, .focus, from: start, seconds: 10 * 60, session: session)

        // The first tick after waking.
        XCTAssertTrue(rig.sessions.checkPlannedDuration())
        let end = try XCTUnwrap(session.endedAt)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(rig.sessions.runningSeconds(for: session, now: end), 25 * 60, accuracy: 5)
        XCTAssertEqual(end.timeIntervalSince(start), 25 * 60, accuracy: 5)
    }

    // MARK: - Relaunch

    func testRelaunchPicksTheLeftoverSessionBackUpAndTheNewEventsJoinIt() throws {
        let rig = try Rig()
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        let id = session.id
        let down = Date().addingTimeInterval(-5 * 60)
        session.startedAt = down.addingTimeInterval(-10 * 60)
        ActivityEvent.add(to: rig.context, .focus, from: session.startedAt, seconds: 10 * 60, session: session)
        try rig.save()

        // The app comes back five minutes later, on the same store.
        let tracker = ActivityTracker(context: rig.context, optOutCache: TitleOptOutCache(context: rig.context), classifier: rig.classifier)
        tracker.secondsSinceInput = { 0 }
        tracker.readWindowTitle = { _ in nil }
        let manager = SessionManager(context: rig.context, tracker: tracker)
        let resumed = try XCTUnwrap(manager.currentSession)
        XCTAssertEqual(resumed.id, id)
        XCTAssertEqual(resumed.pausedSeconds, 5 * 60, accuracy: 2, "the downtime counts as paused")
        XCTAssertEqual(manager.runningSeconds(for: resumed), 10 * 60, accuracy: 2)
        tracker.record(Rig.editor, now: Date())
        XCTAssertTrue(rig.events().last?.session === resumed, "what's tracked next belongs to it")
    }

    func testRelaunchAfterALongTimeEndsTheSessionWhereItsActivityEnded() throws {
        let rig = try Rig()
        rig.sessions.startSession()
        let session = try XCTUnwrap(rig.sessions.currentSession)
        session.startedAt = Date().addingTimeInterval(-5 * 3600)
        ActivityEvent.add(to: rig.context, .focus, from: session.startedAt, seconds: 30 * 60, session: session)
        try rig.save()

        let tracker = ActivityTracker(context: rig.context, optOutCache: TitleOptOutCache(context: rig.context), classifier: rig.classifier)
        let manager = SessionManager(context: rig.context, tracker: tracker)
        XCTAssertNil(manager.currentSession)
        XCTAssertEqual(session.status, .abandoned)
        XCTAssertEqual(session.endedAt, session.startedAt.addingTimeInterval(30 * 60))
        XCTAssertNotNil(session.autoName, "it still gets a name")
    }
}
