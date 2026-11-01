import AppKit
import SwiftData
import XCTest
@testable import FocusGuard

/// Doing the same work less often: what the energy report measures, when
/// the tracker and the clocks wake, and that the numbers come out the same.
@MainActor
final class EnergyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - The diagnostics report's numbers

    func testPerHourMaths() {
        XCTAssertEqual(EnergyUsage.perHour(900, over: 1800), 1800)
        XCTAssertEqual(EnergyUsage.perHour(3, over: 3600), 3)
        XCTAssertNil(EnergyUsage.perHour(10, over: 59), "under a minute is too short to say")

        let usage = EnergyUsage(cpuSeconds: 45, idleWakeups: 120, interruptWakeups: 36_000, awakeSeconds: 7200)
        XCTAssertEqual(usage.cpuSecondsPerHour, 22.5)
        XCTAssertEqual(usage.idleWakeupsPerHour, 60)
        XCTAssertEqual(usage.interruptWakeupsPerHour, 18_000)
        XCTAssertEqual(usage.rows.map(\.0), ["Awake since launch", "CPU", "Idle wakeups", "Interrupt wakeups"])
        XCTAssertEqual(usage.rows.map(\.1), ["2.0 h", "22.5 s per hour (45 s in all)", "60 per hour (120 in all)",
                                             "18000 per hour (36000 in all)"])

        let early = EnergyUsage(cpuSeconds: 1, idleWakeups: 0, interruptWakeups: 5, awakeSeconds: 30)
        XCTAssertEqual(early.rows[1].1, "too early to tell (1 s in all)")
    }

    func testReadsThisProcessFromTheKernel() throws {
        let usage = try XCTUnwrap(EnergyUsage.sinceLaunch())
        XCTAssertGreaterThan(usage.cpuSeconds, 0)
        XCTAssertGreaterThan(usage.awakeSeconds, 0)
        XCTAssertLessThan(usage.cpuSeconds, usage.awakeSeconds * Double(ProcessInfo.processInfo.activeProcessorCount) + 1)

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let oneSecond = UInt64(1_000_000_000) * UInt64(timebase.denom) / UInt64(timebase.numer)
        XCTAssertEqual(EnergyUsage.seconds(machTime: oneSecond), 1, accuracy: 1e-6)
    }

    // MARK: - The tracker's pace

    func testPaceFollowsWhatNeedsIt() {
        XCTAssertEqual(TrackingCadence.choose(secondTicks: true, suspended: true, polling: false), .everySecond)
        XCTAssertEqual(TrackingCadence.choose(secondTicks: false, suspended: true, polling: true), .suspended)
        XCTAssertEqual(TrackingCadence.choose(secondTicks: false, suspended: false, polling: true), .polling)
        XCTAssertEqual(TrackingCadence.choose(secondTicks: false, suspended: false, polling: false), .resting)

        let paces: [TrackingCadence] = [.everySecond, .polling, .resting, .suspended]
        XCTAssertEqual(paces.map(\.interval), paces.map(\.interval).sorted())
        XCTAssertTrue(paces.allSatisfy { $0.tolerance > 0 && $0.tolerance < $0.interval })
        // Daily limits count the gap between ticks, up to a limit.
        XCTAssertLessThan(TrackingCadence.everySecond.interval + TrackingCadence.everySecond.tolerance,
                          DailyLimitsEngine.maxTickGap)
        // Outside sessions, a tick still comes well inside the auto-start
        // offer's sleep check.
        XCTAssertLessThan(TrackingCadence.resting.interval, AutoStartDetector.maxTickGap)
    }

    func testEverySecondOnlyWhenSomethingIsTimedOrOnScreen() {
        XCTAssertFalse(TrackingCadence.needsSecondTicks(inSession: false, onBreak: false, limitInFront: false, onScreen: false))
        XCTAssertTrue(TrackingCadence.needsSecondTicks(inSession: true, onBreak: false, limitInFront: false, onScreen: false))
        XCTAssertTrue(TrackingCadence.needsSecondTicks(inSession: false, onBreak: true, limitInFront: false, onScreen: false))
        XCTAssertTrue(TrackingCadence.needsSecondTicks(inSession: false, onBreak: false, limitInFront: true, onScreen: false))
        XCTAssertTrue(TrackingCadence.needsSecondTicks(inSession: false, onBreak: false, limitInFront: false, onScreen: true))
    }

    func testPollsOnlyWhatNothingAnnounces() {
        // No titles to read (no Screen Recording, or opted out): events cover it.
        XCTAssertFalse(TrackingCadence.needsPolling(away: false, browserWithoutExtension: false,
                                                    titlesReadable: false, titleChangesAnnounced: false))
        // Accessibility announces title changes.
        XCTAssertFalse(TrackingCadence.needsPolling(away: false, browserWithoutExtension: false,
                                                    titlesReadable: true, titleChangesAnnounced: true))
        XCTAssertTrue(TrackingCadence.needsPolling(away: false, browserWithoutExtension: false,
                                                   titlesReadable: true, titleChangesAnnounced: false))
        // A browser's address over AppleScript, or waiting for someone to come back.
        XCTAssertTrue(TrackingCadence.needsPolling(away: false, browserWithoutExtension: true,
                                                   titlesReadable: false, titleChangesAnnounced: true))
        XCTAssertTrue(TrackingCadence.needsPolling(away: true, browserWithoutExtension: false,
                                                   titlesReadable: false, titleChangesAnnounced: true))
    }

    // MARK: - Durations come from when things happened

    private let xcode = FrontmostApp(bundleId: "com.apple.dt.Xcode", name: "Xcode", pid: 999_991)
    private let notes = FrontmostApp(bundleId: "com.apple.Notes", name: "Notes", pid: 999_992)

    private final class Inputs {
        var idle: TimeInterval = 0
        var title: String?
    }

    private func makeTracker(_ inputs: Inputs) throws -> (ActivityTracker, ModelContext, ModelContainer) {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context),
                                      classifier: Classifier(context: context))
        tracker.readWindowTitle = { _ in inputs.title }
        tracker.secondsSinceInput = { inputs.idle }
        tracker.displayKeptAwake = { false }
        return (tracker, context, container)
    }

    private func spans(_ context: ModelContext) -> [(String, TimeInterval, TimeInterval)] {
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.startedAt)]))
        return events.map { ($0.windowTitle ?? $0.appName, $0.startedAt.timeIntervalSince(t0), $0.endedAt.timeIntervalSince(t0)) }
    }

    private func assertSpans(_ context: ModelContext, _ expected: [(String, TimeInterval, TimeInterval)],
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = spans(context)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
        XCTAssertEqual(actual.map(\.2), expected.map(\.2), file: file, line: line)
    }

    func testASwitchEndsTheEventWhenItHappensNotAtTheLastTick() throws {
        let inputs = Inputs()
        let (tracker, context, container) = try makeTracker(inputs)
        _ = container
        tracker.record(xcode, now: t0)
        tracker.record(xcode, now: t0.addingTimeInterval(10))   // the last timer tick
        tracker.record(notes, now: t0.addingTimeInterval(17))   // the switch, between ticks
        tracker.flush(now: t0.addingTimeInterval(30))           // quitting
        assertSpans(context, [("Xcode", 0, 17), ("Notes", 17, 30)])
    }

    func testATitleChangeSplitsWhereItWasSeen() throws {
        let inputs = Inputs()
        let (tracker, context, container) = try makeTracker(inputs)
        _ = container
        inputs.title = "Plan.md"
        tracker.record(xcode, now: t0)
        inputs.title = "Notes.md"
        tracker.record(xcode, now: t0.addingTimeInterval(3))
        tracker.flush(now: t0.addingTimeInterval(9))
        assertSpans(context, [("Plan.md", 0, 3), ("Notes.md", 3, 9)])
    }

    func testAwayEndsTheEventAtTheLastInputEvenWithLooksFarApart() throws {
        let inputs = Inputs()
        let (tracker, context, container) = try makeTracker(inputs)
        _ = container
        tracker.record(xcode, now: t0)
        // The next look comes 400 s later; the last input was at 60 s.
        inputs.idle = 340
        tracker.record(xcode, now: t0.addingTimeInterval(400))
        XCTAssertTrue(tracker.isAway)
        XCTAssertEqual(tracker.lastActiveAt, t0.addingTimeInterval(60))
        // Back.
        inputs.idle = 0
        tracker.record(xcode, now: t0.addingTimeInterval(500))
        XCTAssertFalse(tracker.isAway)
        tracker.flush(now: t0.addingTimeInterval(510))
        assertSpans(context, [("Xcode", 0, 60), ("Xcode", 500, 510)])
    }

    func testFocusGuardInFrontEndsTheEventThen() throws {
        let inputs = Inputs()
        let (tracker, context, container) = try makeTracker(inputs)
        _ = container
        tracker.record(xcode, now: t0)
        tracker.record(FrontmostApp(bundleId: ActivityTracker.selfBundleId, name: "FocusGuard", pid: 999_993),
                       now: t0.addingTimeInterval(8))
        XCTAssertTrue(tracker.isFrontmostSelf)
        tracker.flush(now: t0.addingTimeInterval(20))
        assertSpans(context, [("Xcode", 0, 8)])
    }

    func testSleepEndsTheEventAndWakingDoesntStretchIt() throws {
        let inputs = Inputs()
        let (tracker, context, container) = try makeTracker(inputs)
        _ = container
        tracker.record(xcode, now: t0)
        tracker.record(xcode, now: t0.addingTimeInterval(20))
        tracker.enterSuspension(at: t0.addingTimeInterval(20))
        // A safety tick while asleep records nothing.
        tracker.record(xcode, now: t0.addingTimeInterval(3600))
        XCTAssertTrue(tracker.isAway)
        // The lock screen isn't someone back at work.
        tracker.leaveSuspension(frontmost: "com.apple.loginwindow")
        XCTAssertTrue(tracker.isSuspended)
        tracker.leaveSuspension(frontmost: xcode.bundleId)
        XCTAssertFalse(tracker.isSuspended)
        tracker.record(xcode, now: t0.addingTimeInterval(7200))
        tracker.flush(now: t0.addingTimeInterval(7210))
        assertSpans(context, [("Xcode", 0, 20), ("Xcode", 7200, 7210)])
    }

    private final class Flag: @unchecked Sendable { var raised = false }

    func testSnapshotChangesOnlyWithTheActivityNotTheClock() throws {
        let inputs = Inputs()
        let (tracker, _, container) = try makeTracker(inputs)
        _ = container
        tracker.record(xcode, now: t0)
        let changed = Flag()
        withObservationTracking { _ = tracker.currentSnapshot } onChange: { changed.raised = true }
        tracker.record(xcode, now: t0.addingTimeInterval(1))
        tracker.record(xcode, now: t0.addingTimeInterval(2))
        XCTAssertFalse(changed.raised, "a tick that changed nothing wakes nobody")
        XCTAssertEqual(tracker.currentSnapshot?.observedAt, t0)
        XCTAssertEqual(tracker.currentSnapshot?.observed(at: t0.addingTimeInterval(2)).observedAt, t0.addingTimeInterval(2))
        tracker.record(notes, now: t0.addingTimeInterval(3))
        XCTAssertTrue(changed.raised)
        XCTAssertEqual(tracker.currentSnapshot?.appName, "Notes")
    }

    // MARK: - Clocks wake at the next change, not every second

    func testNextMinuteBoundary() {
        XCTAssertEqual(MinuteClock.untilNextMinute(elapsed: 119.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MinuteClock.untilNextMinute(elapsed: 120), 60)
        XCTAssertEqual(MinuteClock.untilNextMinute(elapsed: 0), 60)
        XCTAssertEqual(MinuteClock.untilMinuteDrops(remaining: 299.5) ?? -1, 59.5, accuracy: 1e-9)
        XCTAssertEqual(MinuteClock.untilMinuteDrops(remaining: 240), 60)
        XCTAssertEqual(MinuteClock.untilMinuteDrops(remaining: 0.5) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(MinuteClock.untilMinuteDrops(remaining: 0))
        XCTAssertEqual(MinuteClock.untilSecondDrops(remaining: 112.25) ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(MinuteClock.untilSecondDrops(remaining: 112), 1)
        XCTAssertNil(MinuteClock.untilSecondDrops(remaining: 0))
    }

    func testTheLabelChangesRightAtTheWakeUp() {
        // "24m so far" and "26m left" turn exactly when the wait is up, not before.
        for elapsed in [0, 0.3, 59.99, 61, 119.5, 1499.25] {
            let wait = MinuteClock.untilNextMinute(elapsed: elapsed)
            XCTAssertEqual(Int((elapsed + wait) / 60), Int(elapsed / 60) + 1, "\(elapsed)")
            XCTAssertEqual(Int((elapsed + wait - 0.01) / 60), Int(elapsed / 60), "\(elapsed)")
            let left = 1500 - elapsed
            XCTAssertEqual(AppState.minutesRoundedUp(left - wait), AppState.minutesRoundedUp(left) - 1, "\(elapsed)")
            XCTAssertEqual(AppState.minutesRoundedUp(left - wait + 0.01), AppState.minutesRoundedUp(left), "\(elapsed)")
        }
        for remaining in [299.5, 240, 61, 0.5] {
            let wait = MinuteClock.untilMinuteDrops(remaining: remaining) ?? -1
            XCTAssertEqual(AppState.minutesRoundedUp(remaining - wait), AppState.minutesRoundedUp(remaining) - 1, "\(remaining)")
            XCTAssertEqual(AppState.minutesRoundedUp(remaining - wait + 0.01), AppState.minutesRoundedUp(remaining), "\(remaining)")
        }
    }

    func testTheShieldFillsAStepRightAtTheWakeUp() throws {
        let planned: TimeInterval = 3000
        let wait = try XCTUnwrap(StatusItemSchedule.untilNextFillStep(elapsed: 1500, planned: planned))
        XCTAssertEqual(StatusGlyphState.focusing(elapsed: 1500 + wait + 0.001, planned: planned), .focusing(progress: 14.0 / 26))
        XCTAssertEqual(StatusGlyphState.focusing(elapsed: 1500 + wait - 0.01, planned: planned), .focusing(progress: 0.5))
        XCTAssertNil(StatusItemSchedule.untilNextFillStep(elapsed: planned, planned: planned))
    }

    func testStatusItemWakesOnlyForTheSoonestChange() throws {
        let slack = StatusItemSchedule.slack
        // Ready, or a paused session: nothing changes by itself, so no timer at all.
        XCTAssertNil(StatusItemSchedule.delay(.init()))
        // A 25-minute session 30 s in: the shield's first step (57.7 s) comes before the minute.
        let session = try XCTUnwrap(StatusItemSchedule.delay(.init(elapsed: 30, planned: 1500)))
        XCTAssertEqual(session, 1500.0 / 26 - 30 + slack, accuracy: 1e-9)
        // Open-ended: the next minute.
        XCTAssertEqual(StatusItemSchedule.delay(.init(elapsed: 30)) ?? -1, 30 + slack, accuracy: 1e-9)
        // A drift about to show, a pass's next second.
        XCTAssertEqual(StatusItemSchedule.delay(.init(elapsed: 30, driftShowsIn: 4)) ?? -1, 4 + slack, accuracy: 1e-9)
        XCTAssertEqual(StatusItemSchedule.delay(.init(elapsed: 30, passRemaining: 112.25)) ?? -1, 0.25 + slack, accuracy: 1e-9)
        // A drift already showing doesn't count.
        XCTAssertEqual(StatusItemSchedule.delay(.init(elapsed: 30, driftShowsIn: -3)) ?? -1, 30 + slack, accuracy: 1e-9)
        // A break's next minute; the recap giving way to ready.
        XCTAssertEqual(StatusItemSchedule.delay(.init(breakRemaining: 299.5)) ?? -1, 59.5 + slack, accuracy: 1e-9)
        XCTAssertEqual(StatusItemSchedule.delay(.init(recapEndsIn: 600)) ?? -1, 600 + slack, accuracy: 1e-9)
    }

    func testWidgetsWakeForTheControlsMinuteTodaysNumbersOrMidnight() {
        let slack = StatusItemSchedule.slack
        XCTAssertEqual(SurfacesCoordinator.nextCheck(minuteChangesIn: 12, sinceWrite: 10, untilMidnight: 5000), 12 + slack)
        XCTAssertEqual(SurfacesCoordinator.nextCheck(minuteChangesIn: nil, sinceWrite: 100, untilMidnight: 5000), 200 + slack)
        XCTAssertEqual(SurfacesCoordinator.nextCheck(minuteChangesIn: nil, sinceWrite: 100, untilMidnight: 30), 30 + slack)
        XCTAssertEqual(SurfacesCoordinator.nextCheck(minuteChangesIn: nil, sinceWrite: 400, untilMidnight: 5000), slack)
    }

    func testCalendarLooksJustAfterTheNextStartOrEnd() {
        let next = CalendarAutostartCoordinator.nextCheck
        XCTAssertEqual(next(t0, [t0.addingTimeInterval(600), t0.addingTimeInterval(-60)], [t0.addingTimeInterval(3600)], 900), 601)
        // An event under way: just after it ends.
        XCTAssertEqual(next(t0, [t0.addingTimeInterval(-600)], [t0.addingTimeInterval(120)], 900), 121)
        // Nothing soon: the safety look.
        XCTAssertEqual(next(t0, [t0.addingTimeInterval(7200)], [t0.addingTimeInterval(9000)], 900), 900)
        XCTAssertEqual(next(t0, [], [], 900), 900)
    }

    func testCoachWakesWhenSomethingComesDue() {
        XCTAssertEqual(WeeklyCoach.nextRefresh(now: t0, due: [t0.addingTimeInterval(100), t0.addingTimeInterval(-5)]), 101)
        XCTAssertEqual(WeeklyCoach.nextRefresh(now: t0, due: []), WeeklyCoach.maxWait)
        XCTAssertEqual(WeeklyCoach.nextRefresh(now: t0, due: [t0.addingTimeInterval(86_400)]), WeeklyCoach.maxWait)
    }

    // MARK: - Nothing ticks while nothing's on screen

    func testWindowCountsAsOnScreenOnlyWhenItCanBeSeen() {
        XCTAssertTrue(OnScreen.isVisible(orderedIn: true, miniaturized: false, occlusion: .visible))
        XCTAssertFalse(OnScreen.isVisible(orderedIn: true, miniaturized: false, occlusion: []), "covered")
        XCTAssertFalse(OnScreen.isVisible(orderedIn: true, miniaturized: true, occlusion: .visible), "minimised")
        XCTAssertFalse(OnScreen.isVisible(orderedIn: false, miniaturized: false, occlusion: .visible), "closed")

        let onScreen = OnScreen()
        XCTAssertFalse(onScreen.any)
        onScreen.setMenu(true, now: t0)
        XCTAssertTrue(onScreen.any)
        XCTAssertEqual(onScreen.menuShownAt, t0)
        // Staying open isn't opening again: the clock floor stays.
        onScreen.setMenu(true, now: t0.addingTimeInterval(5))
        XCTAssertEqual(onScreen.menuShownAt, t0)
        onScreen.setMenu(false)
        XCTAssertFalse(onScreen.any)
        onScreen.setWindow(true, now: t0.addingTimeInterval(9))
        XCTAssertTrue(onScreen.any)
        XCTAssertEqual(onScreen.windowShownAt, t0.addingTimeInterval(9))
    }
}
