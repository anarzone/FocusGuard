import XCTest
import SwiftData
@testable import FocusGuard

/// Daily limits: counting all day, the warning, blocking, extra time per
/// preset, Strict's changes-from-tomorrow, and the reset at 00:00.
@MainActor
final class DailyLimitsEngineTests: XCTestCase {
    typealias StubOverlay = EscalationEngineTests.StubOverlay

    final class RecordingNotifier: LimitNotifying {
        var warnings: [(name: String, minutesLeft: Int)] = []
        func presentLimitWarning(name: String, minutesLeft: Int, minutesToday: Int) { warnings.append((name, minutesLeft)) }
    }

    private var container: ModelContainer!
    private var context: ModelContext!
    private var overlay: StubOverlay!
    private var notifier: RecordingNotifier!
    private var policy = OverridePolicy.standard
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 24 Oct 2026, 10:00 UTC.
    private let morning = Date(timeIntervalSince1970: 1_792_836_000)

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
        overlay = StubOverlay()
        notifier = RecordingNotifier()
        policy = .standard
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    private func makeEngine(now: Date? = nil) -> DailyLimitsEngine {
        DailyLimitsEngine(context: context, notifier: notifier, overlay: overlay,
                          policy: { [unowned self] in self.policy }, calendar: calendar, now: now ?? morning)
    }

