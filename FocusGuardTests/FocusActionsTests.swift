import XCTest
import SwiftData
@testable import FocusGuard

/// What Shortcuts, Siri, Spotlight and the Focus filter do to sessions and
/// breaks, and what they say back.
@MainActor
final class FocusActionsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var sessions: SessionManager!
    private var breaks: BreakManager!

    override func setUpWithError() throws {
        let suite = "FocusActionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        addTeardownBlock { _ = container }
        let context = container.mainContext
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: Classifier(context: context))
        sessions = SessionManager(context: context, tracker: tracker)
        breaks = BreakManager(defaults: defaults)
    }

    private var actions: FocusActions {
        FocusActions(sessions: sessions, breaks: breaks,
                     startBreak: { [breaks] in breaks?.startBreak(durationMinutes: $0) }, defaults: defaults)
    }

    // MARK: - Start

    func testStartUsesTheMenusLastLengthThenTheDefault() {
        XCTAssertEqual(actions.usualMinutes, 50)
        defaults.set(35, forKey: SessionDefaultsKey.durationMinutes)
        XCTAssertEqual(actions.usualMinutes, 35)
        defaults.set(90, forKey: SurfaceKeys.lastSessionMinutes)
        XCTAssertEqual(actions.usualMinutes, 90)

        let now = Date()
        guard case .started(_, let minutes, let endsAt) = actions.start(now: now) else { return XCTFail() }
        XCTAssertEqual(minutes, 90)
        XCTAssertEqual(sessions.currentSession?.plannedDurationMinutes, 90)
        XCTAssertEqual(endsAt?.timeIntervalSince(now) ?? 0, 90 * 60, accuracy: 1)
    }

    func testStartClampsTheLength() {
        actions.start(minutes: 1)
        XCTAssertEqual(sessions.currentSession?.plannedDurationMinutes, Constants.SessionDurations.customMin)
    }

    func testStartWithANameOrTheDefaultLabel() {
        defaults.set("Thesis", forKey: SessionDefaultsKey.label)
        actions.start(minutes: 25, label: "  ")
        XCTAssertEqual(sessions.currentSession?.label, "Thesis")
        actions.end()
        actions.start(minutes: 25, label: "Taxes")
        XCTAssertEqual(sessions.currentSession?.label, "Taxes")
    }

    func testOpenEndedStart() {
        guard case .started(_, nil, nil) = actions.start(openEnded: true) else { return XCTFail() }
        XCTAssertNil(sessions.currentSession?.plannedDurationMinutes)
    }

    func testStartWhileRunningLeavesTheSessionAlone() {
        actions.start(minutes: 25, label: "First")
        let first = sessions.currentSession?.id
        XCTAssertEqual(actions.start(minutes: 50), .alreadyRunning(name: "First"))
        XCTAssertEqual(sessions.currentSession?.id, first)
        XCTAssertEqual(sessions.currentSession?.plannedDurationMinutes, 25)
    }

    func testStartEndsABreakThatCanEndEarly() {
        breaks.startBreak(durationMinutes: 10)
        guard case .started = actions.start(minutes: 25) else { return XCTFail() }
        XCTAssertNil(breaks.current)
        XCTAssertNotNil(sessions.currentSession)
    }

    func testStartWaitsForAStrictBreak() {
        defaults.set(true, forKey: SettingsKeys.Breaks.strictMode)
        breaks.startBreak(durationMinutes: 10)
        guard case .onStrictBreak = actions.start(minutes: 25) else { return XCTFail() }
        XCTAssertNotNil(breaks.current)
        XCTAssertNil(sessions.currentSession)
    }

    // MARK: - End, pause

    func testEnd() {
        XCTAssertEqual(actions.end(), .nothingRunning)
        actions.start(minutes: 25, label: "Taxes")
        XCTAssertEqual(actions.end(), .ended(name: "Taxes", minutes: 0))
        XCTAssertNil(sessions.currentSession)
    }

    func testPauseAndResume() {
        XCTAssertEqual(actions.pauseOrResume(), .nothingRunning)
        actions.start(minutes: 25, label: "Taxes")

        guard case .paused(let name, let left) = actions.pauseOrResume() else { return XCTFail() }
        XCTAssertEqual(name, "Taxes")
        XCTAssertEqual(left ?? 0, 25 * 60, accuracy: 2)
        XCTAssertNotNil(sessions.currentSession?.pausedAt)
        XCTAssertEqual(actions.pauseOrResume(.pause), .alreadyPaused(name: "Taxes"))

        guard case .resumed = actions.pauseOrResume(.resume) else { return XCTFail() }
        XCTAssertNil(sessions.currentSession?.pausedAt)
        XCTAssertEqual(actions.pauseOrResume(.resume), .alreadyRunning(name: "Taxes"))
    }

    // MARK: - Breaks

    func testTakingABreakEndsTheSession() {
        actions.start(minutes: 25, label: "Taxes")
        guard case .started(let minutes, _, let ended) = actions.takeBreak(minutes: 10) else { return XCTFail() }
        XCTAssertEqual(minutes, 10)
        XCTAssertEqual(ended, "Taxes")
        XCTAssertNil(sessions.currentSession)
        XCTAssertEqual(breaks.current?.plannedDuration, 600)

        guard case .alreadyOnBreak = actions.takeBreak(minutes: 5) else { return XCTFail() }
        XCTAssertEqual(breaks.current?.plannedDuration, 600)
    }

    func testBreakLengthIsClamped() {
        actions.takeBreak(minutes: 500)
        XCTAssertEqual(breaks.current?.plannedDuration, TimeInterval(FocusActions.breakRange.upperBound * 60))
    }

    func testEndBreak() {
        XCTAssertEqual(actions.endBreak(), .notOnBreak)
        breaks.startBreak(durationMinutes: 10)
        actions.extendBreak()
        XCTAssertEqual(breaks.current?.plannedDuration, 15 * 60)
        XCTAssertEqual(actions.endBreak(), .ended)
        XCTAssertNil(breaks.current)

        defaults.set(true, forKey: SettingsKeys.Breaks.strictMode)
        breaks.startBreak(durationMinutes: 10)
        guard case .strict = actions.endBreak() else { return XCTFail() }
        XCTAssertNotNil(breaks.current)
    }

    // MARK: - Words

    func testWords() {
        let at = Calendar.current.date(bySettingHour: 15, minute: 40, second: 0, of: Date()) ?? Date()
        let clock = IntentWords.clock(at)
        XCTAssertEqual(IntentWords.start(.started(name: "Taxes", minutes: 50, endsAt: at)),
                       "Started a 50-minute focus session. It ends at \(clock).")
        XCTAssertEqual(IntentWords.start(.alreadyRunning(name: "Taxes")), "“Taxes” is already running.")
        XCTAssertEqual(IntentWords.end(.ended(name: "Taxes", minutes: 1)), "Ended “Taxes” after 1 minute.")
        XCTAssertEqual(IntentWords.end(.nothingRunning), "No focus session is running.")
        XCTAssertEqual(IntentWords.pause(.paused(name: "Taxes", left: 17 * 60 + 5)), "Paused “Taxes”, with 18 minutes left.")
        XCTAssertEqual(IntentWords.takeBreak(.started(minutes: 10, until: at, endedSession: "Taxes")),
                       "Ended “Taxes”. Started a 10-minute break. Back at \(clock).")
        XCTAssertEqual(IntentWords.minutes(30), "1 minute")
    }
}

