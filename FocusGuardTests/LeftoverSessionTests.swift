import XCTest
import SwiftData
@testable import FocusGuard

/// A session still open at launch: the app quit (update relaunch, manual
/// quit, restart) in the middle of it.
@MainActor
final class LeftoverSessionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: - Decision

    func testRecentSessionResumesWithDowntimeCountedAsPaused() {
        // 25-minute session, quit at minute 10, back 3 minutes later.
        let outcome = SessionManager.leftoverOutcome(
            startedAt: t0, pausedAt: nil, pausedSeconds: 0, plannedMinutes: 25,
            lastSeenAt: at(10), now: at(13)
        )
        XCTAssertEqual(outcome, .resume(addPausedSeconds: 3 * 60))
    }

    func testOpenEndedRecentSessionResumes() {
        let outcome = SessionManager.leftoverOutcome(
            startedAt: t0, pausedAt: nil, pausedSeconds: 0, plannedMinutes: nil,
            lastSeenAt: at(90), now: at(90.5)
        )
        XCTAssertEqual(outcome, .resume(addPausedSeconds: 30))
    }

    func testStaleSessionIsAbandoned() {
        // Quit at minute 10 of an open-ended session, back an hour later.
        let outcome = SessionManager.leftoverOutcome(
            startedAt: t0, pausedAt: nil, pausedSeconds: 0, plannedMinutes: nil,
            lastSeenAt: at(10), now: at(70)
        )
        XCTAssertEqual(outcome, .abandon)

        // Same for a timed session whose planned end is far past the window.
        let timed = SessionManager.leftoverOutcome(
            startedAt: t0, pausedAt: nil, pausedSeconds: 0, plannedMinutes: 90,
            lastSeenAt: at(10), now: at(70)
        )
        XCTAssertEqual(timed, .abandon)
    }

    func testSessionWhosePlannedLengthRanOutWhileDownCompletesAtPlannedEnd() {
        // 25 minutes with 2 paused; quit at minute 22, back at minute 30.
        let outcome = SessionManager.leftoverOutcome(
            startedAt: t0, pausedAt: nil, pausedSeconds: 2 * 60, plannedMinutes: 25,
            lastSeenAt: at(22), now: at(30)
        )
        XCTAssertEqual(outcome, .complete(at: at(27)))

        // Back the next day: it still ran out within the window, so it completed.
        let nextDay = SessionManager.leftoverOutcome(
            startedAt: t0, pausedAt: nil, pausedSeconds: 0, plannedMinutes: 25,
            lastSeenAt: at(22), now: at(24 * 60)
        )
        XCTAssertEqual(nextDay, .complete(at: at(25)))
    }

    func testPausedSessionStaysPaused() {
        // Paused at minute 20 of 25, quit at 30, back at 35. The planned clock
        // doesn't run while paused, so it doesn't complete, and the open pause
        // already covers the downtime.
        let outcome = SessionManager.leftoverOutcome(
            startedAt: t0, pausedAt: at(20), pausedSeconds: 0, plannedMinutes: 25,
            lastSeenAt: at(30), now: at(35)
        )
        XCTAssertEqual(outcome, .resume(addPausedSeconds: 0))
    }

    // MARK: - Applied on launch

    private func makeStore() throws -> ModelContext {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        addTeardownBlock { _ = container }
        return container.mainContext
    }

    private func launch(_ context: ModelContext) -> (SessionManager, ActivityTracker) {
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: Classifier(context: context))
        return (SessionManager(context: context, tracker: tracker), tracker)
    }

    private func event(_ session: Session?, from: Date, to: Date, in context: ModelContext) {
        context.insert(ActivityEvent(startedAt: from, endedAt: to, bundleIdentifier: "com.apple.dt.Xcode",
                                     appName: "Xcode", session: session))
    }

    func testLaunchResumesRecentSessionAsCurrent() throws {
        let context = try makeStore()
        let now = Date()
        let session = Session(startedAt: now.addingTimeInterval(-12 * 60), plannedDurationMinutes: 25)
        context.insert(session)
        event(session, from: session.startedAt, to: now.addingTimeInterval(-2 * 60), in: context)
        try context.save()

        let (manager, tracker) = launch(context)

        XCTAssertEqual(manager.currentSession?.id, session.id)
        XCTAssertEqual(tracker.currentSession?.id, session.id)
        XCTAssertNil(session.endedAt)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.pausedSeconds, 2 * 60, accuracy: 2)
        // The ring picks up where it left off: 10 minutes in, not 12.
        XCTAssertEqual(manager.runningSeconds(for: session), 10 * 60, accuracy: 2)

        // An idle pause can't reach back into the downtime already counted.
        manager.pauseSession(at: now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(try XCTUnwrap(session.pausedAt).timeIntervalSince(now), 0, accuracy: 2)
    }

    func testLaunchKeepsPausedSessionPausedAndDetached() throws {
        let context = try makeStore()
        let now = Date()
        let pausedAt = now.addingTimeInterval(-20 * 60)
        let session = Session(startedAt: now.addingTimeInterval(-30 * 60), plannedDurationMinutes: 25)
        session.pausedAt = pausedAt
        context.insert(session)
        // Activity carried on outside the session until just before the quit.
        event(nil, from: pausedAt, to: now.addingTimeInterval(-1 * 60), in: context)
        try context.save()

        let (manager, tracker) = launch(context)

        XCTAssertEqual(manager.currentSession?.id, session.id)
        XCTAssertNil(tracker.currentSession)
        XCTAssertEqual(session.pausedAt, pausedAt)
        XCTAssertEqual(session.pausedSeconds, 0)
        XCTAssertEqual(manager.runningSeconds(for: session), 10 * 60, accuracy: 2)
    }

    func testLaunchAbandonsStaleSessionAtLastEvent() throws {
        let context = try makeStore()
        let now = Date()
        let session = Session(startedAt: now.addingTimeInterval(-3 * 3600))
        context.insert(session)
        let lastActivity = now.addingTimeInterval(-2 * 3600)
        event(session, from: session.startedAt, to: lastActivity, in: context)
        try context.save()

        let (manager, tracker) = launch(context)

        XCTAssertNil(manager.currentSession)
        XCTAssertNil(tracker.currentSession)
        XCTAssertEqual(session.status, .abandoned)
        XCTAssertEqual(session.endedAt, lastActivity)
    }

    func testLaunchCompletesOverrunSessionAtPlannedEnd() throws {
        let context = try makeStore()
        let now = Date()
        let session = Session(startedAt: now.addingTimeInterval(-30 * 60), plannedDurationMinutes: 25)
        context.insert(session)
        event(session, from: session.startedAt, to: now.addingTimeInterval(-8 * 60), in: context)
        try context.save()

        let (manager, _) = launch(context)

        XCTAssertNil(manager.currentSession)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.endedAt, session.startedAt.addingTimeInterval(25 * 60))
    }

    func testOnlyTheNewestLeftoverCanResume() throws {
        let context = try makeStore()
        let now = Date()
        let older = Session(startedAt: now.addingTimeInterval(-60 * 60))
        let newer = Session(startedAt: now.addingTimeInterval(-5 * 60))
        context.insert(older)
        context.insert(newer)
        event(newer, from: newer.startedAt, to: now.addingTimeInterval(-60), in: context)
        try context.save()

        let (manager, _) = launch(context)

        XCTAssertEqual(manager.currentSession?.id, newer.id)
        XCTAssertEqual(older.status, .abandoned)
        XCTAssertEqual(older.endedAt, older.startedAt)
    }
}
