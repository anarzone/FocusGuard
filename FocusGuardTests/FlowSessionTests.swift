import SwiftData
import XCTest
@testable import FocusGuard

/// A session from start to recap, on each preset: drift, nudge, block, pass,
/// back to focus, pause, resume, extend, end.
@MainActor
final class FlowSessionTests: XCTestCase {
    private typealias Rig = FlowRig

    // MARK: - The whole way through

    func testAStandardSessionFromStartToRecap() throws {
        let rig = try Rig(preset: .standard)
        // The run below takes 1500 s; it ends about now, because stopping
        // and resuming go by the real clock.
        let paused: TimeInterval = 300
        let start = Date().addingTimeInterval(-1500)
        rig.sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        session.startedAt = start
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        // Ten focused minutes.
        rig.stay(on: Rig.editor, from: at(0), for: 600)
        XCTAssertEqual(rig.nudges.distractionCalls.count, 0)
        XCTAssertFalse(rig.overlay.isPresenting)

        // A drift: silent, a nudge at 30 s, the block screen at 90 s.
        rig.stay(on: Rig.feed, from: at(600), for: 30)
        XCTAssertEqual(rig.nudges.distractionCalls.count, 0, "nothing before 30 s")
        rig.look(at: Rig.feed, at(630))
        XCTAssertEqual(rig.nudges.distractionCalls.count, 1, "a nudge at 30 s")
        rig.stay(on: Rig.feed, from: at(631), for: 59)
        XCTAssertFalse(rig.overlay.isPresenting, "no block before 90 s")
        rig.look(at: Rig.feed, at(690))
        XCTAssertTrue(rig.overlay.isPresenting, "blocked at 90 s")
        XCTAssertEqual(rig.overlay.current?.reason, .drift(.standard))

        // "Let me through": two minutes of the same site, without more
        // nudges or blocks, then the screen is back at once.
        try rig.letThrough(at: at(691))
        XCTAssertEqual(rig.engine.activePass?.expiresAt, at(811))
        rig.stay(on: Rig.feed, from: at(691), for: 120)
        XCTAssertFalse(rig.overlay.isPresenting, "the pass holds the block back")
        XCTAssertEqual(rig.nudges.distractionCalls.count, 1, "no nudges on a pass")
        rig.look(at: Rig.feed, at(811))
        XCTAssertTrue(rig.overlay.isPresenting, "the pass ran out while on the site")

        // Back to work: the streak is gone, and focus starts counting again.
        rig.overlay.dismiss()
        rig.stay(on: Rig.editor, from: at(812), for: 88)
        XCTAssertNil(rig.engine.currentStreakStartedAt)

        // Pause: FocusGuard's menu is in front for a moment, then whatever
        // happens during the pause isn't the session's, and nothing nags.
        rig.look(at: Rig.focusGuard, at(900))
        rig.sessions.pauseSession(at: at(900))
        rig.stay(on: Rig.feed, from: at(900), for: Int(paused))
        XCTAssertFalse(rig.overlay.isPresenting, "no block while paused")
        XCTAssertEqual(rig.nudges.distractionCalls.count, 1, "no nudges while paused")
        XCTAssertNotNil(session.pausedAt)
        rig.look(at: Rig.focusGuard, at(1200))

        // Resume, from the same moment by the real clock.
        session.pausedAt = Date().addingTimeInterval(-paused)
        rig.sessions.resumeSession()
        XCTAssertEqual(session.pausedSeconds, paused, accuracy: 2)
        XCTAssertNil(session.pausedAt)

        // Extend, then finish.
        rig.sessions.extendSession(byMinutes: 5)
        XCTAssertEqual(session.plannedDurationMinutes, 30)
        rig.stay(on: Rig.editor, from: at(1200), for: 300)
        rig.look(at: Rig.focusGuard, at(1500))
        rig.sessions.stopSession()

        // The record of it.
        XCTAssertNil(rig.sessions.currentSession)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(rig.sessions.runningSeconds(for: session, now: try XCTUnwrap(session.endedAt)), 1200, accuracy: 5)
        var focus: TimeInterval = 0, drift: TimeInterval = 0
        for event in session.events {
            switch event.classification {
            case .focus: focus += event.duration
            case .distraction: drift += event.duration
            default: XCTFail("unexpected \(event.appName)")
            }
        }
        XCTAssertEqual(focus, 600 + 88 + 300, accuracy: 3, "focused stretches")
        // The pass's time is drift, like the rest: "every pass counts as drift".
        XCTAssertEqual(drift, 212, accuracy: 3, "drift, the two-minute pass included")
        XCTAssertFalse(session.events.contains { $0.startedAt >= at(900) && $0.startedAt < at(1200) },
                       "nothing from the pause belongs to the session")

        // Automatic name: same rate as the list, 82% is below "Locked-in".
        XCTAssertNotNil(session.autoName)
        XCTAssertEqual(session.displayName, session.autoName.map(SessionNamer.localizedName(stored:)))
        XCTAssertFalse(session.autoName?.hasPrefix("Locked-in") ?? true, "\(session.autoName ?? "no name")")
        let recap = SessionRecap(session: session, bestZoneToday: 0)
        XCTAssertEqual(recap.plannedMinutes, 30)
        XCTAssertEqual(recap.label, session.displayName)

    }

