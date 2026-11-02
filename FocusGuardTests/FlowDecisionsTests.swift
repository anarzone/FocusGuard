import SwiftData
import XCTest
@testable import FocusGuard

/// The owner's three decisions: a long sleep ends a paused session, Free keeps
/// one limit active, and Strict's "for tomorrow" can't be got round.
@MainActor
final class FlowDecisionsTests: XCTestCase {
    private typealias Rig = FlowRig
    private typealias StubOverlay = EscalationEngineTests.StubOverlay
    private typealias Notifier = DailyLimitsEngineTests.RecordingNotifier

    private let calendar = Calendar.fixed("UTC")
    private var policy = OverridePolicy.strict
    private var morning: Date { calendar.at(2026, 11, 2, 9) }

    private func engine(_ context: ModelContext, overlay: StubOverlay? = nil, now: Date? = nil) -> DailyLimitsEngine {
        DailyLimitsEngine(context: context, notifier: Notifier(), overlay: overlay ?? StubOverlay(), policy: { [unowned self] in self.policy },
                          calendar: calendar, now: now ?? morning)
    }

    // MARK: - Strict's "tomorrow only"

    func testLeavingStrictDoesntOpenUpTodaysLimit() throws {
        let container = try Rig.makeContainer()
        policy = .strict
        let limits = engine(container.mainContext)
        let limit = try XCTUnwrap(limits.addLimit(target: "youtube.com", isSite: true, minutes: 30, now: morning))
        XCTAssertEqual(limits.setMinutes(120, for: limit.id), .fromTomorrow, "Strict's own rule")

        // Out of a session the preset can be switched.
        policy = .gentle
        XCTAssertEqual(limits.setMinutes(240, for: limit.id), .fromTomorrow, "still only for tomorrow")
        XCTAssertEqual(limits.status(for: limit.id)?.minutes, 30, "today's limit stands")
        XCTAssertEqual(limits.status(for: limit.id)?.pending, .minutes(240))
        XCTAssertFalse(limits.takeExtraTime(for: limit.id), "and no extra time today")
        XCTAssertEqual(limits.status(for: limit.id)?.extraLeft, 0)
        XCTAssertEqual(limits.removeLimit(limit.id), .fromTomorrow, "nor removed today")
        XCTAssertNotNil(limits.status(for: limit.id))
        XCTAssertEqual(limits.status(for: limit.id)?.changesWaitForTomorrow, true)
        XCTAssertEqual(limits.policy(for: try XCTUnwrap(limits.status(for: limit.id))), .strict)
    }

    func testStrictForAMomentCountsForTheDayEvenAcrossARelaunch() throws {
        let container = try Rig.makeContainer()
        policy = .gentle
        let limits = engine(container.mainContext)
        let limit = try XCTUnwrap(limits.addLimit(target: "youtube.com", isSite: true, minutes: 30, now: morning))
        XCTAssertEqual(limits.setMinutes(60, for: limit.id), .now, "no Strict today yet")

        policy = .strict
        limits.observe(snapshot: nil, counting: false, now: morning.addingTimeInterval(60))
        policy = .gentle
        limits.observe(snapshot: nil, counting: false, now: morning.addingTimeInterval(120))
        XCTAssertEqual(limits.setMinutes(120, for: limit.id), .fromTomorrow)

        let again = engine(container.mainContext, now: morning.addingTimeInterval(180))
        XCTAssertEqual(again.setMinutes(90, for: limit.id), .fromTomorrow, "a relaunch doesn't open it up")
        XCTAssertFalse(again.takeExtraTime(for: limit.id))
    }

    func testTheNextDayGoesByThePresetOnThen() throws {
        let container = try Rig.makeContainer()
        policy = .strict
        let limits = engine(container.mainContext)
        let limit = try XCTUnwrap(limits.addLimit(target: "youtube.com", isSite: true, minutes: 30, now: morning))
        XCTAssertEqual(limits.setMinutes(60, for: limit.id), .fromTomorrow)
        policy = .gentle
        XCTAssertEqual(limits.status(for: limit.id)?.minutes, 30)

        // What was saved for tomorrow is what tomorrow gets.
        let tomorrow = calendar.at(2026, 11, 3, 0, 0, 1)
        limits.observe(snapshot: nil, counting: false, now: tomorrow)
        let status = try XCTUnwrap(limits.status(for: limit.id))
        XCTAssertEqual(status.minutes, 60)
        XCTAssertNil(status.pending)
        XCTAssertFalse(status.changesWaitForTomorrow)
        XCTAssertEqual(status.extraLeft, 3, "Gentle's extra time, from today")
        XCTAssertEqual(limits.setMinutes(45, for: limit.id), .now)
        XCTAssertTrue(limits.takeExtraTime(for: limit.id))
    }

    /// A stay on Strict across midnight counts for the new day too.
    func testStrictOnAtMidnightHoldsTheNewDay() throws {
        let container = try Rig.makeContainer()
        policy = .strict
        let limits = engine(container.mainContext)
        let limit = try XCTUnwrap(limits.addLimit(target: "youtube.com", isSite: true, minutes: 30, now: morning))
        limits.observe(snapshot: nil, counting: false, now: calendar.at(2026, 11, 3, 0, 0, 1))
        policy = .standard
        XCTAssertEqual(limits.setMinutes(60, for: limit.id), .fromTomorrow)
    }

    // MARK: - Limits on Free

