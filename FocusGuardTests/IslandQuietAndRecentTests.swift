import UserNotifications
import XCTest
@testable import FocusGuard

/// What holds the island besides calls (sharing, a Focus, being away), what it
/// remembers (Recent, the waiting queue, the trial reminder), and what each
/// card says and does. A fake clock and a fake surface, as in `IslandTests`.
@MainActor
final class IslandQuietAndRecentTests: XCTestCase {
    private final class FakeSurface: IslandSurface {
        var shown: [IslandMoment] = []
        var hides = 0

        func attach(_ island: IslandController) {}
        func show(_ moment: IslandMoment, open: Bool, now: Date) { shown.append(moment) }
        func update(_ moment: IslandMoment, open: Bool, now: Date) {}
        func hide() { hides += 1 }
        func announce(_ text: String, urgent: Bool) {}
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
    private var sent: [UNNotificationRequest] = []
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var island: IslandController!
    private var presenter: NotificationPresenter!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "IslandQuietAndRecentTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(50, forKey: SessionDefaultsKey.durationMinutes)
        // 10:00 UTC on a Wednesday.
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10)) ?? now
        conditions = IslandConditions(now: now, frontApp: "com.example.code")
        sent = []
        performed = []
        relaunch()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        island = nil
        presenter = nil
        try await super.tearDown()
    }

    /// A new island over the same defaults: what a quit and relaunch leaves.
    private func relaunch() {
        surface = FakeSurface()
        island = IslandController(surface: surface, clock: { [unowned self] in self.now }, defaults: defaults,
                                  calendar: calendar, runsTimer: false)
        island.conditions = { [unowned self] in
            var conditions = self.conditions
            conditions.now = self.now
            return conditions
        }
        island.perform = { [unowned self] in self.performed.append($0) }
        presenter = NotificationPresenter(defaults: defaults, send: { [unowned self] in self.sent.append($0) }, register: { _ in })
        presenter.island = island
        island.isAllowed = { [unowned self] in self.presenter.islandAllows($0) }
    }

    private func moment(_ kind: IslandKind, key: String? = nil, buttons: [IslandButton] = [], expiresAt: Date? = nil) -> IslandMoment {
        IslandMoment(kind: kind, key: key ?? "\(kind)", pillName: "\(kind)", kicker: "k", title: "\(kind)", body: "b",
                     buttons: buttons, expiresAt: expiresAt)
    }

    private func wait(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        island.tick()
    }

    private var currentKind: IslandKind? { island.queue.current?.moment.kind }

    // MARK: - Screen sharing: what counts

    private func window(_ owner: String, _ title: String, height: CGFloat = 60) -> ScreenShareDetector.WindowInfo {
        .init(owner: owner, title: title, height: height)
    }

    func testTheSharingWindowsItKnows() {
        let sharing = [
            window("zoom.us", "zoom share toolbar window"),
            window("zoom.us", "zoom share statusbar window", height: 900),
            window("Microsoft Teams", "Sharing control bar | Microsoft Teams"),
            window("Cisco Webex Meetings", "Webex is sharing your content"),
            window("Google Chrome", "meet.google.com is sharing your screen."),
            window("Arc", "meet.google.com is sharing a window."),
            window("Google Chrome", "meet.google.com gibt deinen Bildschirm frei"),
            window("Safari", "someone.example is sharing your screen."),
        ]
        for window in sharing {
            XCTAssertTrue(ScreenShareDetector.isSharing([window]), window.title)
        }
    }

    func testOrdinaryWindowsDontCount() {
        let quiet = [
            window("zoom.us", "Zoom Meeting", height: 800),
            window("Microsoft Teams", "Sharing tips | Microsoft Teams", height: 800),
            window("Google Chrome", "Anna is sharing a doc with you", height: 900),
            window("Google Chrome", "Meet – abc-defg-hij", height: 900),
            window("Xcode", "IslandRules.swift", height: 900),
            window("Notes", "Teams sharing plan", height: 900),
        ]
        for window in quiet {
            XCTAssertFalse(ScreenShareDetector.isSharing([window]), window.title)
        }
        XCTAssertFalse(ScreenShareDetector.isSharing([]), "without Screen Recording no window has a title")
    }

    func testSharingHoldsCardsAndTheyComeBack() {
        island.post(moment(.drift))
        XCTAssertEqual(currentKind, .drift)
        conditions.isSharingScreen = true
        wait(1)
        XCTAssertNil(currentKind)
        XCTAssertEqual(surface.hides, 1)
        conditions.isSharingScreen = false
        wait(1)
        XCTAssertEqual(currentKind, .drift)
    }

    func testItIsOnUntilTurnedOff() {
        XCTAssertTrue(IslandSettings.isQuietWhileSharing(defaults))
        defaults.set(false, forKey: IslandSettings.quietWhileSharing)
        XCTAssertFalse(IslandSettings.isQuietWhileSharing(defaults))
    }

    // MARK: - A Focus

    private var focus: FocusQuiet { FocusQuiet(defaults: defaults) }

    func testAFocusHoldsCardsAndReleasesThem() {
        focus.set(true, now: now)
        conditions.isFocusQuiet = focus.isOn(now: now)
        island.post(moment(.limit))
        XCTAssertNil(currentKind)
        focus.set(false, now: now)
        conditions.isFocusQuiet = focus.isOn(now: now)
        wait(1)
        XCTAssertEqual(currentKind, .limit)
    }

    func testAStaleFocusCantHoldForever() {
        focus.set(true, now: now)
        XCTAssertTrue(focus.isOn(now: now.addingTimeInterval(FocusQuiet.longestUnconfirmed - 1)))
        XCTAssertFalse(focus.isOn(now: now.addingTimeInterval(FocusQuiet.longestUnconfirmed)), "nothing confirmed it for too long")
        XCTAssertFalse(focus.isOn(now: now), "and it stays over")
    }

    func testAClockGoneBackwardsEndsTheHold() {
        focus.set(true, now: now)
        XCTAssertFalse(focus.isOn(now: now.addingTimeInterval(-60)))
    }

    func testAskingTheFilterSettlesARelaunch() {
        focus.set(true, now: now)
        focus.apply(.unknown, now: now)
        XCTAssertTrue(focus.isOn(now: now), "no answer: it runs out by itself")
        focus.apply(.off, now: now)
        XCTAssertFalse(focus.isOn(now: now), "the off was missed while the app wasn't running")

        focus.set(true, now: now)
        let later = now.addingTimeInterval(FocusQuiet.longestUnconfirmed - 60)
        focus.apply(.on, now: later)
        XCTAssertTrue(focus.isOn(now: later.addingTimeInterval(120)), "a confirmed Focus goes on past the limit")
    }

    func testTheFiltersDefaultIsOff() {
        // A Focus turning off sets every parameter back to its default and
        // calls `perform()`, so the off is the default.
        XCTAssertFalse(FocusGuardFocusFilter().keepCardsQuiet)
    }

    func testTheFilterSaysWhatItDoes() {
        XCTAssertEqual(FocusGuardFocusFilter.summary(startSession: false, minutes: nil, keepCardsQuiet: true), "Keep cards quiet")
        XCTAssertEqual(FocusGuardFocusFilter.summary(startSession: false, minutes: nil, keepCardsQuiet: false), "Don't start a session")
        XCTAssertEqual(FocusGuardFocusFilter.summary(startSession: true, minutes: 25, keepCardsQuiet: true), "Start a 25-minute session, cards quiet")
    }

    // MARK: - Away

    func testHeldCardsComeBackOnReturn() throws {
        island.post(moment(.limit))
        let shown = try XCTUnwrap(island.queue.current).moment
        conditions.isAway = true
        wait(1)
        XCTAssertNil(currentKind, "it leaves the screen")
        XCTAssertEqual(island.queue.waiting.map(\.moment.key), [shown.key], "and waits")
        conditions.isAway = false
        wait(1)
        XCTAssertEqual(currentKind, .limit)
    }

    func testAWaitingCardShowsOnReturnNotAtItsMaximumWait() {
        conditions.isAway = true
        island.post(moment(.trial))
        wait(30 * 60 + 1)
        XCTAssertNil(currentKind, "past its maximum wait, but the user is away")
        conditions.isAway = false
        wait(1)
        XCTAssertEqual(currentKind, .trial)
    }

    func testStaleCardsAreDroppedWhileAway() {
        conditions.isAway = true
        island.post(moment(.driftPrompt))
        wait(IslandRules.timing(.driftPrompt).expiry + 1)
        XCTAssertTrue(island.queue.isEmpty)
        conditions.isAway = false
        wait(5)
        XCTAssertNil(currentKind)
    }

    // MARK: - Recent

    private var recents: [IslandRecent] { island.recents.today(now: now) }

    func testRecentHasWhatShowedAndWhatTimedOut() {
        island.post(moment(.limit, buttons: [IslandButton(title: "See today", command: .openToday)]))
        conditions.isAway = true
        island.post(moment(.driftPrompt))
        wait(IslandRules.timing(.driftPrompt).expiry + 1)
        XCTAssertEqual(recents.map(\.key), ["driftPrompt", "limit"], "newest first, timed out as well")
        XCTAssertEqual(recents.last?.at, calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10)), "it showed at 10:00, whatever became of it after")
    }

    func testRecentLeavesOutTheSampleAndPickUp() {
        island.post(IslandMoment(kind: .sample, key: "sample", pillName: "", kicker: "", title: "Sample", body: "", requested: true))
        island.remove(key: "sample")
        island.post(moment(.pickUp, key: IslandMoment.pickUpKey))
        XCTAssertTrue(recents.isEmpty)
    }

    func testARepeatReplacesTheEarlierRow() {
        island.post(moment(.limit))
        wait(60)
        island.remove(key: "limit")
        island.post(moment(.limit))
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.at, now)
        XCTAssertEqual(recents.first?.answered, false)
    }

    func testRecentIsGoneTheNextDay() {
        island.post(moment(.limit))
        XCTAssertEqual(recents.count, 1)
        now = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        XCTAssertTrue(recents.isEmpty)
        relaunch()
        island.restoreWaiting()
        XCTAssertTrue(island.recents.items.isEmpty, "and doesn't stay on disk")
    }

    func testRecentComesBackAfterARelaunchTheSameDay() {
        island.post(moment(.limit))
        relaunch()
        XCTAssertEqual(recents.map(\.key), ["limit"])
    }

    func testRecentCutsOffAtItsLimit() {
        for number in 0..<(IslandRecents.keep + 5) { island.recents.note(moment(.reminder, key: "r\(number)"), at: now) }
        XCTAssertEqual(recents.count, IslandRecents.keep)
    }

    func testAnAnsweredMomentHasNoButtonLeft() {
        island.post(moment(.limit, buttons: [IslandButton(title: "See today", command: .openToday)]))
        XCTAssertEqual(IslandRecents.button(for: recents[0], now: now, busy: false)?.command, .openToday)
        island.closeCurrent()
        XCTAssertEqual(recents.count, 1, "it stays in the list")
        XCTAssertNil(IslandRecents.button(for: recents[0], now: now, busy: false))
    }

    func testWhichButtonsStillMakeSense() {
        let later = now.addingTimeInterval(3600), earlier = now.addingTimeInterval(-3600)
        let cases: [(NotificationCommand, busy: Bool, expires: Date, keeps: Bool)] = [
            (.openToday, false, earlier, true),
            (.openPlans, true, earlier, true),
            (.openAnalyzer, true, earlier, true),
            (.startSession(minutes: 50), false, later, true),
            (.startSession(minutes: 50), true, later, false),
            (.startSession(minutes: 50), false, earlier, false),
            (.takeBreak(minutes: 10), false, later, true),
            (.takeBreak(minutes: 10), true, later, false),
            (.startFromOffer(since: earlier, minutes: 50), false, later, true),
            (.startFromOffer(since: earlier, minutes: 50), false, earlier, false),
            (.planSessions([later]), false, earlier, true),
            (.planSessions([earlier]), false, later, false),
            (.backToWork, false, later, false),
            (.allowForSession(url: nil, bundleId: nil), false, later, false),
            (.snoozeAutoStart, false, later, false),
            (.skipPlannedSession(at: later), false, later, false),
        ]
        for (command, busy, expires, keeps) in cases {
            let item = IslandRecent(key: "k", title: "t", at: now, button: IslandButton(title: "b", command: command), expires: expires)
            XCTAssertEqual(IslandRecents.button(for: item, now: now, busy: busy) != nil, keeps, "\(command), busy \(busy)")
        }
        let closeOnly = IslandRecent(key: "k", title: "t", at: now, button: IslandButton(title: "OK"), expires: later)
        XCTAssertNil(IslandRecents.button(for: closeOnly, now: now, busy: false))
    }

    func testPlanningLaterOnlyPlansWhatsAhead() {
        let later = now.addingTimeInterval(3600), earlier = now.addingTimeInterval(-3600)
        let item = IslandRecent(key: "k", title: "t", at: now, button: IslandButton(title: "b", command: .planSessions([earlier, later])), expires: earlier)
        XCTAssertEqual(IslandRecents.button(for: item, now: now, busy: false)?.command, .planSessions([later]))
    }

    func testALimitIsNamedInRecent() {
        presenter.presentLimitWarning(name: "reddit.com", minutesLeft: 5, minutesToday: 30)
        XCTAssertEqual(recents.first?.title, "5 minutes left on reddit.com")
        XCTAssertEqual(island.queue.current?.moment.title, "5 minutes left today")
    }

    // MARK: - The queue across a quit

    func testWhatsWaitingComesBackAfterARelaunch() throws {
        conditions.isAway = true
        island.post(moment(.morningPlan, buttons: [IslandButton(title: "Plan them", command: .planSessions([now]))]))
        let before = try XCTUnwrap(island.queue.waiting.first)
        now = now.addingTimeInterval(120)
        relaunch()
        XCTAssertTrue(island.queue.isEmpty)
        island.restoreWaiting()
        let after = try XCTUnwrap(island.queue.waiting.first)
        XCTAssertEqual(after.moment, before.moment)
        XCTAssertEqual(after.arrived, before.arrived, "the wait doesn't start over")
        XCTAssertEqual(after.expires, before.expires)
    }

    func testWhatsOnScreenComesBackToo() {
        island.post(moment(.limit))
        XCTAssertEqual(currentKind, .limit)
        relaunch()
        island.restoreWaiting()
        XCTAssertEqual(currentKind, .limit)
    }

    func testExpiryStillAppliesAcrossAQuit() {
        conditions.isAway = true
        island.post(moment(.driftPrompt))
        now = now.addingTimeInterval(IslandRules.timing(.driftPrompt).expiry + 1)
        relaunch()
        conditions.isAway = false
        island.restoreWaiting()
        XCTAssertTrue(island.queue.isEmpty, "stale: never shows")
        XCTAssertEqual(recents.map(\.key), ["driftPrompt"], "but it's on the list")
    }

    func testAClosedOneDoesntComeBack() {
        island.post(moment(.limit))
        island.closeCurrent()
        relaunch()
        island.restoreWaiting()
        XCTAssertTrue(island.queue.isEmpty)
    }

    func testOnlyWhatStillMeansSomethingIsKept() {
        conditions.isAway = true
        for kind in IslandKind.allCases { island.post(moment(kind)) }
        let kept = Set(island.queue.saved.map(\.moment.kind))
        XCTAssertEqual(kept, Set(IslandKind.allCases.filter(\.survivesRelaunch)))
        XCTAssertFalse(kept.contains(.drift))
        XCTAssertFalse(kept.contains(.pickUp))
        XCTAssertFalse(kept.contains(.autoStart))
        XCTAssertFalse(kept.contains(.sample))
    }

    func testAMomentSurvivesTheRoundTrip() throws {
        var original = moment(.reminder, buttons: [IslandButton(title: "A", command: .allowForSession(url: "u", bundleId: nil)),
                                                   IslandButton(title: "B")])
        original.countdown = IslandCountdown(ends: now, total: 30)
        original.value = "25/30"
        original.counting = IslandCounting(since: now, name: "Xcode")
        let decoded = try JSONDecoder().decode(IslandMoment.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - The trial reminder

    private final class Reminder: TrialReminding {
        var sent = 0
        var answer: Bool
        init(answer: Bool) { self.answer = answer }
        func presentTrialEndingSoon(endsAt: Date, now: Date) -> Bool {
            sent += 1
            return answer
        }
    }

    private func trial(_ reminder: Reminder) -> (Entitlements, Date)? {
        let plan = Entitlements(defaults: defaults, reminder: reminder, now: { [unowned self] in self.now })
        plan.startTrialIfNeeded(for: .coach)
        guard case .trial(let endsAt) = plan.plan else { return nil }
        now = Entitlements.reminderDate(for: endsAt)
        return (plan, endsAt)
    }

    func testTheReminderKeepsTryingUntilItHasReallyShown() throws {
        let reminder = Reminder(answer: false)
        let (plan, _) = try XCTUnwrap(trial(reminder))
        plan.refresh()
        plan.refresh()
        XCTAssertEqual(reminder.sent, 2, "on the island it isn't sent yet")
        plan.noteTrialReminderShown()
        plan.refresh()
        XCTAssertEqual(reminder.sent, 2, "seen: never again")
    }

    func testTheReminderSentToMacOSCountsAtOnce() throws {
        let reminder = Reminder(answer: true)
        let (plan, _) = try XCTUnwrap(trial(reminder))
        plan.refresh()
        plan.refresh()
        XCTAssertEqual(reminder.sent, 1)
    }

    func testTheCardCountsOnlyWhenItShows() {
        let end = now.addingTimeInterval(2 * 86_400)
        XCTAssertFalse(presenter.presentTrialEndingSoon(endsAt: end, now: now))
        var shown: [IslandKind] = []
        island.didShow = { shown.append($0.kind) }
        wait(1)
        XCTAssertTrue(shown.isEmpty)
        wait(IslandRules.timing(.trial).maxWait)
        XCTAssertEqual(shown, [.trial])
    }

    func testAMacOSNotificationCountsOnlyIfMacOSAllowsIt() {
        defaults.set(IslandSettings.Surface.macOS.rawValue, forKey: IslandSettings.surface)
        XCTAssertTrue(presenter.presentTrialEndingSoon(endsAt: now, now: now))
        presenter.macOSAllows = { false }
        XCTAssertFalse(presenter.presentTrialEndingSoon(endsAt: now, now: now))
    }

    func testSilencedItDoesntCount() {
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        XCTAssertFalse(presenter.presentTrialEndingSoon(endsAt: now, now: now))
    }

    func testTheCardSaysTheRealDaysLeft() throws {
        presenter.presentTrialEndingSoon(endsAt: now.addingTimeInterval(86_400 + 3600), now: now)
        XCTAssertEqual(island.queue.waiting.first?.moment.pillValue, "2 days left")
        XCTAssertEqual(island.queue.waiting.first?.moment.title, "Your trial ends in 2 days")
        presenter.presentTrialEndingSoon(endsAt: now.addingTimeInterval(3600), now: now)
        let moment = try XCTUnwrap(island.queue.waiting.first?.moment)
        XCTAssertEqual(moment.pillName, "Pro trial")
        XCTAssertEqual(moment.pillValue, "1 day left")
        XCTAssertEqual(moment.title, "Your trial ends in 1 day")
    }

    // MARK: - The finished experiment

    func testTheFinishedExperimentGoesToItsResult() throws {
        presenter.presentExperimentFinished()
        let moment = try XCTUnwrap(island.queue.waiting.first?.moment)
        XCTAssertEqual(moment.title, "Your experiment is done")
        XCTAssertEqual(moment.buttons.map(\.title), ["See the result", "OK"])
        XCTAssertEqual(moment.buttons.map(\.command), [.openAnalyzer, nil])
        XCTAssertEqual(NotificationCommand.openAnalyzer.page, .analyzer)
    }

    func testItsBannerHasTheSameButtons() throws {
        defaults.set(IslandSettings.Surface.macOS.rawValue, forKey: IslandSettings.surface)
        presenter.presentExperimentFinished()
        let content = try XCTUnwrap(sent.first?.content)
        let actions = presenter.categoryActions(content.categoryIdentifier)
        XCTAssertEqual(actions.map(\.title), ["See the result", "OK"])
        let see = try XCTUnwrap(actions.first)
        XCTAssertEqual(NotificationCommand(action: see.identifier, category: content.categoryIdentifier, info: content.userInfo), .openAnalyzer)
        XCTAssertTrue(see.options.contains(.foreground))
        XCTAssertEqual(NotificationCommand(action: UNNotificationDefaultActionIdentifier, category: content.categoryIdentifier, info: [:]), .openAnalyzer,
                       "clicking the banner itself")
        XCTAssertNil(NotificationCommand(action: NotificationAction.ok.rawValue, category: content.categoryIdentifier, info: [:]))
    }

    func testPagesOfTheOpeningCommands() {
        XCTAssertEqual(NotificationCommand.openToday.page, .home)
        XCTAssertEqual(NotificationCommand.openPlans.page, .settings)
        XCTAssertNil(NotificationCommand.backToWork.page)
    }

    // MARK: - Every card's buttons

    func testEveryButtonsTitleAndCommand() throws {
        let slot = now.addingTimeInterval(3600)
        let since = now.addingTimeInterval(-300)
        let plan = MorningPlan(slots: [slot], sessionMinutes: 25, goalMinutes: 240, focusedMinutes: 0, fromCalendar: false)
        let wrapUp = EveningWrapUp(focusedMinutes: 100, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil)
        let tip = EveningTip(kind: .driftHour, text: "Tip", slot: slot, button: "Plan it for 15:00")
        let tipped = EveningWrapUp(focusedMinutes: 100, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil, tip: tip)
        let offer = AutoStartOffer(since: since, appNames: ["Xcode"], bundleId: nil)
        let inSession = NudgeContext(sessionName: "Evening", minutesLeft: 18, backTo: "Xcode", bundleId: "com.x")

        let cases: [(String, NudgeContext?, () -> Void, [(String, NotificationCommand?)])] = [
            ("limit", nil, { self.presenter.presentLimitWarning(name: "reddit.com", minutesLeft: 5, minutesToday: 30) },
             [("Start a session", .startSession(minutes: nil)), ("OK", nil)]),
            ("limit in a session", inSession, { self.presenter.presentLimitWarning(name: "reddit.com", minutesLeft: 5, minutesToday: 30) },
             [("See today", .openToday), ("OK", nil)]),
            ("break over", nil, { self.presenter.presentBreakOver(breakMinutes: 10) },
             [("Start session", .startSession(minutes: 50)), ("5 more min", .takeBreak(minutes: 5))]),
            ("trial", nil, { self.presenter.presentTrialEndingSoon(endsAt: slot, now: self.now) },
             [("See plans", .openPlans), ("Later", nil)]),
            ("evening", nil, { self.presenter.presentEveningWrapUp(wrapUp) },
             [("See today", .openToday), ("Close", nil)]),
            ("evening with a tip", nil, { self.presenter.presentEveningWrapUp(tipped) },
             [("Plan it for 15:00", .planSessions([slot])), ("Close", nil)]),
            ("morning", nil, { self.presenter.presentMorningPlan(plan) },
             [("Plan them", .planSessions([slot])), ("Not today", nil)]),
            ("planned", nil, { self.presenter.presentPlannedSession(at: slot, minutes: 25) },
             [("Start now", .startSession(minutes: 25)), ("Skip this one", .skipPlannedSession(at: slot))]),
            ("drift, no session", nil, { self.presenter.presentDriftPrompt(host: "reddit.com") },
             [("Start 25 minutes", .startSession(minutes: 25)), ("Not now", nil)]),
            ("offer", nil, { self.presenter.presentAutoStartOffer(offer, now: self.now) },
             [("Start 50 minutes", .startFromOffer(since: since, minutes: 50)), ("Not now", .snoozeAutoStart)]),
            ("session finished", nil, { self.presenter.presentSessionComplete(name: "Run", minutes: 50, focusPercent: 88, zoneMinutes: 34, breakMinutes: 10) },
             [("Take a 10-minute break", .takeBreak(minutes: 10)), ("Start another", .startSession(minutes: 50))]),
            ("drift", inSession, { self.presenter.presentDistractionWarning(appName: "Chrome", currentURL: "https://x.com/a") },
             [("Back to Xcode", .backToWork), ("It's for work", .allowForSession(url: "https://x.com/a", bundleId: "com.x"))]),
        ]
        for (name, context, present, expected) in cases {
            relaunchEmpty()
            presenter.nudgeContext = { context }
            present()
            let shown = try XCTUnwrap(island.queue.current ?? island.queue.waiting.first, name).moment
            XCTAssertEqual(shown.buttons.map(\.title), expected.map(\.0), name)
            XCTAssertEqual(shown.buttons.map(\.command), expected.map(\.1), name)
        }
    }

    private func relaunchEmpty() {
        defaults.removeObject(forKey: IslandSettings.savedQueue)
        relaunch()
    }

    // MARK: - What the cards say

    func testThePrototypesWords() throws {
        func shown(_ present: () -> Void) throws -> IslandMoment {
            relaunchEmpty()
            present()
            return try XCTUnwrap(island.queue.current ?? island.queue.waiting.first).moment
        }
        let limit = try shown { presenter.presentLimitWarning(name: "reddit.com", minutesLeft: 5, minutesToday: 30) }
        XCTAssertEqual([limit.pillName, limit.pillValue, limit.kicker, limit.title, limit.value, limit.body],
                       ["reddit.com", "5 min left", "Daily limit", "5 minutes left today", "25/30", "It blocks at 30 minutes and resets at midnight."])

        let breakOver = try shown { presenter.presentBreakOver(breakMinutes: 10) }
        XCTAssertEqual([breakOver.pillName, breakOver.pillValue, breakOver.kicker, breakOver.title, breakOver.body],
                       ["Break over", "Start?", "Break over", "Ready for another 50 minutes?", "You took a 10-minute break."])

        let prompt = try shown { presenter.presentDriftPrompt(host: "reddit.com") }
        XCTAssertEqual([prompt.pillName, prompt.pillValue, prompt.kicker, prompt.title, prompt.body],
                       ["reddit.com", "Drifting?", "A few visits this hour", "Drifting to reddit.com?", "A short session might help."])

        let trial = try shown { presenter.presentTrialEndingSoon(endsAt: now.addingTimeInterval(2 * 86_400), now: now) }
        XCTAssertEqual([trial.pillName, trial.pillValue, trial.kicker, trial.title, trial.body],
                       ["Pro trial", "2 days left", "FocusGuard Pro", "Your trial ends in 2 days", "Free keeps your data and the basics."])

        let wrapUp = try shown { presenter.presentEveningWrapUp(EveningWrapUp(focusedMinutes: 203, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil)) }
        XCTAssertEqual([wrapUp.pillName, wrapUp.pillValue, wrapUp.kicker, wrapUp.title], ["Today", "3h 23m", "Evening wrap-up", "3h 23m focused today"])

        let finished = try shown { presenter.presentSessionComplete(name: "Evening focus", minutes: 50, focusPercent: 88, zoneMinutes: 34, breakMinutes: 10, longestThisWeek: true) }
        XCTAssertEqual([finished.pillName, finished.pillValue, finished.kicker, finished.title, finished.value, finished.body],
                       ["Evening focus", "88%", "Session complete · 50 min", "Evening focus", "88%", "34 min in the zone. Your longest stretch this week."])
    }

    func testTheMorningLineIsTrueToWhatItKnows() {
        let at = [calendar.date(bySettingHour: 9, minute: 30, second: 0, of: now) ?? now,
                  calendar.date(bySettingHour: 14, minute: 30, second: 0, of: now) ?? now]
        func plan(calendar fromCalendar: Bool, meetings: Bool) -> MorningPlan {
            MorningPlan(slots: at, sessionMinutes: 50, goalMinutes: 240, focusedMinutes: 0, fromCalendar: fromCalendar, hasMeetings: meetings)
        }
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(plan(calendar: true, meetings: true).shortBody(locale: locale, calendar: calendar), "Free at 9:30 and 14:30, around your meetings.")
        XCTAssertEqual(plan(calendar: true, meetings: false).shortBody(locale: locale, calendar: calendar), "Free at 9:30 and 14:30.")
        XCTAssertEqual(plan(calendar: false, meetings: false).shortBody(locale: locale, calendar: calendar), "Try 9:30 and 14:30.")

        let moment = presenter.morningPlanMoment(plan(calendar: false, meetings: false))
        XCTAssertEqual(moment.title, "Plan your day")
        XCTAssertEqual(moment.pillValue, "2 slots", "free only when the calendar could say so")
        XCTAssertEqual(presenter.morningPlanMoment(plan(calendar: true, meetings: true)).pillValue, "2 free slots")
    }

    func testLongestStretchIsSaidOnlyWhenTrue() {
        let say = SessionFinishedFacts.isLongestThisWeek
        XCTAssertTrue(say(34 * 60, [20 * 60, 33 * 60]))
        XCTAssertFalse(say(34 * 60, [35 * 60]), "a longer one this week")
        XCTAssertFalse(say(34 * 60, [34 * 60]), "a tie isn't the longest")
        XCTAssertFalse(say(34 * 60, []), "the week's first session has nothing to beat")
        XCTAssertFalse(say(30, [10]), "under a minute isn't a stretch")

        let plain = presenter.sessionFinishedMoment(name: "Run", minutes: 50, focusPercent: 88, zoneMinutes: 34)
        XCTAssertEqual(plain.body, "34 min in the zone.")
        let longest = presenter.sessionFinishedMoment(name: "Run", minutes: 50, focusPercent: 88, zoneMinutes: 34, longestThisWeek: true)
        XCTAssertEqual(longest.body, "34 min in the zone. Your longest stretch this week.")
        let none = presenter.sessionFinishedMoment(name: "Run", minutes: 50, focusPercent: 88, zoneMinutes: 0, longestThisWeek: true)
        XCTAssertEqual(none.body, "A good moment for a break.")
    }

    func testTheOfferKeepsUpWithTheRealMinutes() throws {
        let since = now.addingTimeInterval(-5 * 60)
        presenter.presentAutoStartOffer(AutoStartOffer(since: since, appNames: ["Xcode"], bundleId: nil), now: now)
        let moment = try XCTUnwrap(island.queue.waiting.first).moment
        XCTAssertEqual(moment.shownBody(at: now), "These 5 minutes will count.")
        XCTAssertEqual(moment.shownPillName(at: now), "Xcode · 5 min")
        XCTAssertEqual(moment.shownBody(at: now.addingTimeInterval(4 * 60)), "These 9 minutes will count.", "it waited")
        XCTAssertEqual(moment.shownPillName(at: now.addingTimeInterval(4 * 60)), "Xcode · 9 min")
        XCTAssertEqual(moment.shownBody(at: since.addingTimeInterval(60)), "This 1 minute will count.")
        XCTAssertTrue(moment.announcement(at: now).contains("These 5 minutes"))
    }

    func testAcrossSeveralAppsTheOfferSaysFocused() {
        let offer = AutoStartOffer(since: now.addingTimeInterval(-5 * 60), appNames: ["Xcode", "Notes"], bundleId: nil)
        XCTAssertEqual(presenter.autoStartMoment(offer, usualMinutes: 50, now: now).shownPillName(at: now), "Focused · 5 min")
    }

    func testItSaysNaturalPauseOnlyWhenItWasHeldUntilOne() throws {
        let offer = AutoStartOffer(since: now.addingTimeInterval(-5 * 60), appNames: ["Xcode"], bundleId: nil)
        // Held, then an app switch.
        presenter.presentAutoStartOffer(offer, now: now)
        wait(10)
        XCTAssertNil(currentKind)
        conditions.frontApp = "com.example.browser"
        wait(1)
        XCTAssertEqual(island.queue.current?.moment.shownKicker, "At a natural pause")

        // Held, and its maximum wait ran out with no pause.
        relaunchEmpty()
        conditions.frontApp = "com.example.code"
        presenter.presentAutoStartOffer(offer, now: now)
        wait(IslandRules.timing(.autoStart).maxWait)
        XCTAssertEqual(currentKind, .autoStart)
        XCTAssertTrue(try XCTUnwrap(island.queue.current).moment.shownKicker.hasPrefix("Focused since"))

        // It came during a pause, so nothing held it.
        relaunchEmpty()
        conditions.idleSeconds = IslandRules.idleForPause
        presenter.presentAutoStartOffer(offer, now: now)
        XCTAssertEqual(currentKind, .autoStart)
        XCTAssertTrue(try XCTUnwrap(island.queue.current).moment.shownKicker.hasPrefix("Focused since"))
    }

    func testAWithdrawnOfferLeavesTheIsland() {
        presenter.presentAutoStartOffer(AutoStartOffer(since: now, appNames: ["Xcode"], bundleId: nil), now: now)
        XCTAssertFalse(island.queue.isEmpty)
        presenter.withdrawAutoStartOffer()
        XCTAssertTrue(island.queue.isEmpty)
    }

    func testThePlannedKickerIsTrue() {
        let slot = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now) ?? now
        func kicker(_ planned: Date?) -> String { NotificationPresenter.plannedKicker(slot: slot, plannedAt: planned, calendar: calendar) }
        XCTAssertEqual(kicker(calendar.date(bySettingHour: 9, minute: 15, second: 0, of: now)), "Planned this morning")
        XCTAssertEqual(kicker(calendar.date(bySettingHour: 13, minute: 0, second: 0, of: now)), "Your plan", "planned this afternoon")
        XCTAssertEqual(kicker(calendar.date(byAdding: .day, value: -1, to: slot)), "Your plan", "the evening tip plans for the next day")
        XCTAssertEqual(kicker(nil), "Your plan", "a slot from before this was kept")

        let planned = presenter.plannedSessionMoment(at: slot, title: "t", body: "b", plannedAt: calendar.date(bySettingHour: 9, minute: 15, second: 0, of: now), calendar: calendar)
        XCTAssertEqual(planned.kicker, "Planned this morning")
    }

    func testThePlannedLinesAreTheDesigns() throws {
        let slot = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now) ?? now
        presenter.presentPlannedSession(at: slot, minutes: 50)
        let moment = try XCTUnwrap(island.queue.waiting.first).moment
        XCTAssertEqual(moment.body, "50 minutes, as you planned.")
        XCTAssertEqual(moment.pillValue, "Now")
    }

    // MARK: - The window's margin

    func testOnlyTheIslandTakesThePointer() {
        let shape = IslandPlacement.shape(of: CGSize(width: 352, height: 143), at: IslandPlacement.Spot(centerX: 1000, top: 800))
        XCTAssertEqual(shape, NSRect(x: 824, y: 657, width: 352, height: 143))
        func over(_ x: CGFloat, _ y: CGFloat) -> Bool { IslandPlacement.isOver(shape, radius: 24, point: NSPoint(x: x, y: y)) }
        XCTAssertTrue(over(1000, 700), "the middle")
        XCTAssertTrue(over(825, 700), "the left edge")
        XCTAssertTrue(over(1000, 658), "the bottom edge")
        XCTAssertFalse(over(1000, 655), "2 points under: the shadow")
        XCTAssertFalse(over(820, 700), "left of it")
        XCTAssertFalse(over(1000, 802), "above it")
        XCTAssertFalse(over(825, 658), "outside the rounded corner")
        XCTAssertTrue(over(832, 665), "inside the rounded corner")
    }

    func testTheMarginHoldsTheWholeShadow() {
        let margin = IslandStyle.margin
        XCTAssertEqual(IslandStyle.shadowRadius * 2 + IslandStyle.shadowOffset, margin.bottom)
        XCTAssertEqual(IslandStyle.shadowRadius * 2, margin.leading)
        XCTAssertEqual(IslandStyle.shadowRadius * 2, margin.trailing)
        XCTAssertEqual(IslandStyle.shadowRadius * 2 - IslandStyle.shadowOffset, margin.top)
    }

    // MARK: - The notification permission

    func testItIsAskedForOnlyWhenMacOSIsPicked() {
        XCTAssertTrue(IslandSettings.shouldAskForNotifications(surface: .macOS, status: .notDetermined))
        for status in [PermissionStatus.granted, .denied, .unknown] {
            XCTAssertFalse(IslandSettings.shouldAskForNotifications(surface: .macOS, status: status), "\(status): never asks again")
        }
        for status in [PermissionStatus.notDetermined, .granted, .denied, .unknown] {
            XCTAssertFalse(IslandSettings.shouldAskForNotifications(surface: .cards, status: status), "cards don't need it")
        }
    }

    func testNothingNagsAboutNotifications() {
        let permissions = PermissionsCoordinator()
        permissions.screenRecording = .granted
        for status in [PermissionStatus.notDetermined, .denied, .unknown] {
            permissions.notifications = status
            XCTAssertTrue(permissions.allGranted, "\(status)")
        }
        permissions.screenRecording = .denied
        XCTAssertFalse(permissions.allGranted, "Screen Recording is what tracking needs")
    }
}
