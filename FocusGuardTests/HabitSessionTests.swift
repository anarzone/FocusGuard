import XCTest
import SwiftData
@testable import FocusGuard

/// Habits acting on sessions: starting one from the auto-start offer, and
/// nudges waiting during calls.
@MainActor
final class HabitSessionTests: XCTestCase {
    private func makeStore() throws -> ModelContext {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    func testABackdatedSessionTakesTheWorkSinceThen() throws {
        let context = try makeStore()
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context),
                                      classifier: Classifier(context: context))
        let manager = SessionManager(context: context, tracker: tracker)
        let now = Date()
        let opened = now.addingTimeInterval(-5 * 60)
        let before = ActivityEvent(startedAt: opened.addingTimeInterval(-600), endedAt: opened.addingTimeInterval(-60),
                                   bundleIdentifier: "com.apple.Safari", appName: "Safari")
        let xcode = ActivityEvent(startedAt: opened, endedAt: now, bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        context.insert(before)
        context.insert(xcode)

        let actions = FocusActions(sessions: manager, breaks: BreakManager(), startBreak: { _ in })
        let result = actions.start(minutes: 50, startedAt: opened, now: now)

        let session = try XCTUnwrap(manager.currentSession)
        XCTAssertEqual(session.startedAt, opened)
        XCTAssertTrue(xcode.session === session)
        XCTAssertNil(before.session)
        XCTAssertEqual(manager.runningSeconds(for: session, now: now), 5 * 60, accuracy: 1)
        guard case .started(_, _, let endsAt) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(endsAt, opened.addingTimeInterval(50 * 60))
    }

    func testAStartInTheFutureIsNow() throws {
        let context = try makeStore()
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context),
                                      classifier: Classifier(context: context))
        let manager = SessionManager(context: context, tracker: tracker)
        manager.startSession(startedAt: Date().addingTimeInterval(3600))
        XCTAssertLessThanOrEqual(try XCTUnwrap(manager.currentSession).startedAt, Date())
    }

    func testNudgesWaitDuringACall() {
        let presenter = EscalationEngineTests.RecordingPresenter()
        let overlay = EscalationEngineTests.StubOverlay()
        let engine = EscalationEngine(presenter: presenter, overlay: overlay)
        engine.notifyThreshold = 30
        engine.blockThreshold = 60
        var inCall = true
        engine.holdsNudges = { inCall }

        let t0 = Date()
        func drift(_ seconds: TimeInterval) {
            engine.observe(snapshot: ActivitySnapshot(bundleIdentifier: "com.google.Chrome", appName: "Chrome", windowTitle: nil,
                                                      url: "https://x.com", classification: .distraction,
                                                      observedAt: t0.addingTimeInterval(seconds)), isInSession: true)
        }
        drift(0); drift(40); drift(90)
        XCTAssertTrue(presenter.distractionCalls.isEmpty)
        XCTAssertEqual(overlay.presentCount, 0)

        // After the call, drift counts from scratch.
        inCall = false
        drift(100); drift(125)
        XCTAssertTrue(presenter.distractionCalls.isEmpty)
        drift(131)
        XCTAssertEqual(presenter.distractionCalls.count, 1)
    }
}