    // MARK: - The presets' ladders

    /// When the nudge and the block come for `preset`, in seconds of drift.
    private func ladder(_ preset: DriftResponse) throws -> (nudge: Int?, block: Int?) {
        let rig = try Rig(preset: preset)
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let start = Date()
        var nudge: Int?, block: Int?
        for second in 0...200 {
            rig.look(at: Rig.feed, start.addingTimeInterval(TimeInterval(second)))
            if nudge == nil, !rig.nudges.distractionCalls.isEmpty { nudge = second }
            if rig.overlay.isPresenting { block = second; break }
        }
        return (nudge, block)
    }

    func testEachPresetsLadder() throws {
        let gentle = try ladder(.gentle)
        XCTAssertEqual(gentle.nudge, 60)
        XCTAssertEqual(gentle.block, 180)
        let standard = try ladder(.standard)
        XCTAssertEqual(standard.nudge, 30)
        XCTAssertEqual(standard.block, 90)
        let strict = try ladder(.strict)
        XCTAssertNil(strict.nudge, "Strict goes straight to the block screen")
        XCTAssertEqual(strict.block, 0)
    }

    func testStrictSessionOffersNoPassAndForWorkOnlyAfterAWait() throws {
        let rig = try Rig(preset: .strict)
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let start = Date()
        rig.look(at: Rig.feed, start)
        XCTAssertEqual(rig.overlay.current?.reason, .drift(.strict))
        guard case .drift(let policy)? = rig.overlay.current?.reason else { return XCTFail("not a drift block") }
        XCTAssertFalse(policy.allowsPass)
        XCTAssertEqual(policy.forWorkWaitSeconds, 10)

        // Even a pass asked for directly goes nowhere.
        rig.overlay.letMeThrough()
        XCTAssertNil(rig.engine.activePass)
        rig.look(at: Rig.feed, start.addingTimeInterval(1))
        XCTAssertTrue(rig.overlay.isPresenting, "still blocked")

        // "It's for work" keeps it open for the rest of the session only.
        rig.engine.allowForSession(try XCTUnwrap(rig.tracker.currentSnapshot))
        XCTAssertFalse(rig.overlay.isPresenting)
        rig.stay(on: Rig.feed, from: start.addingTimeInterval(2), for: 30)
        XCTAssertFalse(rig.overlay.isPresenting)
        rig.engine.resetForSessionEnd()
        rig.look(at: Rig.feed, start.addingTimeInterval(40))
        XCTAssertTrue(rig.overlay.isPresenting, "the exemption ended with the session")
    }

