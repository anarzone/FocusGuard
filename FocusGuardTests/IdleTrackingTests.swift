import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class IdleTrackingTests: XCTestCase {
    func testAwayOnlyAfterFiveQuietMinutesAndNotWhileSomethingKeepsTheDisplayOn() {
        XCTAssertFalse(IdleMonitor.isAway(idleSeconds: 299, displayKeptAwake: false))
        XCTAssertTrue(IdleMonitor.isAway(idleSeconds: 300, displayKeptAwake: false))
        XCTAssertTrue(IdleMonitor.isAway(idleSeconds: 8 * 3600, displayKeptAwake: false))
        XCTAssertFalse(IdleMonitor.isAway(idleSeconds: 3600, displayKeptAwake: true)) // watching a video
    }

    func testBackdatedPauseDoesntCountIdleMinutes() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: Classifier(context: context))
        let manager = SessionManager(context: context, tracker: tracker)

        manager.startSession(label: "Deep work", plannedDurationMinutes: 25)
        let session = try XCTUnwrap(manager.currentSession)
        session.startedAt = Date().addingTimeInterval(-20 * 60)

        // Last input 10 minutes ago; the pause starts there, not now.
        manager.pauseSession(at: Date().addingTimeInterval(-10 * 60))
        XCTAssertEqual(manager.runningSeconds(for: session), 10 * 60, accuracy: 2)

        // Can't backdate before the session started.
        manager.resumeSession()
        manager.pauseSession(at: .distantPast)
        XCTAssertEqual(session.pausedAt, session.startedAt)
    }
}
