import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class SessionNamerTests: XCTestCase {
    private func seg(_ c: Classification, _ minutes: Double) -> SessionTimeline.Segment {
        .init(classification: c, seconds: minutes * 60)
    }

    private func pattern(_ segments: [SessionTimeline.Segment]) -> SessionNamer.Pattern {
        SessionNamer.pattern(of: segments)
    }

    // MARK: - Length

    func testLengthWords() {
        XCTAssertEqual(SessionNamer.Length(minutes: 12), .sprint)
        XCTAssertEqual(SessionNamer.Length(minutes: 20), .run)
        XCTAssertEqual(SessionNamer.Length(minutes: 44.9), .run)
        XCTAssertEqual(SessionNamer.Length(minutes: 45), .deepDive)
        XCTAssertEqual(SessionNamer.Length(minutes: 90), .deepDive)
        XCTAssertEqual(SessionNamer.Length(minutes: 91), .marathon)
    }

    // MARK: - Pattern

    func testMostlyFocusedIsLockedIn() {
        XCTAssertEqual(pattern([seg(.focus, 28), seg(.distraction, 2)]), .lockedIn)
    }

    func testDriftOnlyAtTheStartIsSlowStart() {
        XCTAssertEqual(pattern([seg(.distraction, 10), seg(.focus, 20)]), .slowStart)
    }

    func testDriftInTheMiddleThenCleanFinishIsComeback() {
        XCTAssertEqual(pattern([seg(.focus, 5), seg(.distraction, 8), seg(.focus, 17)]), .comeback)
    }

    func testCleanStartThenDriftIsFading() {
        XCTAssertEqual(pattern([seg(.focus, 20), seg(.distraction, 10)]), .fading)
    }

    func testDriftSpreadEvenlyFallsBackToShare() {
        let steady = Array(repeating: [seg(.focus, 8), seg(.distraction, 2)], count: 3).flatMap { $0 }
        XCTAssertEqual(pattern(steady), .steady)
        let bumpy = Array(repeating: [seg(.focus, 6), seg(.distraction, 4)], count: 3).flatMap { $0 }
        XCTAssertEqual(pattern(bumpy), .bumpy)
        let wandering = Array(repeating: [seg(.focus, 3), seg(.distraction, 7)], count: 3).flatMap { $0 }
        XCTAssertEqual(pattern(wandering), .wandering)
    }

    func testNothingTrackedIsQuiet() {
        XCTAssertEqual(pattern([]), .quiet)
        XCTAssertEqual(pattern([seg(.focus, 0.5)]), .quiet)
    }

    func testNameCombinesPatternAndLength() {
        XCTAssertEqual(SessionNamer.name(segments: [seg(.focus, 50)], runningSeconds: 50 * 60), "Locked-in Deep Dive")
        XCTAssertEqual(SessionNamer.name(segments: [seg(.focus, 5), seg(.distraction, 8), seg(.focus, 17)],
                                         runningSeconds: 30 * 60), "Comeback Run")
    }

    // MARK: - While running

    func testLiveNameFollowsTimeOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour))! }
        XCTAssertEqual(SessionNamer.liveName(startedAt: at(9), calendar: calendar), "Morning focus")
        XCTAssertEqual(SessionNamer.liveName(startedAt: at(13), calendar: calendar), "Afternoon focus")
        XCTAssertEqual(SessionNamer.liveName(startedAt: at(19), calendar: calendar), "Evening focus")
        XCTAssertEqual(SessionNamer.liveName(startedAt: at(23), calendar: calendar), "Late-night focus")
        XCTAssertEqual(SessionNamer.liveName(startedAt: at(3), calendar: calendar), "Late-night focus")
    }

    func testDisplayNamePrefersTheUsersLabel() {
        let session = Session(startedAt: Date(), label: "Thesis")
        session.autoName = "Steady Run"
        XCTAssertEqual(session.displayName, "Thesis")
        session.label = nil
        XCTAssertEqual(session.displayName, "Steady Run")
        session.autoName = nil
        XCTAssertEqual(session.displayName, SessionNamer.liveName(startedAt: session.startedAt))
    }

    // MARK: - Applied by SessionManager

    private func makeStore() throws -> ModelContext {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        addTeardownBlock { _ = container }
        return container.mainContext
    }

    private func manager(_ context: ModelContext) -> SessionManager {
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: Classifier(context: context))
        return SessionManager(context: context, tracker: tracker)
    }

    private func focusEvent(_ session: Session, from: Date, to: Date, in context: ModelContext) {
        let event = ActivityEvent(startedAt: from, endedAt: to, bundleIdentifier: "com.apple.dt.Xcode",
                                  appName: "Xcode", session: session)
        event.classification = .focus
        context.insert(event)
    }

    func testEndingASessionNamesIt() throws {
        let context = try makeStore()
        let manager = manager(context)
        manager.startSession(plannedDurationMinutes: 25)
        let session = try XCTUnwrap(manager.currentSession)
        session.startedAt = Date().addingTimeInterval(-30 * 60)
        focusEvent(session, from: session.startedAt, to: Date(), in: context)

        manager.stopSession()

        XCTAssertNil(session.label)
        XCTAssertEqual(session.autoName, "Locked-in Run")
        XCTAssertEqual(session.displayName, "Locked-in Run")
    }

    func testRenamingBackToTheAutomaticNameKeepsItAutomatic() throws {
        let context = try makeStore()
        let manager = manager(context)
        let session = Session(startedAt: Date().addingTimeInterval(-3600))
        session.endedAt = Date()
        session.autoName = "Steady Deep Dive"
        context.insert(session)

        manager.rename(session, to: "Steady Deep Dive ")
        XCTAssertNil(session.label)
        manager.rename(session, to: "Thesis chapter 2")
        XCTAssertEqual(session.label, "Thesis chapter 2")
        manager.rename(session, to: "")
        XCTAssertNil(session.label)
    }

    func testLaunchNamesEarlierSessionsAndDropsTheOldDefaultLabel() throws {
        let context = try makeStore()
        let start = Date().addingTimeInterval(-2 * 3600)
        let old = Session(startedAt: start, label: "Deep work")
        old.endedAt = start.addingTimeInterval(50 * 60)
        old.status = .completed
        context.insert(old)
        focusEvent(old, from: start, to: start.addingTimeInterval(50 * 60), in: context)
        let mine = Session(startedAt: start, label: "Taxes")
        mine.endedAt = start.addingTimeInterval(10 * 60)
        mine.status = .completed
        context.insert(mine)
        try context.save()

        _ = manager(context)

        XCTAssertNil(old.label)
        XCTAssertEqual(old.displayName, "Locked-in Deep Dive")
        XCTAssertEqual(mine.label, "Taxes")
        XCTAssertEqual(mine.autoName, "Quiet Sprint")
    }
}