    func testStrictLocksTheBlockedListUntilTheSessionEnds() throws {
        let rig = try Rig(preset: .strict)
        var inSession = true
        rig.classifier.isBlockListLocked = { inSession && rig.engine.policy.locksDuringSession }

        XCTAssertFalse(rig.classifier.setOverride(bundleId: Rig.feed.bundleId, classification: .focus),
                       "a blocked app can't be unblocked")
        XCTAssertFalse(rig.classifier.setOverride(bundleId: Rig.feed.bundleId, classification: .neutral))
        XCTAssertEqual(rig.classifier.classify(bundleId: Rig.feed.bundleId, windowTitle: nil, url: nil), .distraction)
        XCTAssertTrue(rig.classifier.setOverride(bundleId: Rig.editor.bundleId, classification: .distraction),
                      "more can be blocked")

        inSession = false
        XCTAssertTrue(rig.classifier.setOverride(bundleId: Rig.feed.bundleId, classification: .focus))
    }

    func testAPassForOneSiteDoesntCoverAnother() throws {
        let rig = try Rig(preset: .gentle)
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let start = Date()
        rig.tab = ExtensionTab(url: "https://www.x.com/home", title: nil)
        rig.classifier.setOverride(host: "x.com", classification: .distraction)
        rig.classifier.setOverride(host: "reddit.com", classification: .distraction)
        rig.stay(on: Rig.safari, from: start, for: 181)
        XCTAssertTrue(rig.overlay.isPresenting)
        try rig.letThrough(at: start.addingTimeInterval(181))
        XCTAssertEqual(rig.engine.activePass?.name, "x.com")

        // Another distraction starts its own ladder, inside the pass.
        rig.tab = ExtensionTab(url: "https://reddit.com/", title: nil)
        rig.stay(on: Rig.safari, from: start.addingTimeInterval(181), for: 61)
        XCTAssertEqual(rig.nudges.distractionCalls.last?.url, "https://reddit.com/")
        XCTAssertFalse(rig.overlay.isPresenting)
    }

    func testAPassThatEndsAwayFromTheSiteDoesntBlockOnTheWayBack() throws {
        let rig = try Rig(preset: .standard)
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let start = Date()
        rig.stay(on: Rig.feed, from: start, for: 91)
        try rig.letThrough(at: start.addingTimeInterval(91))
        let pass = try XCTUnwrap(rig.engine.activePass)
        // Back to work before it runs out.
        rig.stay(on: Rig.editor, from: start.addingTimeInterval(91), for: 200)
        XCTAssertNil(rig.engine.activePass, "the pass ran out")
        XCTAssertGreaterThan(start.addingTimeInterval(291), pass.expiresAt)
        // A fresh visit starts over rather than blocking straight away.
        rig.look(at: Rig.feed, start.addingTimeInterval(291))
        XCTAssertFalse(rig.overlay.isPresenting)
    }

    // MARK: - Pause and focus in FocusGuard itself

    func testFocusGuardInFrontNeverCountsAsDrift() throws {
        let rig = try Rig(preset: .standard)
        rig.sessions.startSession(plannedDurationMinutes: 50)
        let start = Date()
        rig.stay(on: Rig.feed, from: start, for: 20)
        XCTAssertNotNil(rig.engine.currentStreakStartedAt)
        rig.stay(on: Rig.focusGuard, from: start.addingTimeInterval(20), for: 200)
        XCTAssertNil(rig.engine.currentStreakStartedAt, "FocusGuard in front ends the streak")
        XCTAssertFalse(rig.overlay.isPresenting)
        XCTAssertEqual(rig.nudges.distractionCalls.count, 0)
        XCTAssertFalse(rig.events().contains { $0.bundleIdentifier == ActivityTracker.selfBundleId },
                       "time in FocusGuard isn't recorded")
    }

    func testRenamingOrClearingANameKeepsTheAutomaticOne() throws {
        let rig = try Rig()
        rig.sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        rig.sessions.stopSession()
        let automatic = session.displayName

        rig.sessions.rename(session, to: "  Tax return  ")
        XCTAssertEqual(session.label, "Tax return")
        XCTAssertEqual(session.displayName, "Tax return")

        rig.sessions.rename(session, to: "   ")
        XCTAssertNil(session.label)
        XCTAssertEqual(session.displayName, automatic)

        rig.sessions.rename(session, to: automatic)
        XCTAssertNil(session.label, "the automatic name left as it was stays automatic")
    }