    private func snapshot(_ host: String, at date: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: "com.apple.Safari", appName: "Safari", windowTitle: nil, url: "https://\(host)/",
                         classification: .neutral, observedAt: date)
    }

    private final class Cap { var value: Int? = 1 }

    /// Three limits, oldest first; `cap` says how many the plan keeps.
    private func threeLimits(_ context: ModelContext, cap: Cap, overlay: StubOverlay) -> DailyLimitsEngine {
        policy = .standard
        let limits = DailyLimitsEngine(context: context, notifier: Notifier(), overlay: overlay, policy: { [unowned self] in self.policy },
                                       activeCap: { cap.value }, calendar: calendar, now: morning)
        for (index, host) in ["first.example", "second.example", "third.example"].enumerated() {
            _ = limits.addLimit(target: host, isSite: true, minutes: 5, now: morning.addingTimeInterval(TimeInterval(index)))
        }
        return limits
    }

    func testFreeKeepsTheOldestInForceAndPausesTheRest() throws {
        let container = try Rig.makeContainer()
        let overlay = StubOverlay()
        let limits = threeLimits(container.mainContext, cap: Cap(), overlay: overlay)
        XCTAssertEqual(limits.statuses.map(\.isPaused), [false, true, true])
        XCTAssertEqual(limits.activeStatuses.map(\.target), ["first.example"])
        XCTAssertEqual(limits.statuses.count, 3, "paused, not deleted")

        // A paused limit counts nothing, blocks nothing, and isn't "on" this site.
        var tick = morning
        for _ in 0...400 {
            limits.observe(snapshot: snapshot("second.example", at: tick), counting: true, now: tick)
            tick = tick.addingTimeInterval(1)
        }
        let second = try XCTUnwrap(limits.statuses.first { $0.target == "second.example" })
        XCTAssertEqual(second.used, 0)
        XCTAssertFalse(overlay.isPresenting)
        XCTAssertNil(limits.status(for: snapshot("second.example", at: tick)), "so it doesn't speed the tracker up either")
        XCTAssertFalse(limits.takeExtraTime(for: second.id))

        // The one in force does.
        for _ in 0...301 {
            limits.observe(snapshot: snapshot("first.example", at: tick), counting: true, now: tick)
            tick = tick.addingTimeInterval(1)
        }
        XCTAssertTrue(overlay.isPresenting)
    }

    func testDeletingTheOneInForcePutsTheNextOldestInItsPlace() throws {
        let container = try Rig.makeContainer()
        let context = container.mainContext
        // Time already spent today on the one coming into force counts.
        ActivityEvent.add(to: context, .neutral, from: morning.addingTimeInterval(-3600), seconds: 120, app: Rig.safari,
                          url: "https://second.example/")
        try context.save()
        let limits = threeLimits(context, cap: Cap(), overlay: StubOverlay())
        let first = try XCTUnwrap(limits.statuses.first)
        XCTAssertEqual(limits.removeLimit(first.id), .now)
        XCTAssertEqual(limits.statuses.map(\.target), ["second.example", "third.example"])
        XCTAssertEqual(limits.statuses.map(\.isPaused), [false, true])
        XCTAssertEqual(limits.statuses.first?.used ?? 0, 120, accuracy: 1)
    }

    func testUpgradingBringsThemBackAndTheTrialEndingPausesThemAgain() throws {
        let container = try Rig.makeContainer()
        let context = container.mainContext
        let cap = Cap()
        let overlay = StubOverlay()
        ActivityEvent.add(to: context, .neutral, from: morning.addingTimeInterval(-3600), seconds: 400, app: Rig.safari,
                          url: "https://third.example/")
        try context.save()
        let limits = threeLimits(context, cap: cap, overlay: overlay)

        cap.value = nil
        limits.planChanged(now: morning)
        XCTAssertEqual(limits.statuses.map(\.isPaused), [false, false, false])
        XCTAssertEqual(limits.activeStatuses.count, 3)
        let third = try XCTUnwrap(limits.statuses.last)
        XCTAssertEqual(third.used, 400, accuracy: 1, "today's time on it was recorded all along")

        // Used up, so it blocks; then the trial ends and it's off.
        limits.observe(snapshot: snapshot("third.example", at: morning), counting: true, now: morning)
        XCTAssertEqual(overlay.current.map { if case .dailyLimit = $0.reason { true } else { false } }, true)
        cap.value = 1
        limits.planChanged(now: morning.addingTimeInterval(1))
        XCTAssertFalse(overlay.isPresenting, "a limit that's off doesn't hold the screen")
        XCTAssertEqual(limits.statuses.map(\.isPaused), [false, true, true])
    }

    // MARK: - A long sleep

    func testAPauseOverFifteenMinutesEndsTheSessionWhereItPaused() throws {
        let rig = try Rig()
        rig.sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        let start = Date().addingTimeInterval(-14 * 3600)
        session.startedAt = start
        session.pausedAt = start.addingTimeInterval(600)

        XCTAssertTrue(rig.sessions.endIfPausedTooLong())
        XCTAssertNil(rig.sessions.currentSession)
        XCTAssertEqual(session.status, .abandoned)
        XCTAssertEqual(session.endedAt, start.addingTimeInterval(600), "it ends at the pause")
        XCTAssertNil(session.pausedAt)
        XCTAssertEqual(rig.sessions.runningSeconds(for: session, now: start.addingTimeInterval(600)), 600, accuracy: 1)
        XCTAssertNotNil(session.autoName)
    }

    func testAShorterPauseIsLeftToResume() throws {
        let rig = try Rig()
        rig.sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        session.startedAt = Date().addingTimeInterval(-3600)
        session.pausedAt = Date().addingTimeInterval(-14 * 60)
        XCTAssertFalse(rig.sessions.endIfPausedTooLong())
        XCTAssertNotNil(rig.sessions.currentSession)
        XCTAssertNotNil(session.pausedAt)
    }
}
