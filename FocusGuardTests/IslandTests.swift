import UserNotifications
import XCTest
@testable import FocusGuard

/// The focus island: when a moment shows, what it says, and that its buttons
/// send the same commands as the macOS notification's. A fake clock and a fake
/// surface: nothing here puts anything on screen.
@MainActor
final class IslandTests: XCTestCase {
    private final class FakeSurface: IslandSurface {
        var shown: [IslandMoment] = []
        var openWhenShown: [Bool] = []
        var updates: [IslandMoment] = []
        var lastOpen = false
        var hides = 0
        var announced: [String] = []
        var urgent: [Bool] = []

        func attach(_ island: IslandController) {}
        func show(_ moment: IslandMoment, open: Bool, now: Date) {
            shown.append(moment)
            openWhenShown.append(open)
            lastOpen = open
        }
        func update(_ moment: IslandMoment, open: Bool, now: Date) {
            updates.append(moment)
            lastOpen = open
        }
        func hide() { hides += 1 }
        func announce(_ text: String, urgent: Bool) {
            announced.append(text)
            self.urgent.append(urgent)
        }
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
    private var now = Date(timeIntervalSinceReferenceDate: 815_000_000)
    private var conditions = IslandConditions(now: .now)
    private var surface = FakeSurface()
    private var performed: [NotificationCommand] = []
    private var sounds: [IslandKind] = []
    private var sent: [UNNotificationRequest] = []
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var island: IslandController!
    private var presenter: NotificationPresenter!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "IslandTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(50, forKey: SessionDefaultsKey.durationMinutes)
        // 10:00 UTC on a Wednesday.
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10)) ?? now
        conditions = IslandConditions(now: now, frontApp: "com.example.code")
        surface = FakeSurface()
        performed = []
        sounds = []
        sent = []
        island = IslandController(surface: surface, clock: { [unowned self] in self.now }, defaults: defaults,
                                  calendar: calendar, runsTimer: false)
        island.conditions = { [unowned self] in
            var conditions = self.conditions
            conditions.now = self.now
            return conditions
        }
        island.perform = { [unowned self] in self.performed.append($0) }
        island.playSound = { [unowned self] in self.sounds.append($0) }
        presenter = NotificationPresenter(defaults: defaults, send: { [unowned self] in self.sent.append($0) }, register: { _ in })
        presenter.island = island
        island.isAllowed = { [unowned self] in self.presenter.islandAllows($0) }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        island = nil
        presenter = nil
        try await super.tearDown()
    }

    private func moment(_ kind: IslandKind, key: String? = nil, buttons: [IslandButton] = [],
                        startsOpen: Bool = false, requested: Bool = false, expiresAt: Date? = nil) -> IslandMoment {
        IslandMoment(kind: kind, key: key ?? "\(kind)", pillName: "\(kind)", kicker: "k", title: "\(kind)", body: "b",
                     buttons: buttons, startsOpen: startsOpen, requested: requested, expiresAt: expiresAt)
    }

    private func wait(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        island.tick()
    }

    private var currentKind: IslandKind? { island.queue.current?.moment.kind }

    // MARK: - Showing at once, or at a pause

    func testOnlyTheNudgeAndTheLimitShowAtOnce() {
        for kind in IslandKind.allCases where kind != .pickUp && kind != .sample {
            XCTAssertEqual(IslandRules.timing(kind).atOnce, kind == .drift || kind == .limit, "\(kind)")
        }
        island.post(moment(.drift))
        XCTAssertEqual(currentKind, .drift)
    }

    func testAnythingElseWaitsForAPause() {
        island.post(moment(.trial))
        XCTAssertNil(currentKind)
        wait(10)
        XCTAssertNil(currentKind)
    }

    func testAnAppSwitchIsAPause() {
        island.post(moment(.trial))
        wait(1)
        XCTAssertNil(currentKind)
        conditions.frontApp = "com.example.browser"
        wait(1)
        XCTAssertEqual(currentKind, .trial)
    }

    func testAFrontAppFromBeforeItArrivedIsNoPause() {
        island.post(moment(.drift))
        island.closeCurrent()
        conditions.frontApp = "com.example.browser"
        wait(60)
        // Nothing looks at the front app while the queue is empty.
        now = now.addingTimeInterval(60)
        island.post(moment(.trial))
        XCTAssertNil(currentKind)
    }

    func testAFewSecondsWithNoInputIsAPause() {
        island.post(moment(.trial))
        conditions.idleSeconds = IslandRules.idleForPause - 1
        wait(1)
        XCTAssertNil(currentKind)
        conditions.idleSeconds = IslandRules.idleForPause
        wait(1)
        XCTAssertEqual(currentKind, .trial)
    }

    func testASessionOrBreakEndingIsAPause() {
        island.post(moment(.sessionFinished, startsOpen: true))
        XCTAssertNil(currentKind)
        island.notePause()
        XCTAssertEqual(currentKind, .sessionFinished)
    }

    func testWaitsNoLongerThanItsMaximum() {
        for kind in IslandKind.allCases where !IslandRules.timing(kind).atOnce {
            setUpIslandAgain()
            island.post(moment(kind))
            let maxWait = IslandRules.timing(kind).maxWait
            // The morning plan arrives at 10:00, so its wait is under the half to midday.
            wait(maxWait - 1)
            XCTAssertNil(currentKind, "\(kind)")
            wait(1)
            XCTAssertEqual(currentKind, kind, "\(kind)")
        }
    }

    private func setUpIslandAgain() {
        island = IslandController(surface: surface, clock: { [unowned self] in self.now }, defaults: defaults,
                                  calendar: calendar, runsTimer: false)
        island.conditions = { [unowned self] in
            var conditions = self.conditions
            conditions.now = self.now
            return conditions
        }
    }

    func testEveryMaximumWaitIsShorterThanItsExpiry() {
        for kind in IslandKind.allCases where !IslandRules.timing(kind).atOnce {
            let timing = IslandRules.timing(kind)
            XCTAssertLessThan(timing.maxWait, timing.expiry, "\(kind)")
            XCTAssertLessThanOrEqual(timing.maxWait, 30 * 60, "\(kind) would show too late")
        }
        XCTAssertLessThanOrEqual(IslandRules.timing(.plannedSession).maxWait, 2 * 60)
    }

    func testAWaitingGapFollowsOneClosing() {
        island.post(moment(.drift))
        island.post(moment(.trial))
        island.closeCurrent()
        conditions.idleSeconds = 10
        island.tick()
        XCTAssertNil(currentKind)
        wait(IslandRules.gapBetween)
        XCTAssertEqual(currentKind, .trial)
    }

    // MARK: - Priority

    func testHigherReplacesLowerWhichGoesBackInTheQueue() {
        island.post(moment(.trial))
        conditions.idleSeconds = 10
        island.tick()
        XCTAssertEqual(currentKind, .trial)

        island.post(moment(.limit))
        XCTAssertEqual(currentKind, .limit)
        XCTAssertEqual(island.queue.waiting.map(\.moment.kind), [.trial])

        island.post(moment(.drift))
        XCTAssertEqual(currentKind, .drift)
        XCTAssertEqual(Set(island.queue.waiting.map { "\($0.moment.kind)" }), ["trial", "limit"])
    }

    func testLowerDoesNotReplaceHigher() {
        island.post(moment(.drift))
        conditions.idleSeconds = 10
        island.post(moment(.sessionFinished))
        island.post(moment(.morningPlan))
        XCTAssertEqual(currentKind, .drift)
        XCTAssertEqual(island.queue.waiting.count, 2)
    }

    func testTheOrderIsDriftLimitSessionThenTheRest() {
        XCTAssertLessThan(IslandRules.rank(.drift), IslandRules.rank(.limit))
        XCTAssertLessThan(IslandRules.rank(.limit), IslandRules.rank(.sessionFinished))
        for kind in IslandKind.allCases where ![.drift, .limit, .sessionFinished, .sample].contains(kind) {
            XCTAssertLessThan(IslandRules.rank(.sessionFinished), IslandRules.rank(kind), "\(kind)")
        }
    }

    func testAReplacedOneComesBackIfItStillMatters() {
        island.post(moment(.trial))
        conditions.idleSeconds = 10
        island.tick()
        island.post(moment(.limit))
        island.closeCurrent()
        wait(IslandRules.gapBetween)
        XCTAssertEqual(currentKind, .trial)
    }

    // MARK: - Repeats

    func testARepeatUpdatesInPlace() {
        island.post(moment(.drift, key: "nudge"))
        var repeated = moment(.drift, key: "nudge")
        repeated.title = "Still on reddit.com?"
        island.post(repeated)
        XCTAssertEqual(surface.shown.count, 1)
        XCTAssertEqual(surface.announced.count, 1)
        XCTAssertEqual(island.queue.current?.moment.title, "Still on reddit.com?")
        XCTAssertEqual(surface.updates.last?.title, "Still on reddit.com?")
    }

    func testARepeatWhileWaitingKeepsItsPlaceAndArrival() {
        island.post(moment(.trial))
        wait(100)
        island.post(moment(.trial))
        XCTAssertEqual(island.queue.waiting.count, 1)
        wait(IslandRules.timing(.trial).maxWait - 100)
        XCTAssertEqual(currentKind, .trial)
    }

    func testARepeatedCountdownKeepsTheRingsLength() {
        let ends = now.addingTimeInterval(60)
        var first = moment(.drift, key: "nudge")
        first.countdown = IslandCountdown(ends: ends, total: 60)
        island.post(first)
        now = now.addingTimeInterval(30)
        var second = first
        second.countdown = IslandCountdown(ends: ends, total: 30)
        island.post(second)
        XCTAssertEqual(island.queue.current?.moment.countdown?.total, 60)
        XCTAssertEqual(island.queue.current?.moment.shownFill(at: now), 0.5)
    }

    // MARK: - Expiry

    func testHeldPastItsExpiryItNeverShows() {
        conditions.inCall = true
        island.post(moment(.plannedSession))
        wait(IslandRules.timing(.plannedSession).expiry)
        conditions.inCall = false
        wait(1)
        XCTAssertNil(currentKind)
        XCTAssertTrue(island.queue.isEmpty)
    }

    func testTheMorningPlanGoesAtMidday() {
        conditions.inCall = true
        island.post(moment(.morningPlan))
        now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        conditions.inCall = false
        island.tick()
        XCTAssertNil(currentKind)
    }

    func testTheMorningPlanJustBeforeMiddayStillShows() {
        now = calendar.date(bySettingHour: 11, minute: 50, second: 0, of: now) ?? now
        island.post(moment(.morningPlan))
        wait(5 * 60)
        XCTAssertEqual(currentKind, .morningPlan)
    }

    func testTheWrapUpGoesAtMidnight() {
        now = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now
        let expires = IslandRules.expiry(of: moment(.wrapUp), arrived: now, calendar: calendar)
        XCTAssertEqual(expires, calendar.date(byAdding: .hour, value: 1, to: now))
    }

    func testAMomentsOwnExpiryWins() {
        let expires = now.addingTimeInterval(20)
        conditions.inCall = true
        island.post(moment(.limit, expiresAt: expires))
        wait(21)
        conditions.inCall = false
        wait(1)
        XCTAssertNil(currentKind)
    }

    func testItLeavesAfterItsTimeOnScreen() throws {
        island.post(moment(.limit))
        let shown = try XCTUnwrap(IslandRules.timing(.limit).onScreen)
        wait(shown - 1)
        XCTAssertEqual(currentKind, .limit)
        wait(1)
        XCTAssertNil(currentKind)
        XCTAssertEqual(surface.hides, 1)
    }

    // MARK: - Quiet

    func testNothingShowsDuringACallAndItComesBackAfter() {
        conditions.inCall = true
        island.post(moment(.drift))
        XCTAssertNil(currentKind)
        conditions.inCall = false
        wait(1)
        XCTAssertEqual(currentKind, .drift)
    }

    func testACallHidesWhatsUpAndItReturns() {
        island.post(moment(.limit))
        XCTAssertEqual(currentKind, .limit)
        conditions.inCall = true
        wait(1)
        XCTAssertNil(currentKind)
        XCTAssertEqual(surface.hides, 1)
        conditions.inCall = false
        wait(1)
        XCTAssertEqual(currentKind, .limit)
    }

    func testABlockScreenHoldsEverything() {
        conditions.screenUp = true
        island.post(moment(.drift))
        island.post(moment(.sample, requested: true))
        XCTAssertNil(currentKind)
    }

    func testLockedOrAsleepHoldsAndExpiryStillApplies() {
        conditions.isAsleepOrLocked = true
        island.post(moment(.driftPrompt))
        wait(5 * 60)
        XCTAssertNil(currentKind)
        wait(IslandRules.timing(.driftPrompt).expiry)
        conditions.isAsleepOrLocked = false
        wait(1)
        XCTAssertNil(currentKind)
    }

    func testAwayHoldsUntilTheUserIsBack() {
        conditions.isAway = true
        island.post(moment(.trial))
        wait(IslandRules.timing(.trial).maxWait)
        XCTAssertNil(currentKind)
        conditions.isAway = false
        wait(1)
        XCTAssertEqual(currentKind, .trial)
    }

    func testTheEndOfAQuietTimeIsAPause() {
        conditions.screenUp = true
        island.post(moment(.breakOver))
        wait(1)
        conditions.screenUp = false
        wait(1)
        XCTAssertEqual(currentKind, .breakOver)
    }

    func testWhatTheUserAskedForStaysThroughACallButNotABlockScreen() {
        conditions.inCall = true
        island.post(moment(.pickUp, requested: true))
        XCTAssertEqual(currentKind, .pickUp)
        conditions.screenUp = true
        wait(1)
        XCTAssertNil(currentKind)
    }

    func testANudgeGoesWhenTheDriftStops() {
        island.post(moment(.drift))
        conditions.isDrifting = false
        wait(1)
        XCTAssertNil(currentKind)
        XCTAssertTrue(island.queue.isEmpty)
    }

    // MARK: - Hover

    func testHoverOpensAndLeavingShrinks() {
        island.post(moment(.drift))
        XCTAssertEqual(surface.openWhenShown, [false])
        island.hover(true)
        XCTAssertTrue(surface.lastOpen)
        island.hover(false)
        XCTAssertFalse(surface.lastOpen)
    }

    func testASessionFinishedOpensByItselfAndStaysOpen() {
        island.post(moment(.sessionFinished, startsOpen: true))
        island.notePause()
        XCTAssertEqual(surface.openWhenShown, [true])
        island.hover(true)
        island.hover(false)
        XCTAssertTrue(surface.lastOpen)
    }

    func testHoverPausesItsTimeOnScreen() throws {
        island.post(moment(.limit))
        let shown = try XCTUnwrap(IslandRules.timing(.limit).onScreen)
        wait(shown - 2)
        island.hover(true)
        wait(shown * 3)
        XCTAssertEqual(currentKind, .limit)
        island.hover(false)
        wait(1)
        XCTAssertEqual(currentKind, .limit, "It still has its two seconds, and more")
        wait(IslandRules.afterHover)
        XCTAssertNil(currentKind)
    }

    func testAClickOpensThePillUntilThePointerLeaves() {
        island.post(moment(.limit))
        island.openByHand()
        XCTAssertTrue(surface.lastOpen)
        wait(30)
        XCTAssertEqual(currentKind, .limit)
    }

    func testReduceMotionCrossFades() {
        XCTAssertEqual(IslandMotion.choose(reduceMotion: true), .crossFade)
        XCTAssertEqual(IslandMotion.choose(reduceMotion: false), .spring)
    }

    // MARK: - Which surface

    func testCardsAreTheDefaultAndNothingGoesToMacOS() {
        presenter.presentBreakOver()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(island.queue.waiting.first?.moment.kind, .breakOver)
    }

    func testWithMacOSNotificationsItIsAsBefore() {
        defaults.set(IslandSettings.Surface.macOS.rawValue, forKey: IslandSettings.surface)
        presenter.presentBreakOver()
        presenter.presentDistractionWarning(appName: "Chrome", currentURL: nil)
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(island.queue.isEmpty)
    }

    func testSwitchingToMacOSDropsWhatsWaiting() {
        presenter.presentBreakOver()
        defaults.set(IslandSettings.Surface.macOS.rawValue, forKey: IslandSettings.surface)
        island.tick()
        XCTAssertTrue(island.queue.isEmpty)
    }

    func testTheMasterSwitchesCountOnBothSurfaces() {
        for surfaceKind in IslandSettings.Surface.allCases {
            setUp(surfaceKind: surfaceKind)
            defaults.set(false, forKey: SettingsKeys.showNotifications)
            presenter.presentBreakOver()
            presenter.presentDistractionWarning(appName: "Chrome", currentURL: nil)
            XCTAssertTrue(sent.isEmpty, "\(surfaceKind)")
            XCTAssertTrue(island.queue.isEmpty, "\(surfaceKind)")

            defaults.set(true, forKey: SettingsKeys.showNotifications)
            defaults.set(false, forKey: SettingsKeys.Escalation.notificationsEnabled)
            presenter.presentDistractionWarning(appName: "Chrome", currentURL: nil)
            XCTAssertTrue(sent.isEmpty, "\(surfaceKind)")
            XCTAssertNil(currentKind, "\(surfaceKind)")
            presenter.presentBreakOver()
            XCTAssertEqual(sent.count + island.queue.waiting.count, 1, "\(surfaceKind)")
        }
    }

    private func setUp(surfaceKind: IslandSettings.Surface) {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(surfaceKind.rawValue, forKey: IslandSettings.surface)
        sent = []
        setUpIslandAgain()
        island.isAllowed = { [unowned self] in self.presenter.islandAllows($0) }
        presenter.island = island
    }

    func testSwitchingTheMasterOffDropsWhatsWaiting() {
        presenter.presentBreakOver()
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        island.tick()
        XCTAssertTrue(island.queue.isEmpty)
    }

    func testTheSampleIsARealCardWhoseButtonsOnlyClose() throws {
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        presenter.presentSampleCard(now: now)
        XCTAssertEqual(currentKind, .sample)
        let buttons = try XCTUnwrap(island.queue.current?.moment.buttons)
        XCTAssertEqual(buttons.count, 2)
        XCTAssertTrue(buttons.allSatisfy { $0.command == nil })
    }

    func testTheSampleIsANotificationWithMacOSChosen() {
        defaults.set(IslandSettings.Surface.macOS.rawValue, forKey: IslandSettings.surface)
        presenter.presentSampleCard(now: now)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(island.queue.isEmpty)
    }

    // MARK: - Every kind and its buttons

    /// Who says what: each card has the notification's buttons with the
    /// commands `NotificationCommand` works out for them, and the ones that
    /// only close the card.
    func testEveryKindSendsTheNotificationsCommands() throws {
        let slot = now.addingTimeInterval(3600)
        let tip = EveningTip(kind: .driftHour, text: "Tip", slot: slot, button: "Plan it for 15:00")
        let since = now.addingTimeInterval(-300)
        let plan = MorningPlan(slots: [slot], sessionMinutes: 25, goalMinutes: 240, focusedMinutes: 0, fromCalendar: false)
        let wrapUp = EveningWrapUp(focusedMinutes: 100, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil)
        let tipped = EveningWrapUp(focusedMinutes: 100, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil, tip: tip)
        presenter.nudgeContext = { NudgeContext(sessionName: "Evening", minutesLeft: 18, backTo: "Xcode", bundleId: "com.x") }

        let cases: [(IslandKind, () -> Void, [NotificationCommand?])] = [
            (.drift, { self.presenter.presentDistractionWarning(appName: "Chrome", currentURL: "https://x.com/a") },
             [.backToWork, .allowForSession(url: "https://x.com/a", bundleId: "com.x")]),
            (.sessionFinished, { self.presenter.presentSessionComplete(name: "Run", minutes: 50, focusPercent: 88, zoneMinutes: 34, breakMinutes: 10) },
             [.takeBreak(minutes: 10), .startSession(minutes: 50)]),
            (.breakOver, { self.presenter.presentBreakOver() }, [.startSession(minutes: 50), .takeBreak(minutes: 5)]),
            (.driftPrompt, { self.presenter.presentDriftPrompt(host: "reddit.com") }, [.startSession(minutes: 25), nil]),
            (.limit, { self.presenter.presentLimitWarning(name: "reddit.com", minutesLeft: 5, minutesToday: 30) }, [.openToday, nil]),
            (.morningPlan, { self.presenter.presentMorningPlan(plan) }, [.planSessions([slot]), nil]),
            (.plannedSession, { self.presenter.presentPlannedSession(at: slot, minutes: 25) },
             [.startSession(minutes: 25), .skipPlannedSession(at: slot)]),
            (.autoStart, { self.presenter.presentAutoStartOffer(AutoStartOffer(since: since, appNames: ["Xcode"], bundleId: nil), now: self.now) },
             [.startFromOffer(since: since, minutes: 50), .snoozeAutoStart]),
            (.wrapUp, { self.presenter.presentEveningWrapUp(wrapUp) }, [.openToday, nil]),
            (.wrapUp, { self.presenter.presentEveningWrapUp(tipped) }, [.planSessions([slot]), nil]),
            (.trial, { self.presenter.presentTrialEndingSoon(endsAt: slot) }, [.openPlans, nil])
        ]
        for (kind, present, commands) in cases {
            setUpIslandAgain()
            presenter.island = island
            present()
            let waiting = island.queue.current ?? island.queue.waiting.first
            let moment = try XCTUnwrap(waiting?.moment, "\(kind)")
            XCTAssertEqual(moment.kind, kind)
            XCTAssertEqual(moment.buttons.map(\.command), commands, "\(kind)")
            XCTAssertTrue(moment.buttons.allSatisfy { !$0.title.isEmpty }, "\(kind)")
        }
    }

    func testAnAnalyzerReminderReachesTheIsland() {
        let request = NotificationPresenter.request(title: "Your plan", body: "If it's 15:00, start a session.")
        presenter.deliver(request, as: .general)
        let moment = island.queue.waiting.first?.moment
        XCTAssertEqual(moment?.kind, .reminder)
        XCTAssertEqual(moment?.body, "If it's 15:00, start a session.")
        XCTAssertEqual(moment?.buttons.map(\.command), [nil])
    }

    func testAButtonSendsItsCommandAndCloses() throws {
        presenter.presentLimitWarning(name: "reddit.com", minutesLeft: 5, minutesToday: 30)
        let button = try XCTUnwrap(island.queue.current?.moment.buttons.first)
        island.press(button)
        XCTAssertEqual(performed, [.startSession(minutes: nil)])
        XCTAssertNil(currentKind)
    }

    func testACloseOnlyButtonSendsNothing() throws {
        presenter.presentLimitWarning(name: "reddit.com", minutesLeft: 5, minutesToday: 30)
        let button = try XCTUnwrap(island.queue.current?.moment.buttons.last)
        island.press(button)
        XCTAssertTrue(performed.isEmpty)
        XCTAssertNil(currentKind)
    }

    // MARK: - The nudge's countdown

    func testTheCountdownIsTheEnginesRealBlockTime() {
        final class Notifier: DistractionNotifier {
            func presentDistractionWarning(appName: String, currentURL: String?) {}
        }
        final class Overlay: BlockOverlayPresenting {
            var isPresenting = false
            var current: BlockRequest?
            var onOverride: (() -> Void)?
            var onExtraTime: ((UUID) -> Void)?
            func present(_ request: BlockRequest) {}
            func dismiss() {}
        }
        let engine = EscalationEngine(presenter: Notifier(), overlay: Overlay())
        engine.blockThreshold = 90
        XCTAssertNil(engine.blockDeadline(at: now))
        engine.observe(snapshot: ActivitySnapshot(bundleIdentifier: "a", appName: "A", windowTitle: nil, url: nil,
                                                  classification: .distraction, observedAt: now), isInSession: true)
        XCTAssertEqual(engine.blockDeadline(at: now), now.addingTimeInterval(90))
    }

    func testTheNudgeTicksDownAndTheRingEmpties() throws {
        let context = NudgeContext(sessionName: "Evening focus", minutesLeft: 18, backTo: "Xcode", bundleId: nil,
                                   blockAt: now.addingTimeInterval(60), presetName: "Standard")
        let moment = presenter.driftMoment(place: "x.com", body: "", context: context, now: now)
        let countdown = try XCTUnwrap(moment.countdown)
        XCTAssertEqual(moment.shownPillValue(at: now), "1:00")
        XCTAssertEqual(moment.shownPillValue(at: now.addingTimeInterval(2)), "0:58")
        XCTAssertEqual(moment.shownValue(at: now.addingTimeInterval(59)), "0:01")
        XCTAssertEqual(moment.shownFill(at: now), 1)
        XCTAssertEqual(moment.shownFill(at: now.addingTimeInterval(30)), 0.5, accuracy: 0.01)
        XCTAssertEqual(moment.shownFill(at: now.addingTimeInterval(90)), 0)
        XCTAssertEqual(moment.expiresAt, countdown.ends)
        XCTAssertEqual(moment.title, "Still on x.com?")
        XCTAssertEqual(moment.kicker, "Evening focus · 18 min left")
        XCTAssertEqual(moment.body, "Your Standard preset blocks it when this runs out.")
    }

    func testNoBlockComingMeansNoCountdown() {
        let context = NudgeContext(sessionName: "Evening", minutesLeft: nil, backTo: nil, bundleId: nil)
        let moment = presenter.driftMoment(place: "x.com", body: "Evening is still running.", context: context, now: now)
        XCTAssertNil(moment.countdown)
        XCTAssertEqual(moment.shownPillValue(at: now), "Drifting?")
        XCTAssertEqual(moment.body, "Evening is still running.")
    }

    func testANudgeNamesTheSiteNotThePage() {
        presenter.presentDistractionWarning(appName: "Google Chrome", currentURL: "https://www.x.com/someone/status/1?secret=2")
        let moment = island.queue.current?.moment
        XCTAssertEqual(moment?.pillName, "x.com")
        XCTAssertEqual(moment?.title, "Still on x.com?")
    }

    // MARK: - Told to VoiceOver, and the sound

    func testItsAnnouncedWhenItShowsOnly() {
        island.post(moment(.drift))
        wait(1)
        wait(1)
        XCTAssertEqual(surface.announced, ["drift. b"])
        XCTAssertEqual(surface.urgent, [true])
    }

    func testTheSoftSoundIsOffAndOnlyForANudgeAndAFinishedSession() {
        island.post(moment(.drift))
        XCTAssertTrue(sounds.isEmpty)
        island.closeCurrent()

        defaults.set(true, forKey: IslandSettings.softSound)
        island.post(moment(.drift))
        XCTAssertEqual(sounds, [.drift])
        island.closeCurrent()
        island.post(moment(.sessionFinished))
        island.notePause()
        wait(IslandRules.gapBetween)
        XCTAssertEqual(sounds, [.drift, .sessionFinished])
        for kind in IslandKind.allCases where kind != .drift && kind != .sessionFinished {
            XCTAssertFalse(IslandSettings.hasSound(kind), "\(kind)")
        }
    }

    // MARK: - Contrast

    func testTextIsAtLeast4_5To1() {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ rgb: [Double]) -> Double {
            0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])
        }
        func over(_ alpha: Double, _ back: [Double]) -> [Double] { back.map { alpha + $0 * (1 - alpha) } }
        func contrast(_ a: [Double], _ b: [Double]) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        let back = [0x17 / 255.0, 0x16 / 255.0, 0x1F / 255.0]
        XCTAssertGreaterThanOrEqual(contrast(over(IslandStyle.secondaryOpacity, back), back), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(over(IslandStyle.bodyOpacity, back), back), 4.5)
        // The secondary button's label on its translucent fill.
        XCTAssertGreaterThanOrEqual(contrast([1, 1, 1], over(0.16, back)), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(back, [1, 1, 1]), 4.5)
    }

    // MARK: - Where it goes

    private let plainScreen = IslandPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                                     visible: NSRect(x: 0, y: 0, width: 1440, height: 875), safeTop: 0)

    func testItSitsCentredUnderTheStatusItem() {
        let spot = IslandPlacement.spot(anchor: NSRect(x: 900, y: 875, width: 40, height: 25), screens: [plainScreen], pointer: .zero)
        XCTAssertEqual(spot, IslandPlacement.Spot(centerX: 920, top: 875 - IslandPlacement.gap))
    }

    func testItStaysOnTheScreen() throws {
        let spot = try XCTUnwrap(IslandPlacement.spot(anchor: NSRect(x: 1400, y: 875, width: 30, height: 25), screens: [plainScreen], pointer: .zero))
        XCTAssertLessThanOrEqual(spot.centerX + IslandStyle.cardWidth / 2, 1440)
    }

    func testItFollowsTheStatusItemsScreen() {
        let second = IslandPlacement.Screen(frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
                                            visible: NSRect(x: 1440, y: 0, width: 1920, height: 1055), safeTop: 0)
        let spot = IslandPlacement.spot(anchor: NSRect(x: 2500, y: 1055, width: 40, height: 25), screens: [plainScreen, second], pointer: .zero)
        XCTAssertEqual(spot, IslandPlacement.Spot(centerX: 2520, top: 1055 - IslandPlacement.gap))
    }

    func testWithoutTheStatusItemItsTopRightOfTheScreenInUse() {
        let second = IslandPlacement.Screen(frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
                                            visible: NSRect(x: 1440, y: 0, width: 1920, height: 1055), safeTop: 0)
        let spot = IslandPlacement.spot(anchor: nil, screens: [plainScreen, second], pointer: NSPoint(x: 2000, y: 500))
        XCTAssertEqual(spot?.centerX, 1440 + 1920 - IslandStyle.cardWidth / 2 - IslandPlacement.sideMargin)
        XCTAssertEqual(spot?.top, 1055 - IslandPlacement.gap)
    }

    func testAnOffScreenStatusItemCountsAsUnknown() {
        let spot = IslandPlacement.spot(anchor: NSRect(x: -500, y: 5000, width: 40, height: 25), screens: [plainScreen], pointer: NSPoint(x: 10, y: 10))
        XCTAssertEqual(spot?.centerX, 1440 - IslandStyle.cardWidth / 2 - IslandPlacement.sideMargin)
    }

    func testItClearsTheNotchEvenWithTheMenuBarHidden() {
        let notched = IslandPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                                             visible: NSRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 37)
        let spot = IslandPlacement.spot(anchor: NSRect(x: 756, y: 945, width: 30, height: 37), screens: [notched], pointer: .zero)
        XCTAssertEqual(spot?.top, 982 - 37 - IslandPlacement.gap)
    }

    // MARK: - Pick up

    private func place(_ bundleId: String = "com.google.Chrome", _ appName: String = "Google Chrome",
                       title: String? = "TSLA 412.50 ▲ 1.2% — TradingView", url: String? = "https://www.tradingview.com/chart/x") -> PickUpPlace {
        PickUpPlace(bundleId: bundleId, appName: appName, title: title, url: url, at: now)
    }

    func testPickUpLeadsWithTheSiteNotThePageTitle() {
        let found = PickUpReturn(kind: .call, since: now, seconds: 600)
        let card = PickUpCard.returning(found, places: [place()], session: nil, sawPrivateWindow: false)
        XCTAssertEqual(card.title, "You were on tradingview.com")
        XCTAssertEqual(card.rows.first?.detail, "tradingview.com")
    }

    func testPickUpStillNamesAnAppsWindow() {
        let found = PickUpReturn(kind: .call, since: now, seconds: 600)
        let card = PickUpCard.returning(found, places: [place("com.example.code", "Xcode", title: "AuthSession.swift — FocusGuard", url: nil)],
                                        session: nil, sawPrivateWindow: false)
        XCTAssertEqual(card.title, "You were in AuthSession.swift")
    }

    func testPickUpsButtonIsShort() {
        let found = PickUpReturn(kind: .drift(name: "x.com"), since: now, seconds: 600)
        let card = PickUpCard.returning(found, places: [place()], session: nil, sawPrivateWindow: false)
        XCTAssertEqual(card.primary, "Back to Chrome")
        XCTAssertEqual(place("com.apple.Safari", "Safari").shortAppName, "Safari")
    }

    func testAReturnStartsAsAPillAndWhatWasAskedForOpens() {
        let found = PickUpReturn(kind: .away, since: now, seconds: 600)
        let back = PickUpCard.returning(found, places: [place()], session: nil, sawPrivateWindow: false)
        XCTAssertFalse(IslandMoment.pickUp(back).startsOpen)
        XCTAssertEqual(IslandMoment.pickUp(back).pillName, "tradingview.com")
        XCTAssertEqual(IslandMoment.pickUp(back).pillValue, "Pick up")
        let menu = PickUpCard.lastPlaces([place()], now: now, calendar: calendar)
        XCTAssertTrue(IslandMoment.pickUp(menu).startsOpen)
        XCTAssertTrue(IslandMoment.pickUp(menu).requested)
    }

    func testPickUpGoesOnTheIslandAndClosesWithIt() {
        let found = PickUpReturn(kind: .away, since: now, seconds: 600)
        let card = PickUpCard.returning(found, places: [place()], session: nil, sawPrivateWindow: false)
        let presenter = IslandPickUpPresenter(island: island)
        let coordinator = PickUpCoordinator(opener: NoPickUpOpener(), presenter: presenter, defaults: defaults)
        presenter.show(card, coordinator: coordinator)
        XCTAssertEqual(currentKind, .pickUp)
        XCTAssertEqual(island.queue.current?.moment.pickUp, card)
        wait(3600 - 1)
        XCTAssertEqual(currentKind, .pickUp, "Pick up's own rules close it")
        presenter.close()
        XCTAssertNil(currentKind)
    }
}
