import XCTest
import SwiftData
@testable import FocusGuard

/// Fixes from the code audit: strict breaks, reduce motion, plurals, "Back to
/// work", calendar autostart, browser access retry, export, goal range.
@MainActor
final class AuditFixesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AuditFixesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Strict breaks

    func test_strictBreak_cannotBeEndedEarly() {
        defaults.set(true, forKey: SettingsKeys.Breaks.strictMode)
        let breaks = BreakManager(defaults: defaults)
        var ended = false
        breaks.onBreakEnded = { ended = true }
        breaks.startBreak(durationMinutes: 5)

        XCTAssertFalse(breaks.canEndEarly)
        breaks.skip()
        XCTAssertTrue(breaks.isOnBreak)
        XCTAssertFalse(ended)
    }

    func test_normalBreak_endsEarly() {
        let breaks = BreakManager(defaults: defaults)
        var ended = false
        breaks.onBreakEnded = { ended = true }
        breaks.startBreak(durationMinutes: 5)

        XCTAssertTrue(breaks.canEndEarly)
        breaks.skip()
        XCTAssertFalse(breaks.isOnBreak)
        XCTAssertTrue(ended)
    }

    // MARK: - Reduce motion

    func test_reduceMotion_eitherSettingIsEnough() {
        XCTAssertFalse(Motion.isReduced(system: false, app: false))
        XCTAssertTrue(Motion.isReduced(system: true, app: false))
        XCTAssertTrue(Motion.isReduced(system: false, app: true))
    }

    // MARK: - Plurals

    func test_counted_usesSingularForOne() {
        XCTAssertEqual(counted(1, "day"), "1 day")
        XCTAssertEqual(counted(0, "day"), "0 days")
        XCTAssertEqual(counted(3, "minute"), "3 minutes")
        XCTAssertEqual(counted(1, "activity event"), "1 activity event")
        XCTAssertEqual(counted(2, "child", plural: "children"), "2 children")
    }

    // MARK: - Back to work

    func test_backToWork_returnsToTheLastFocusApp() {
        let target = BackToWork.target(lastFocus: "com.apple.dt.Xcode", isRunning: { _ in true },
                                       distraction: "com.apple.Safari", selfId: "com.anar.focusguard")
        XCTAssertEqual(target, .activate("com.apple.dt.Xcode"))
    }

    func test_backToWork_hidesTheDistractionWhenTheFocusAppQuit() {
        let target = BackToWork.target(lastFocus: "com.apple.dt.Xcode", isRunning: { _ in false },
                                       distraction: "com.apple.Safari", selfId: "com.anar.focusguard")
        XCTAssertEqual(target, .hide("com.apple.Safari"))
    }

    func test_backToWork_neverHidesFocusGuard() {
        let target = BackToWork.target(lastFocus: nil, isRunning: { _ in true },
                                       distraction: "com.anar.focusguard", selfId: "com.anar.focusguard")
        XCTAssertEqual(target, .none)
        XCTAssertEqual(BackToWork.target(lastFocus: nil, isRunning: { _ in true },
                                         distraction: nil, selfId: "com.anar.focusguard"), .none)
    }

    // MARK: - Calendar autostart

    func test_calendar_stopsOnlyTheSessionItStarted() {
        let started = UUID()
        XCTAssertTrue(CalendarAutostartCoordinator.isOurs(startedSessionID: started, current: started))
        XCTAssertFalse(CalendarAutostartCoordinator.isOurs(startedSessionID: started, current: UUID()))
        XCTAssertFalse(CalendarAutostartCoordinator.isOurs(startedSessionID: started, current: nil))
        XCTAssertFalse(CalendarAutostartCoordinator.isOurs(startedSessionID: nil, current: UUID()))
    }

    // MARK: - Browser access

    func test_deniedBrowser_isAskedAgainAfterAWhile() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(BrowserTabReader.shouldRetryDenied(lastDenied: nil, now: now))
        XCTAssertFalse(BrowserTabReader.shouldRetryDenied(lastDenied: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(BrowserTabReader.shouldRetryDenied(
            lastDenied: now.addingTimeInterval(-BrowserTabReader.deniedRetryInterval), now: now))
    }

    // MARK: - Goal range

    func test_goalRange_coversEveryStepperValue() {
        XCTAssertEqual(FocusGoal.range, 15...720)
        XCTAssertTrue(FocusGoal.range.contains(GoalDefaults.dailyFocusMinutes))
    }

    // MARK: - Export

    func test_exportOverlap_includesSessionsTouchingTheRange() {
        let from = Date(timeIntervalSince1970: 1_800_000_000)
        let to = from.addingTimeInterval(86_400)
        XCTAssertTrue(DataExporter.overlaps(startedAt: from.addingTimeInterval(-600), endedAt: from.addingTimeInterval(600), from: from, to: to))
        XCTAssertTrue(DataExporter.overlaps(startedAt: from.addingTimeInterval(3600), endedAt: nil, from: from, to: to))
        XCTAssertFalse(DataExporter.overlaps(startedAt: from.addingTimeInterval(-7200), endedAt: from.addingTimeInterval(-3600), from: from, to: to))
        XCTAssertFalse(DataExporter.overlaps(startedAt: to, endedAt: to.addingTimeInterval(600), from: from, to: to))
    }

    func test_exportJSON_filtersSessionsAndUsesTheBundleVersion() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let from = Date(timeIntervalSince1970: 1_800_000_000)
        let to = from.addingTimeInterval(86_400)

        let inside = Session(startedAt: from.addingTimeInterval(3600), label: "inside", status: .completed)
        inside.endedAt = from.addingTimeInterval(7200)
        let before = Session(startedAt: from.addingTimeInterval(-90_000), label: "before", status: .completed)
        before.endedAt = from.addingTimeInterval(-86_400)
        context.insert(inside)
        context.insert(before)
        try context.save()

        let data = try DataExporter.buildJSON(context: context, from: from, to: to,
                                              info: ["CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "97"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["appVersion"] as? String, "2.3.4")
        XCTAssertEqual(root["appBuild"] as? String, "97")
        let labels = (root["sessions"] as? [[String: Any]])?.compactMap { $0["label"] as? String }
        XCTAssertEqual(labels, ["inside"])
    }
}
