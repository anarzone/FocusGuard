import AppKit
import SwiftData
import XCTest
@testable import FocusGuard

/// The real wiring: an `AppState` in UITestMode (an in-memory store, no
/// tracker timer, no integrations), driven one tracker tick at a time through
/// its own `onTick`. Here is what lives only in `AppState`: auto-pause and
/// auto-resume, and what the engines and the block screen read off the tracker.
///
/// CI only. Building an `AppState` reads the Keychain and the app's defaults,
/// which on the owner's Mac are the real app's. On the runner they're nobody's.
@MainActor
final class FlowAppStateTests: XCTestCase {
    private typealias Rig = FlowRig
    private var state: AppState!
    private var idle: TimeInterval = 0
    private var wasOn = false

    override func setUpWithError() throws {
        try XCTSkipUnless(NSUserName() == "runner", "Runs on CI: AppState touches the real app's Keychain items and defaults")
        wasOn = UITestMode.isOn
        UITestMode.isOn = true
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: HabitSettings.morningPlan)
        defaults.set(false, forKey: HabitSettings.eveningWrapUp)
        defaults.set(false, forKey: HabitSettings.autoStartOffer)
        defaults.set("empty", forKey: "FocusGuardUITestSeed")
        state = AppState()
        state.habits.readMicrophone = { .init(recording: [], microphoneInUse: false, runningApps: [], frontURL: $0) }
        state.classifier.setOverride(bundleId: Rig.editor.bundleId, classification: .focus)
        state.classifier.setOverride(bundleId: Rig.feed.bundleId, classification: .distraction)
        state.tracker.readWindowTitle = { _ in nil }
        state.tracker.secondsSinceInput = { [unowned self] in idle }
        state.tracker.displayKeptAwake = { false }
    }

    override func tearDownWithError() throws {
        guard state != nil else { return }
        if state.sessionManager.currentSession != nil { state.sessionManager.stopSession() }
        state = nil
        UITestMode.isOn = wasOn
        UserDefaults.standard.removeObject(forKey: "FocusGuardUITestSeed")
    }

    private var sessions: SessionManager { state.sessionManager }

    /// A tracker tick now, on `front`, through `AppState`'s own `onTick`.
    private func tick(_ front: FrontmostApp = Rig.editor) {
        state.tracker.record(front, now: Date())
    }

    /// Lets a notification's main-actor hop run, until `done` or a few seconds.
    private func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if done() { return }
        }
    }

    private func postDistributed(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    /// The real block screen's windows are at screen-saver level.
    private var blockScreenIsUp: Bool {
        NSApp.windows.contains { $0.level == .screenSaver && $0.isVisible }
    }

    /// No input for six minutes: the tick that notices pauses the session.
    private func goIdleUntilAutoPause() throws -> Session {
        let session = try XCTUnwrap(sessions.currentSession)
        idle = 360
        tick()
        XCTAssertNotNil(session.pausedAt, "idle should auto-pause")
        return session
    }

    // MARK: - Auto-pause

    func testIdleAutoPausesAndComingBackAutoResumes() throws {
        sessions.startSession(plannedDurationMinutes: 120)
        try XCTUnwrap(sessions.currentSession).startedAt = Date().addingTimeInterval(-3600)
        tick()
        let session = try goIdleUntilAutoPause()
        // The pause starts at the last input, not when it was noticed.
        XCTAssertEqual(session.pausedAt?.timeIntervalSinceNow ?? 0, -360, accuracy: 5)
        idle = 0
        tick()
        XCTAssertNil(session.pausedAt, "back at the Mac: resumed")
        XCTAssertEqual(session.pausedSeconds, 360, accuracy: 5)
    }

    func testAPauseByHandHoldsWhenNothingElseHasPaused() throws {
        sessions.startSession(plannedDurationMinutes: 50)
        tick()
        sessions.pauseSession()
        tick()
        tick()
        XCTAssertNotNil(sessions.currentSession?.pausedAt, "the tick leaves the user's pause alone")
    }

    /// An idle pause resumed by hand, or a session ended while auto-paused:
    /// the next pause by hand is the user's own, and the next tick leaves it.
    func testAPauseByHandHoldsAfterAnAutoPauseWasResumedByHand() throws {
        sessions.startSession(plannedDurationMinutes: 50)
        tick()
        let session = try goIdleUntilAutoPause()
        sessions.resumeSession()
        idle = 0
        tick()
        XCTAssertNil(session.pausedAt)

        sessions.pauseSession()
        tick()
        XCTAssertNotNil(session.pausedAt, "the user's pause should hold")
    }

    func testAPauseByHandHoldsInTheSessionAfterOneEndedAutoPaused() throws {
        sessions.startSession(plannedDurationMinutes: 50)
        tick()
        _ = try goIdleUntilAutoPause()
        sessions.stopSession()
        idle = 0

        sessions.startSession(plannedDurationMinutes: 50)
        let next = try XCTUnwrap(sessions.currentSession)
        tick()
        sessions.pauseSession()
        tick()
        XCTAssertNotNil(next.pausedAt, "the user's pause should hold")
    }

    /// Screens off, no lock: the session pauses on the notification, and
    /// recent input from before they went off doesn't resume it.
    func testScreensOffKeepTheSessionPausedUntilTheyWake() async throws {
        sessions.startSession(plannedDurationMinutes: 50)
        let session = try XCTUnwrap(sessions.currentSession)
        tick()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle { session.pausedAt != nil }
        XCTAssertNotNil(session.pausedAt, "screens off pause it")

        idle = 30
        tick()
        XCTAssertNotNil(session.pausedAt, "the screens are still off")
    }

    func testTheLockScreenHoldsThePauseUntilUnlocked() async throws {
        sessions.startSession(plannedDurationMinutes: 50)
        let session = try XCTUnwrap(sessions.currentSession)
        tick()
        postDistributed("com.apple.screenIsLocked")
        await settle { session.pausedAt != nil }
        XCTAssertNotNil(session.pausedAt, "locking pauses it")
        tick(Rig.lockScreen)
        XCTAssertNotNil(session.pausedAt, "the lock screen's ticks leave it paused")
        postDistributed("com.apple.screenIsUnlocked")
        await settle { session.pausedAt == nil }
        XCTAssertNil(session.pausedAt, "unlocking resumes it")
    }

    /// Pins today's behaviour for the owner to weigh: a session the Mac slept
    /// through, paused by the screens going off, picks up on wake however long
    /// it's been, with its old start. A relaunch would have ended the same
    /// session after 15 minutes (`leftoverOutcome`).
    func testASessionPausedThroughALongSleepResumesOnWake() async throws {
        sessions.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(sessions.currentSession)
        tick()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle { session.pausedAt != nil }
        // It started last night and paused ten minutes in.
        session.startedAt = Date().addingTimeInterval(-14 * 3600)
        session.pausedAt = session.startedAt.addingTimeInterval(600)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle { session.pausedAt == nil }
        XCTAssertTrue(sessions.currentSession === session, "still the same session")
        XCTAssertNil(session.pausedAt)
        XCTAssertEqual(sessions.runningSeconds(for: session), 600, accuracy: 5, "fifteen minutes still to go, the next morning")
    }

    // MARK: - The block screen

    /// While the block screen is up FocusGuard is in front. The streak goes
    /// on behind it, for the screen's "Drifted 1:42", and stops once it's down.
    func testTheBlockScreenKeepsCountingTheDrift() throws {
        let engine = state.escalationEngine
        engine.strictMode = true
        defer { engine.strictMode = false }
        sessions.startSession(plannedDurationMinutes: 50)
        tick(Rig.feed)
        XCTAssertTrue(blockScreenIsUp, "Strict blocks straight away")
        XCTAssertNotNil(engine.currentStreakStartedAt, "the drift is counted")
        XCTAssertNotNil(state.blockContext()?.awaySince)

        // The screen came up and activated the app.
        tick(Rig.focusGuard)
        XCTAssertNotNil(state.blockContext()?.awaySince, "the drift goes on behind the block screen")
        engine.resetForSessionEnd()
    }

    // MARK: - The limit and the session together

    func testADailyLimitBlocksOutOfASessionAndStaysWhenOneEnds() async throws {
        let host = "limited.example"
        state.tracker.extensionTab = { _ in ExtensionTab(url: "https://\(host)/", title: nil) }
        state.classifier.setOverride(host: host, classification: .neutral)
        let start = Date().addingTimeInterval(-3600)
        ActivityEvent.add(to: state.container.mainContext, .neutral, from: start, seconds: 6 * 60, app: Rig.safari, url: "https://\(host)/")
        try state.container.mainContext.save()
        let limit = try XCTUnwrap(state.limits.addLimit(target: host, isSite: true, minutes: 5))
        XCTAssertEqual(state.limits.status(for: limit.id)?.isUsedUp, true)
        XCTAssertFalse(blockScreenIsUp)

        // No session running: it still blocks.
        tick(Rig.safari)
        XCTAssertTrue(blockScreenIsUp, "daily limits block in sessions and out")
        XCTAssertTrue(state.needsSecondTicks, "a limit in front is timed to the second")

        // A session starting and ending behind it doesn't take it down.
        sessions.startSession(plannedDurationMinutes: 25)
        sessions.stopSession()
        XCTAssertTrue(blockScreenIsUp, "a daily limit's block stays when a session ends")

        state.limits.removeLimit(limit.id)
        await settle { !blockScreenIsUp }
        XCTAssertFalse(blockScreenIsUp, "removing the limit lifts it")
    }

    // MARK: - The pace

    func testThePaceFollowsWhatsGoingOn() throws {
        XCTAssertFalse(state.needsSecondTicks, "nothing timed")
        sessions.startSession(plannedDurationMinutes: 50)
        XCTAssertTrue(state.needsSecondTicks, "a session")
        sessions.pauseSession()
        XCTAssertTrue(state.needsSecondTicks, "a paused session")
        sessions.stopSession()
        XCTAssertFalse(state.needsSecondTicks)
        state.breakManager.startBreak(durationMinutes: 5)
        XCTAssertTrue(state.needsSecondTicks, "a break")
        state.breakManager.skip()
        XCTAssertFalse(state.needsSecondTicks)
    }

    func testTheMenuBarLabelThroughASessionAndAPass() throws {
        XCTAssertNil(state.statusLabel(), "nothing to show")
        sessions.startSession(plannedDurationMinutes: 25)
        XCTAssertEqual(state.statusLabel()?.text, "25m")
        sessions.pauseSession()
        XCTAssertEqual(state.statusLabel()?.dimmed, true)
        sessions.resumeSession()
        tick(Rig.feed)
        let snapshot = try XCTUnwrap(state.tracker.currentSnapshot)
        state.escalationEngine.takePass(for: snapshot)
        XCTAssertEqual(state.statusLabel()?.text, "\(Rig.feed.name) 2:00")
        XCTAssertEqual(state.statusLabel()?.showsDot, true)
        sessions.stopSession()
        XCTAssertNil(state.statusLabel(), "a pass ends with its session")
    }
}