    func testTheRunningSessionCantBeDeleted() throws {
        let rig = try Rig()
        rig.sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        rig.sessions.delete(session)
        XCTAssertNotNil(rig.sessions.currentSession)
        XCTAssertEqual(try rig.context.fetchCount(FetchDescriptor<Session>()), 1)
    }

    func testExtendingAnOpenEndedSessionDoesNothing() throws {
        let rig = try Rig()
        rig.sessions.startSession()
        rig.sessions.extendSession(byMinutes: 5)
        XCTAssertNil(rig.sessions.currentSession?.plannedDurationMinutes)
    }

    func testAPausedSessionDoesntRunOutAndAResumedOneStillDoes() throws {
        let rig = try Rig()
        rig.sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(rig.sessions.currentSession)
        session.startedAt = Date().addingTimeInterval(-40 * 60)
        session.pausedAt = Date().addingTimeInterval(-30 * 60)
        XCTAssertFalse(rig.sessions.checkPlannedDuration(), "ten minutes ran, then it paused")
        rig.sessions.resumeSession()
        XCTAssertEqual(session.pausedSeconds, 30 * 60, accuracy: 2)
        XCTAssertFalse(rig.sessions.checkPlannedDuration())
        session.startedAt = session.startedAt.addingTimeInterval(-16 * 60)
        XCTAssertTrue(rig.sessions.checkPlannedDuration(), "25 running minutes are up")
        XCTAssertNil(rig.sessions.currentSession)
    }

    // MARK: - After the session

    /// The notification's rate is the session's own: what happened during a
    /// pause in the same stretch of the clock doesn't count.
    func testTheCompletionRateLeavesOutWhatHappenedInAPause() throws {
        let rig = try Rig()
        let start = Date().addingTimeInterval(-3600)
        let session = Session(startedAt: start, status: .completed)
        session.endedAt = start.addingTimeInterval(3600)
        rig.context.insert(session)
        ActivityEvent.add(to: rig.context, .focus, from: start, seconds: 1800, session: session)
        // Paused for the rest of it, and on a distraction, in no session.
        ActivityEvent.add(to: rig.context, .distraction, from: start.addingTimeInterval(1800), seconds: 1800, app: Rig.feed)
        try rig.save()
        XCTAssertEqual(AppState.completionPercent(of: session), 100)
    }

    // MARK: - A calendar event during a break

    func testACalendarEventWaitsForTheBreak() {
        XCTAssertTrue(CalendarAutostartCoordinator.shouldStart(hasSession: false, onBreak: false, startedEventID: nil, eventID: "a"))
        XCTAssertFalse(CalendarAutostartCoordinator.shouldStart(hasSession: false, onBreak: true, startedEventID: nil, eventID: "a"))
        XCTAssertFalse(CalendarAutostartCoordinator.shouldStart(hasSession: true, onBreak: false, startedEventID: nil, eventID: "a"))
        XCTAssertFalse(CalendarAutostartCoordinator.shouldStart(hasSession: false, onBreak: false, startedEventID: "a", eventID: "a"),
                       "the user ended that event's session themselves")
    }

    /// The menu's recap suggests a break from the session's length, like the
    /// notification does. An open session has no planned length, so the
    /// recap falls back to 25 minutes however long it ran.
    func testTheRecapsBreakFitsAnOpenSessionsLength() throws {
        let rig = try Rig()
        rig.sessions.startSession()
        let session = try XCTUnwrap(rig.sessions.currentSession)
        session.startedAt = Date().addingTimeInterval(-2 * 3600)
        rig.sessions.stopSession()
        let recap = SessionRecap(session: session, bestZoneToday: 0)
        // The notification for the same session (`presentSessionComplete`).
        let noted = AppState.suggestedBreakMinutes(forSessionMinutes: 120)
        XCTAssertEqual(recap.suggestedBreakMinutes, noted)
    }
}