    private func snap(_ url: String?, bundleId: String = "com.apple.Safari", at: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleId, appName: "Safari", windowTitle: nil,
                         url: url, classification: .neutral, observedAt: at)
    }

    /// One tick a second on `url` for `seconds`, starting at `start`.
    private func spend(_ seconds: Int, on url: String?, bundleId: String = "com.apple.Safari",
                       from start: Date, in engine: DailyLimitsEngine) {
        for i in 0...seconds {
            let t = start.addingTimeInterval(TimeInterval(i))
            engine.observe(snapshot: snap(url, bundleId: bundleId, at: t), counting: true, now: t)
        }
    }

    // MARK: - Counting

    func test_countsTimeOnTheSiteAndItsSubdomains() {
        let engine = makeEngine()
        let limit = engine.addLimit(target: "https://www.YouTube.com/watch?v=1", isSite: true, minutes: 30)
        XCTAssertEqual(limit?.target, "youtube.com")

        spend(60, on: "https://m.youtube.com/feed", from: morning, in: engine)
        spend(60, on: "https://notyoutube.com", from: morning.addingTimeInterval(61), in: engine)

        XCTAssertEqual(engine.statuses.first?.used ?? 0, 61, accuracy: 0.5)
    }

    func test_countsAppsByBundleId() {
        let engine = makeEngine()
        engine.addLimit(target: "com.valvesoftware.steam", isSite: false, name: "Steam", minutes: 60)
        spend(30, on: nil, bundleId: "com.valvesoftware.steam", from: morning, in: engine)
        XCTAssertEqual(engine.statuses.first?.used ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(engine.statuses.first?.name, "Steam")
    }

    func test_doesntCountWhileFocusGuardIsFrontOrNobodysThere() {
        let engine = makeEngine()
        engine.addLimit(target: "youtube.com", isSite: true, minutes: 30)
        for i in 0...60 {
            let t = morning.addingTimeInterval(TimeInterval(i))
            engine.observe(snapshot: snap("https://youtube.com", at: t), counting: false, now: t)
        }
        XCTAssertEqual(engine.statuses.first?.used, 0)
    }

    func test_aLongGapBetweenTicksCountsAtMostTwoSeconds() {
        let engine = makeEngine()
        engine.addLimit(target: "youtube.com", isSite: true, minutes: 30)
        engine.observe(snapshot: snap("https://youtube.com", at: morning), counting: true, now: morning)
        let later = morning.addingTimeInterval(3600)
        engine.observe(snapshot: snap("https://youtube.com", at: later), counting: true, now: later)
        XCTAssertEqual(engine.statuses.first?.used, DailyLimitsEngine.maxTickGap)
    }

    func test_readsBackTodaysTimeFromTheStore_atLaunch() {
        let midnight = calendar.startOfDay(for: morning)
        // 10 min yesterday evening running past midnight: only the 5 after it count.
        context.insert(ActivityEvent(startedAt: midnight.addingTimeInterval(-300), endedAt: midnight.addingTimeInterval(300),
                                     bundleIdentifier: "com.apple.Safari", appName: "Safari", url: "https://youtube.com/a"))
        context.insert(ActivityEvent(startedAt: morning.addingTimeInterval(-600), endedAt: morning.addingTimeInterval(-300),
                                     bundleIdentifier: "com.apple.Safari", appName: "Safari", url: "https://www.youtube.com/b"))
        context.insert(ActivityEvent(startedAt: morning.addingTimeInterval(-200), endedAt: morning.addingTimeInterval(-100),
                                     bundleIdentifier: "com.apple.Safari", appName: "Safari", url: "https://x.com"))
        context.insert(DailyLimit(target: "youtube.com", isSite: true, name: "youtube.com", minutes: 30))
        Persistence.save(context)

        let engine = makeEngine()
        XCTAssertEqual(engine.statuses.first?.used ?? 0, 600, accuracy: 0.5)
    }

    func test_aLimitAddedMidDay_countsTheEarlierTimeToday() {
        context.insert(ActivityEvent(startedAt: morning.addingTimeInterval(-1200), endedAt: morning.addingTimeInterval(-600),
                                     bundleIdentifier: "com.apple.Safari", appName: "Safari", url: "https://reddit.com/r/x"))
        Persistence.save(context)
        let engine = makeEngine()
        engine.addLimit(target: "reddit.com", isSite: true, minutes: 15, now: morning)
        XCTAssertEqual(engine.statuses.first?.used ?? 0, 600, accuracy: 0.5)
    }

    // MARK: - Warning and block

    func test_warnsOnceFiveMinutesBeforeTheEnd() {
        let engine = makeEngine()
        engine.addLimit(target: "youtube.com", isSite: true, minutes: 10)
        spend(299, on: "https://youtube.com", from: morning, in: engine)
        XCTAssertTrue(notifier.warnings.isEmpty)
        spend(30, on: "https://youtube.com", from: morning.addingTimeInterval(300), in: engine)
        XCTAssertEqual(notifier.warnings.count, 1)
        XCTAssertEqual(notifier.warnings.first?.name, "youtube.com")
        XCTAssertEqual(notifier.warnings.first?.minutesLeft, 5)
    }

    func test_blocksWhenTheLimitRunsOut() {
        let engine = makeEngine()
        let limit = engine.addLimit(target: "youtube.com", isSite: true, minutes: 1)
        spend(59, on: "https://youtube.com", from: morning, in: engine)
        XCTAssertFalse(overlay.presented)
        spend(2, on: "https://youtube.com", from: morning.addingTimeInterval(60), in: engine)
        XCTAssertTrue(overlay.presented)
        guard case .dailyLimit(let block) = overlay.current?.reason else { return XCTFail("not a limit block") }
        XCTAssertEqual(block.limitID, limit?.id)
        XCTAssertEqual(block.minutesToday, 1)
        XCTAssertEqual(block.extraLeft, 1)
        XCTAssertTrue(engine.statuses.first?.isUsedUp == true)
    }

    func test_otherSitesStayOpen() {
        let engine = makeEngine()
        engine.addLimit(target: "youtube.com", isSite: true, minutes: 1)
        spend(70, on: "https://youtube.com", from: morning, in: engine)
        overlay.dismiss()
        spend(5, on: "https://github.com", from: morning.addingTimeInterval(80), in: engine)
        XCTAssertFalse(overlay.presented)
    }

    // MARK: - Extra time

    func test_gentle_givesFiveMinutesUpToThreeTimes() throws {
        policy = .gentle
        let engine = makeEngine()
        let id = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 10)?.id)
        XCTAssertTrue(engine.takeExtraTime(for: id))
        XCTAssertTrue(engine.takeExtraTime(for: id))
        XCTAssertTrue(engine.takeExtraTime(for: id))
        XCTAssertFalse(engine.takeExtraTime(for: id))
        XCTAssertEqual(engine.status(for: id)?.allowance, 25 * 60)
        XCTAssertEqual(engine.status(for: id)?.extraLeft, 0)
    }

    func test_standard_givesFiveMinutesOnce() throws {
        let engine = makeEngine()
        let id = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 10)?.id)
        XCTAssertTrue(engine.takeExtraTime(for: id))
        XCTAssertFalse(engine.takeExtraTime(for: id))
        XCTAssertEqual(engine.status(for: id)?.allowance, 15 * 60)
    }

    func test_strict_givesNoExtraTime() throws {
        policy = .strict
        let engine = makeEngine()
        let id = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 10)?.id)
        XCTAssertFalse(engine.takeExtraTime(for: id))
        XCTAssertEqual(engine.status(for: id)?.extraLeft, 0)
    }

    func test_extraTimeFromTheBlockScreen_opensTheSiteAgain() {
        let engine = makeEngine()
        engine.addLimit(target: "youtube.com", isSite: true, minutes: 1)
        spend(61, on: "https://youtube.com", from: morning, in: engine)
        guard case .dailyLimit(let block) = overlay.current?.reason else { return XCTFail("not a limit block") }
        overlay.dismiss()
        overlay.onExtraTime?(block.limitID)

        spend(60, on: "https://youtube.com", from: morning.addingTimeInterval(62), in: engine)
        XCTAssertFalse(overlay.presented)
        XCTAssertEqual(engine.statuses.first?.remaining ?? 0, 4 * 60 - 1, accuracy: 2)
    }

    func test_extraTimeTakenSurvivesARelaunch() throws {
        let first = makeEngine()
        let id = try XCTUnwrap(first.addLimit(target: "youtube.com", isSite: true, minutes: 10)?.id)
        XCTAssertTrue(first.takeExtraTime(for: id))
        let second = makeEngine(now: morning.addingTimeInterval(60))
        XCTAssertFalse(second.takeExtraTime(for: id))
        XCTAssertEqual(second.status(for: id)?.extraMinutes, 5)
    }

    // MARK: - Midnight

    func test_resetsAtMidnight() throws {
        let engine = makeEngine()
        let id = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 1)?.id)
        let evening = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: morning)!
        spend(61, on: "https://youtube.com", from: evening, in: engine)
        overlay.dismiss()
        XCTAssertTrue(engine.takeExtraTime(for: id))
        spend(400, on: "https://youtube.com", from: evening.addingTimeInterval(62), in: engine)
        XCTAssertTrue(overlay.presented, "blocked again once the extra time is used")

        let afterMidnight = calendar.startOfDay(for: morning).addingTimeInterval(24 * 3600 + 1)
        engine.observe(snapshot: snap("https://youtube.com", at: afterMidnight), counting: true, now: afterMidnight)
        XCTAssertFalse(overlay.presented, "the limit's block comes down at 00:00")
        XCTAssertEqual(engine.status(for: id)?.used ?? 99, 0, accuracy: 1)
        XCTAssertEqual(engine.status(for: id)?.extraMinutes, 0)
        XCTAssertEqual(engine.status(for: id)?.extraLeft, 1)
    }

    func test_warnsAgainTheNextDay() {
        let engine = makeEngine()
        engine.addLimit(target: "youtube.com", isSite: true, minutes: 5)
        spend(3, on: "https://youtube.com", from: morning, in: engine)
        let tomorrow = morning.addingTimeInterval(24 * 3600)
        spend(3, on: "https://youtube.com", from: tomorrow, in: engine)
        XCTAssertEqual(notifier.warnings.count, 2)
    }

    // MARK: - Changing limits

    func test_changesApplyNow_onGentleAndStandard() throws {
        let engine = makeEngine()
        let id = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 10)?.id)
        XCTAssertEqual(engine.setMinutes(20, for: id), .now)
        XCTAssertEqual(engine.status(for: id)?.minutes, 20)
        XCTAssertEqual(engine.removeLimit(id), .now)
        XCTAssertTrue(engine.statuses.isEmpty)
    }

    func test_strict_changesWaitForTomorrow() throws {
        policy = .strict
        let engine = makeEngine()
        let raise = try XCTUnwrap(engine.addLimit(target: "youtube.com", isSite: true, minutes: 10)?.id)
        let drop = try XCTUnwrap(engine.addLimit(target: "reddit.com", isSite: true, minutes: 10)?.id)

        XCTAssertEqual(engine.setMinutes(60, for: raise), .fromTomorrow)
        XCTAssertEqual(engine.removeLimit(drop), .fromTomorrow)
        XCTAssertEqual(engine.status(for: raise)?.minutes, 10)
        XCTAssertEqual(engine.status(for: raise)?.pending, .minutes(60))
        XCTAssertEqual(engine.status(for: drop)?.pending, .removal)

        let tomorrow = morning.addingTimeInterval(24 * 3600)
        engine.observe(snapshot: nil, counting: true, now: tomorrow)
        XCTAssertEqual(engine.status(for: raise)?.minutes, 60)
        XCTAssertNil(engine.status(for: raise)?.pending)
        XCTAssertNil(engine.status(for: drop))
    }

    func test_strict_changesSavedForTomorrow_applyAtLaunchTheNextDay() throws {
        policy = .strict
        let first = makeEngine()
        let id = try XCTUnwrap(first.addLimit(target: "youtube.com", isSite: true, minutes: 10)?.id)
        first.setMinutes(45, for: id)
        let nextDay = makeEngine(now: morning.addingTimeInterval(24 * 3600))
        XCTAssertEqual(nextDay.status(for: id)?.minutes, 45)
    }

    func test_addingTheSameSiteAgain_changesTheExistingLimit() {
        let engine = makeEngine()
        let first = engine.addLimit(target: "youtube.com", isSite: true, minutes: 10)
        let second = engine.addLimit(target: "www.youtube.com", isSite: true, minutes: 20)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(engine.statuses.count, 1)
        XCTAssertEqual(engine.statuses.first?.minutes, 20)
    }

    func test_rejectsNonsense() {
        let engine = makeEngine()
        XCTAssertNil(engine.addLimit(target: "not a site", isSite: true, minutes: 10))
        XCTAssertNil(engine.addLimit(target: "youtube.com", isSite: true, minutes: 0))
        XCTAssertNil(engine.addLimit(target: "", isSite: false, minutes: 10))
    }

    func test_siteTarget() {
        XCTAssertEqual(DailyLimitsEngine.siteTarget("https://www.YouTube.com/watch?v=1"), "youtube.com")
        XCTAssertEqual(DailyLimitsEngine.siteTarget("m.youtube.com/"), "m.youtube.com")
        XCTAssertEqual(DailyLimitsEngine.siteTarget(" reddit.com "), "reddit.com")
        XCTAssertNil(DailyLimitsEngine.siteTarget("localhost"))
    }
}