/// The Focus filter starts a session when its Focus turns on and ends only
/// that session when the Focus turns off.
@MainActor
final class FocusFilterResponderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var sessions: SessionManager!
    private var breaks: BreakManager!

    override func setUpWithError() throws {
        let suite = "FocusFilterResponderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        addTeardownBlock { _ = container }
        let context = container.mainContext
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: Classifier(context: context))
        sessions = SessionManager(context: context, tracker: tracker)
        breaks = BreakManager(defaults: defaults)
    }

    private var actions: FocusActions {
        FocusActions(sessions: sessions, breaks: breaks,
                     startBreak: { [breaks] in breaks?.startBreak(durationMinutes: $0) }, defaults: defaults)
    }

    private var responder: FocusFilterResponder { FocusFilterResponder(defaults: defaults) }

    /// The Focus turning off: every parameter back at its default.
    private func turnOff() -> FocusFilterResponder.Outcome {
        responder.apply(startSession: false, minutes: nil, endWhenOff: true, actions: actions)
    }

    func testOnStartsAnOpenEndedSessionAndOffEndsIt() {
        XCTAssertEqual(responder.apply(startSession: true, minutes: nil, endWhenOff: true, actions: actions), .started)
        XCTAssertNotNil(sessions.currentSession)
        XCTAssertNil(sessions.currentSession?.plannedDurationMinutes)

        XCTAssertEqual(turnOff(), .ended)
        XCTAssertNil(sessions.currentSession)
    }

    func testTimedLength() {
        responder.apply(startSession: true, minutes: 50, endWhenOff: true, actions: actions)
        XCTAssertEqual(sessions.currentSession?.plannedDurationMinutes, 50)
    }

    func testOffKeepsTheSessionWhenAskedTo() {
        // "End the session when Work turns off" was off when it started; the
        // defaults delivered on the way out don't change that.
        responder.apply(startSession: true, minutes: nil, endWhenOff: false, actions: actions)
        XCTAssertEqual(turnOff(), .leftAlone)
        XCTAssertNotNil(sessions.currentSession)
    }

    func testNeverTakesOverASessionTheUserStarted() {
        actions.start(minutes: 25, label: "Mine")
        let mine = sessions.currentSession?.id
        XCTAssertEqual(responder.apply(startSession: true, minutes: 90, endWhenOff: true, actions: actions), .leftAlone)
        XCTAssertEqual(turnOff(), .leftAlone)
        XCTAssertEqual(sessions.currentSession?.id, mine)
    }

    func testDeliveredAgainWhileOnDoesNothing() {
        responder.apply(startSession: true, minutes: nil, endWhenOff: true, actions: actions)
        let first = sessions.currentSession?.id
        XCTAssertEqual(responder.apply(startSession: true, minutes: nil, endWhenOff: true, actions: actions), .leftAlone)
        XCTAssertEqual(sessions.currentSession?.id, first)
        XCTAssertEqual(turnOff(), .ended)
    }

    func testALaterSessionIsNotEnded() {
        // The filter's session ended on its own; the user started another
        // before the Focus turned off.
        responder.apply(startSession: true, minutes: 25, endWhenOff: true, actions: actions)
        actions.end()
        actions.start(minutes: 25, label: "Mine")
        XCTAssertEqual(turnOff(), .leftAlone)
        XCTAssertEqual(sessions.currentSession?.label, "Mine")
    }

    func testDoesNotInterruptABreak() {
        breaks.startBreak(durationMinutes: 10)
        XCTAssertEqual(responder.apply(startSession: true, minutes: nil, endWhenOff: true, actions: actions), .leftAlone)
        XCTAssertNotNil(breaks.current)
        XCTAssertNil(sessions.currentSession)
    }

    func testFilterDefaultsMeanOff() {
        let filter = FocusGuardFocusFilter()
        XCTAssertFalse(filter.startSession)
        XCTAssertNil(filter.length.minutes)
    }
}
