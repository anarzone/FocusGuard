import SwiftData
import XCTest
@testable import FocusGuard

/// What each plan opens: every `ProFeature` on Free, the trial and Pro, the
/// trial running out, and the 30 days of history on Free.
@MainActor
final class FlowPlanTests: XCTestCase {
    private struct AcceptingVerifier: LicenceVerifier {
        func verify(_ key: String) async -> LicenceCheck { .valid }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_793_000_000)
    }

    private var defaults: UserDefaults!
    private var suite = ""
    private let clock = Clock()

    override func setUp() {
        suite = "FlowPlanTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func entitlements(verifier: LicenceVerifier = PlaceholderLicenceVerifier()) -> Entitlements {
        let clock = clock
        return Entitlements(defaults: defaults, verifier: verifier, now: { clock.now })
    }

    private func days(_ count: Double) -> TimeInterval { count * 86_400 }

    func testEveryFeatureOnEveryPlan() async {
        let plan = entitlements(verifier: AcceptingVerifier())
        for feature in ProFeature.allCases {
            XCTAssertFalse(plan.isUnlocked(feature), "\(feature) on Free")
            XCTAssertFalse(feature.title.isEmpty)
        }
        XCTAssertEqual(plan.dailyLimitCap, 1)
        XCTAssertNotNil(plan.historyStart())

        plan.startTrialIfNeeded(for: .debrief)
        for feature in ProFeature.allCases { XCTAssertTrue(plan.isUnlocked(feature), "\(feature) on the trial") }
        XCTAssertNil(plan.dailyLimitCap)
        XCTAssertNil(plan.historyStart())
        XCTAssertFalse(plan.canStartTrial)

        // Past the trial: Free again, without waiting for a timer.
        clock.now = clock.now.addingTimeInterval(days(15))
        for feature in ProFeature.allCases { XCTAssertFalse(plan.isUnlocked(feature), "\(feature) after the trial") }
        XCTAssertEqual(plan.dailyLimitCap, 1)
        XCTAssertNotNil(plan.historyStart())
        XCTAssertFalse(plan.canStartTrial, "the trial runs once")

        // A licence opens everything, whenever.
        let result = await plan.activateLicence("FG-TEST")
        XCTAssertEqual(result, .valid)
        for feature in ProFeature.allCases { XCTAssertTrue(plan.isUnlocked(feature), "\(feature) on Pro") }
        XCTAssertEqual(plan.plan, .pro)

        plan.removeLicence()
        XCTAssertEqual(plan.plan, .free)
    }

    func testAnyProFeatureStartsTheSameTrial() {
        for feature in ProFeature.allCases {
            let suite = "FlowPlanTests-\(feature.rawValue)-\(UUID().uuidString)"
            let store = UserDefaults(suiteName: suite)
            defer { store?.removePersistentDomain(forName: suite) }
            let clock = clock
            let plan = Entitlements(defaults: store ?? .standard, now: { clock.now })
            plan.startTrialIfNeeded(for: feature)
            guard case .trial(let endsAt) = plan.plan else { return XCTFail("\(feature) didn't start it") }
            XCTAssertEqual(endsAt, Calendar.current.date(byAdding: .day, value: 14, to: clock.now))
            XCTAssertEqual(plan.plan.daysLeft(at: clock.now), 14)
        }
    }

    func testTheTrialEndsAtItsLastSecondNotAfterIt() {
        let plan = entitlements()
        plan.startTrialIfNeeded(for: .ask)
        guard case .trial(let endsAt) = plan.plan else { return XCTFail("no trial") }
        clock.now = endsAt.addingTimeInterval(-1)
        XCTAssertTrue(plan.isUnlocked(.ask))
        XCTAssertEqual(plan.plan.daysLeft(at: clock.now), 1, "a part day counts as one")
        clock.now = endsAt
        XCTAssertFalse(plan.isUnlocked(.ask))
        plan.refresh()
        XCTAssertEqual(plan.plan, .free)
    }

    func testTheTrialReminderComesTwoDaysBeforeTheEnd() {
        final class Spy: TrialReminding {
            var reminders: [Date] = []
            func presentTrialEndingSoon(endsAt: Date, now: Date) -> Bool {
                reminders.append(endsAt)
                return true
            }
        }
        let spy = Spy()
        let clock = clock
        let plan = Entitlements(defaults: defaults, reminder: spy, now: { clock.now })
        plan.startTrialIfNeeded(for: .coach)
        guard case .trial(let endsAt) = plan.plan else { return XCTFail("no trial") }
        clock.now = endsAt.addingTimeInterval(-days(2) - 60)
        plan.refresh()
        XCTAssertTrue(spy.reminders.isEmpty, "not yet")
        clock.now = endsAt.addingTimeInterval(-days(2))
        plan.refresh()
        XCTAssertEqual(spy.reminders, [endsAt])
        clock.now = endsAt.addingTimeInterval(-days(1))
        plan.refresh()
        XCTAssertEqual(spy.reminders.count, 1, "once")
    }

    func testTheExtensionsPlanFollowsEntitlementsAndAddingItStartsNothing() {
        let plan = entitlements()
        let free = ExtensionBridge.plan(from: plan, now: clock.now)
        XCTAssertFalse(free.pro)
        XCTAssertFalse(free.features.blockInBrowser)
        XCTAssertFalse(free.features.partsOfSites)
        XCTAssertFalse(free.features.youtubePerVideo)
        XCTAssertFalse(free.features.unlimitedLimits)
        XCTAssertNil(free.trialDaysLeft)
        XCTAssertTrue(plan.canStartTrial, "reading the plan for the extension doesn't start the trial")
        XCTAssertEqual(plan.plan, .free)

        plan.startTrialIfNeeded(for: .blockInBrowser)
        let trial = ExtensionBridge.plan(from: plan, now: clock.now)
        XCTAssertTrue(trial.pro)
        XCTAssertTrue(trial.features.blockInBrowser)
        XCTAssertEqual(trial.trialDaysLeft, 14)
    }

    func testThePagesGatesFollowThePlan() {
        XCTAssertFalse(WorkLogAccess.isOpen(shipped: true, unlocked: false))
        XCTAssertTrue(WorkLogAccess.isOpen(shipped: true, unlocked: true))
        XCTAssertFalse(WorkLogAccess.isOpen(shipped: false, unlocked: true))
        XCTAssertFalse(AskAccess.isOpen(shipped: true, unlocked: false))
        XCTAssertTrue(AskAccess.isOpen(shipped: true, unlocked: true))
    }

    // MARK: - Limits per plan

    func testFreeKeepsOneLimitTheTrialAddsMore() {
        let plan = entitlements()
        XCTAssertTrue(LimitGate.canAdd(existing: 0, entitlements: plan))
        XCTAssertFalse(LimitGate.canAdd(existing: 1, entitlements: plan))
        plan.startTrialIfNeeded(for: .unlimitedLimits)
        XCTAssertTrue(LimitGate.canAdd(existing: 40, entitlements: plan))
        clock.now = clock.now.addingTimeInterval(days(20))
        XCTAssertFalse(LimitGate.canAdd(existing: 1, entitlements: plan))
    }

    /// Limits made during the trial, once it's over: the oldest stays in
    /// force, the rest are paused, none deleted.
    func testLimitsMadeOnTheTrialPauseOnFree() throws {
        let plan = entitlements()
        plan.startTrialIfNeeded(for: .unlimitedLimits)
        clock.now = clock.now.addingTimeInterval(days(20))
        XCTAssertEqual(plan.dailyLimitCap, 1)

        let container = try FlowRig.makeContainer()
        let overlay = EscalationEngineTests.StubOverlay()
        let engine = DailyLimitsEngine(context: container.mainContext, notifier: DailyLimitsEngineTests.RecordingNotifier(),
                                       overlay: overlay, policy: { .standard }, activeCap: { plan.dailyLimitCap }, now: clock.now)
        for site in ["one.example", "two.example", "three.example"] {
            XCTAssertNotNil(engine.addLimit(target: site, isSite: true, minutes: 5, now: clock.now))
        }
        XCTAssertEqual(engine.statuses.count, 3, "the engine keeps them all")
        XCTAssertEqual(engine.activeStatuses.map(\.target), ["one.example"])
    }

    // MARK: - History

    func testFreeHistoryIsThirtyDaysCountingToday() throws {
        let calendar = Calendar.fixed("UTC")
        let now = calendar.at(2026, 11, 20, 12)
        clock.now = now
        let plan = entitlements()
        let start = try XCTUnwrap(plan.historyStart(calendar: calendar))
        XCTAssertEqual(start, calendar.at(2026, 10, 22), "today and the 29 days before it")
        XCTAssertEqual(calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day, 29)

        let container = try FlowRig.makeContainer()
        let context = container.mainContext
        // The last day in reach, and the first one out of it.
        ActivityEvent.add(to: context, .focus, from: calendar.at(2026, 10, 22, 9), seconds: 3600)
        ActivityEvent.add(to: context, .focus, from: calendar.at(2026, 10, 21, 9), seconds: 7200)
        // A session on each, too.
        let kept = Session(startedAt: calendar.at(2026, 10, 22, 9), status: .completed)
        kept.endedAt = calendar.at(2026, 10, 22, 10)
        let cut = Session(startedAt: calendar.at(2026, 10, 21, 9), status: .completed)
        cut.endedAt = calendar.at(2026, 10, 21, 10)
        context.insert(kept)
        context.insert(cut)
        try context.save()

        let days = DaySummaries(context: context, now: now, calendar: calendar) {
            DaySummary.make(days: $0, context: context, calendar: calendar)
        }
        let october = ReportsModelBuilder.build(period: .month, offset: 1, context: context, now: now, calendar: calendar,
                                                historyStart: start, goal: { _ in 3600 }, summaries: days)
        XCTAssertEqual(october.data.breakdown.focus, 3600, accuracy: 1, "the day out of reach isn't added")
        XCTAssertEqual(october.data.sessionCount, 1)
        XCTAssertEqual(october.clippedAt, start)
        XCTAssertEqual(october.calendar.flatMap { $0 }.first { $0.date == calendar.at(2026, 10, 21) }?.isLocked, true)
        XCTAssertEqual(october.calendar.flatMap { $0 }.first { $0.date == calendar.at(2026, 10, 22) }?.isLocked, false)

        let unlocked = ReportsModelBuilder.build(period: .month, offset: 1, context: context, now: now, calendar: calendar,
                                                 historyStart: nil, goal: { _ in 3600 })
        XCTAssertEqual(unlocked.data.breakdown.focus, 3 * 3600, accuracy: 1, "with full history it's all there")
    }
}
