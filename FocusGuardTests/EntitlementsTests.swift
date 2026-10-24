import XCTest
@testable import FocusGuard

@MainActor
final class EntitlementsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// A fixed clock in June 2030: no real timer fires during a test, and no
    /// daylight-saving change falls inside a trial.
    private var clock = Date(timeIntervalSince1970: 1_906_566_400)
    private var reminders: RecordingReminder!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "EntitlementsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        reminders = RecordingReminder()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        reminders = nil
        try await super.tearDown()
    }

    private func make(verifier: LicenceVerifier = PlaceholderLicenceVerifier()) -> Entitlements {
        Entitlements(defaults: defaults, verifier: verifier, reminder: reminders, now: { [weak self] in self?.clock ?? .now })
    }

    private func advance(days: Double) {
        clock = clock.addingTimeInterval(days * 86_400)
    }

    private func days(_ n: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: date)!
    }

    // MARK: - Free and the trial

    func testStartsOnFreeWithEveryProFeatureLocked() {
        let entitlements = make()
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertTrue(entitlements.canStartTrial)
        for feature in ProFeature.allCases {
            XCTAssertFalse(entitlements.isUnlocked(feature), "\(feature)")
        }
    }

    func testTurningOnAProFeatureStartsAFourteenDayTrial() {
        let entitlements = make()
        let start = clock
        entitlements.startTrialIfNeeded(for: .debrief)

        XCTAssertEqual(entitlements.plan, .trial(endsAt: days(14, from: start)))
        XCTAssertEqual(entitlements.plan.daysLeft(at: clock), 14)
        XCTAssertFalse(entitlements.canStartTrial)
        for feature in ProFeature.allCases {
            XCTAssertTrue(entitlements.isUnlocked(feature), "\(feature)")
        }
    }

    func testTheTrialRunsOnceAndEndsBackOnFree() {
        let entitlements = make()
        entitlements.startTrialIfNeeded(for: .blockInBrowser)
        advance(days: 14)
        XCTAssertFalse(entitlements.isUnlocked(.blockInBrowser))   // follows the clock before any refresh
        entitlements.refresh()
        XCTAssertEqual(entitlements.plan, .free)

        entitlements.startTrialIfNeeded(for: .coach)
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertFalse(entitlements.canStartTrial)
    }

    func testStartingAgainDuringTheTrialKeepsTheSameEnd() {
        let entitlements = make()
        entitlements.startTrialIfNeeded(for: .debrief)
        let plan = entitlements.plan
        advance(days: 3)
        entitlements.startTrialIfNeeded(for: .workLog)
        XCTAssertEqual(entitlements.plan, plan)
    }

    func testTheTrialSurvivesRelaunch() {
        let start = clock
        make().startTrialIfNeeded(for: .smartCategories)
        advance(days: 5)
        let relaunched = make()
        XCTAssertEqual(relaunched.plan, .trial(endsAt: days(14, from: start)))
        XCTAssertEqual(relaunched.plan.daysLeft(at: clock), 9)
    }

    // MARK: - Reminder

    func testRemindsOnceTwoDaysBeforeTheTrialEnds() {
        let entitlements = make()
        let start = clock
        entitlements.startTrialIfNeeded(for: .debrief)
        advance(days: 11.9)
        entitlements.refresh()
        XCTAssertTrue(reminders.sent.isEmpty)

        advance(days: 0.2)
        entitlements.refresh()
        entitlements.refresh()
        XCTAssertEqual(reminders.sent, [days(14, from: start)])

        make().refresh()   // relaunch
        XCTAssertEqual(reminders.sent.count, 1)
    }

    func testAReminderThatWasMissedGoesOutBeforeTheEnd() {
        let entitlements = make()
        entitlements.startTrialIfNeeded(for: .debrief)
        advance(days: 13.5)   // the Mac was off on day 12
        make().refresh()
        XCTAssertEqual(reminders.sent.count, 1)
    }

    func testNoReminderOnceTheTrialHasEnded() {
        make().startTrialIfNeeded(for: .debrief)
        advance(days: 15)
        make().refresh()
        XCTAssertTrue(reminders.sent.isEmpty)
    }

    func testReminderText() {
        let endsAt = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10))!
        let request = NotificationPresenter.trialEndingSoon(endsAt: endsAt)
        XCTAssertEqual(request.content.title, "Your Pro trial ends in 2 days")
        XCTAssertTrue(request.content.body.contains(endsAt.formatted(.dateTime.day().month(.wide))), request.content.body)
        XCTAssertTrue(request.content.body.contains("November"), request.content.body)
        XCTAssertNil(request.trigger)
    }

    // MARK: - Free limits

    func testFreeHistoryIsThirtyDays() throws {
        let entitlements = make()
        let calendar = Calendar.current
        let start = try XCTUnwrap(entitlements.historyStart(calendar: calendar))
        XCTAssertEqual(start, calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: clock)))
        XCTAssertEqual(calendar.dateComponents([.day], from: start, to: clock).day, 29)

        entitlements.startTrialIfNeeded(for: .fullHistory)
        XCTAssertNil(entitlements.historyStart(calendar: calendar))
    }

    func testFreeHasOneDailyLimit() {
        let entitlements = make()
        XCTAssertEqual(entitlements.dailyLimitCap, 1)
        entitlements.startTrialIfNeeded(for: .unlimitedLimits)
        XCTAssertNil(entitlements.dailyLimitCap)
    }

    // MARK: - Licence

    func testThePlaceholderTurnsDownEveryKey() async {
        let entitlements = make()
        for key in ["ABCD-1234", "PRO", String(repeating: "x", count: 64)] {
            let result = await entitlements.activateLicence(key)
            XCTAssertNotEqual(result, .valid)
        }
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertTrue(entitlements.canStartTrial)
    }

    func testAnEmptyKeyIsTurnedDownWithoutAsking() async {
        let verifier = AcceptingVerifier()
        let result = await make(verifier: verifier).activateLicence("  ")
        XCTAssertEqual(result, .invalid(reason: "Enter a licence key."))
        XCTAssertTrue(verifier.checked.isEmpty)
    }

    func testAGoodKeyUnlocksPro() async {
        let entitlements = make(verifier: AcceptingVerifier())
        let result = await entitlements.activateLicence(" GOOD-KEY \n")
        XCTAssertEqual(result, .valid)
        XCTAssertEqual(entitlements.plan, .pro)
        XCTAssertFalse(entitlements.canStartTrial)
        for feature in ProFeature.allCases {
            XCTAssertTrue(entitlements.isUnlocked(feature), "\(feature)")
        }

        XCTAssertEqual(make(verifier: AcceptingVerifier()).plan, .pro)   // relaunch
        entitlements.removeLicence()
        XCTAssertEqual(entitlements.plan, .free)
    }

    func testRemovingTheLicenceDuringTheTrialGoesBackToTheTrial() async {
        let entitlements = make(verifier: AcceptingVerifier())
        entitlements.startTrialIfNeeded(for: .debrief)
        let trial = entitlements.plan
        _ = await entitlements.activateLicence("GOOD")
        XCTAssertEqual(entitlements.plan, .pro)
        entitlements.removeLicence()
        XCTAssertEqual(entitlements.plan, trial)
    }

    func testASavedKeyThatsNoLongerGoodIsDropped() async {
        defaults.set("OLD-KEY", forKey: "plan.licenceKey")
        let entitlements = make()
        await entitlements.recheckLicence()
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertNil(defaults.string(forKey: "plan.licenceKey"))
    }

    // MARK: - Debug override

    #if DEBUG
    func testDebugOverrideLeavesTheRealPlanAlone() {
        let entitlements = make()
        entitlements.debugOverride = .pro
        XCTAssertEqual(entitlements.plan, .pro)
        XCTAssertTrue(entitlements.isUnlocked(.workLog))
        XCTAssertEqual(make().plan, .pro)   // survives relaunch

        entitlements.debugOverride = .trial(daysLeft: 2)
        XCTAssertEqual(entitlements.plan.daysLeft(at: clock), 2)
        XCTAssertEqual(entitlements.debugOverride, .trial(daysLeft: 2))
        XCTAssertTrue(reminders.sent.isEmpty)

        entitlements.debugOverride = nil
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertTrue(entitlements.canStartTrial)
    }

    func testTrialFromAFreeOverrideIsPretendToo() {
        let entitlements = make()
        entitlements.debugOverride = .free
        XCTAssertTrue(entitlements.canStartTrial)
        entitlements.startTrialIfNeeded(for: .coach)
        XCTAssertEqual(entitlements.debugOverride, .trial(daysLeft: 14))
        XCTAssertTrue(entitlements.isUnlocked(.coach))

        entitlements.debugOverride = nil
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertTrue(entitlements.canStartTrial)   // the real trial is still unused
    }

    func testOverrideFromALaunchArgument() {
        XCTAssertEqual(Entitlements.decodeOverride("pro", now: clock), .pro)
        XCTAssertEqual(Entitlements.decodeOverride("Free", now: clock), .free)
        XCTAssertEqual(Entitlements.decodeOverride("trial", now: clock), .trial(endsAt: clock.addingTimeInterval(14 * 86_400)))
        XCTAssertEqual(Entitlements.decodeOverride("trial:2", now: clock), .trial(endsAt: clock.addingTimeInterval(2 * 86_400)))
        XCTAssertNil(Entitlements.decodeOverride("gold", now: clock))
        XCTAssertNil(Entitlements.decodeOverride(nil, now: clock))
    }
    #endif
}

@MainActor
private final class RecordingReminder: TrialReminding {
    var sent: [Date] = []
    func presentTrialEndingSoon(endsAt: Date) { sent.append(endsAt) }
}

private final class AcceptingVerifier: LicenceVerifier {
    var checked: [String] = []
    func verify(_ key: String) async -> LicenceCheck {
        checked.append(key)
        return .valid
    }
}
