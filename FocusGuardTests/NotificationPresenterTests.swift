import XCTest
import UserNotifications
@testable import FocusGuard

@MainActor
final class NotificationPresenterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sent: [UNNotificationRequest] = []
    private var registered: [Set<UNNotificationCategory>] = []
    private var presenter: NotificationPresenter!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "NotificationPresenterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(50, forKey: SessionDefaultsKey.durationMinutes)
        sent = []
        registered = []
        presenter = NotificationPresenter(defaults: defaults,
                                          send: { [weak self] in self?.sent.append($0) },
                                          register: { [weak self] in self?.registered.append($0) })
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        presenter = nil
        try await super.tearDown()
    }

    private func sendEverything() {
        presenter.presentDistractionWarning(appName: "Safari", currentURL: "https://youtube.com")
        presenter.presentSessionComplete(name: "Steady Run", minutes: 42, focusPercent: 84, zoneMinutes: 30, breakMinutes: 10)
        presenter.presentBreakOver()
        presenter.presentDriftPrompt(host: "youtube.com")
        presenter.presentLimitWarning(name: "youtube.com", minutesLeft: 5, minutesToday: 30)
        presenter.presentEveningWrapUp(EveningWrapUp(focusedMinutes: 200, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil))
        presenter.presentAutoStartOffer(AutoStartOffer(since: Date().addingTimeInterval(-300), appNames: ["Xcode"], bundleId: nil))
        presenter.presentTrialEndingSoon(endsAt: .now)
    }

    private func buttons(_ request: UNNotificationRequest?) -> [String] {
        guard let id = request?.content.categoryIdentifier,
              let category = registered.last?.first(where: { $0.identifier == id }) else { return [] }
        return category.actions.map(\.title)
    }

    // MARK: - Switches

    func testEverythingIsSentByDefault() {
        sendEverything()
        XCTAssertEqual(sent.count, 8)
    }

    func testMasterSwitchSilencesEverything() {
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        sendEverything()
        XCTAssertTrue(sent.isEmpty)
    }

    func testDriftSwitchSilencesOnlyDriftWarnings() {
        defaults.set(false, forKey: SettingsKeys.Escalation.notificationsEnabled)
        sendEverything()
        XCTAssertEqual(sent.count, 7)
        XCTAssertFalse(sent.contains { $0.content.title.hasPrefix("Still on") })
    }

    func testSwitchChangesApplyImmediately() {
        presenter.presentBreakOver()
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        presenter.presentBreakOver()
        defaults.set(true, forKey: SettingsKeys.showNotifications)
        presenter.presentBreakOver()
        XCTAssertEqual(sent.count, 2)
    }

    func testTestNotificationAlwaysSends() {
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        defaults.set(false, forKey: SettingsKeys.Escalation.notificationsEnabled)
        presenter.presentTestNotification()
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: - What they say

    func testNudgeNamesTheSiteAndTheSession() {
        presenter.nudgeContext = { NudgeContext(sessionName: "Evening focus", minutesLeft: 24, backTo: "Xcode", bundleId: "com.google.Chrome") }
        presenter.presentDistractionWarning(appName: "Chrome", currentURL: "https://www.x.com/home")
        let request = sent.first
        XCTAssertEqual(request?.content.title, "Still on x.com?")
        XCTAssertEqual(request?.content.body, "Evening focus has 24 minutes left. Xcode is one click away.")
        XCTAssertEqual(buttons(request), ["Back to Xcode", "It's for work"])
        XCTAssertEqual(request?.content.userInfo[NotificationInfo.url] as? String, "https://www.x.com/home")
        XCTAssertEqual(request?.content.userInfo[NotificationInfo.bundleId] as? String, "com.google.Chrome")
    }

    func testNudgeWithoutAFocusAppOrEnd() {
        presenter.nudgeContext = { NudgeContext(sessionName: "Morning focus", minutesLeft: nil, backTo: nil, bundleId: nil) }
        presenter.presentDistractionWarning(appName: "Discord", currentURL: nil)
        XCTAssertEqual(sent.first?.content.title, "Still on Discord?")
        XCTAssertEqual(sent.first?.content.body, "Morning focus is still running.")
        XCTAssertEqual(buttons(sent.first), ["Back to work", "It's for work"])
    }

    func testSessionCompleteUsesTheSessionName() {
        presenter.presentSessionComplete(name: "Locked-in Deep Dive", minutes: 50, focusPercent: 92, zoneMinutes: 41, breakMinutes: 10)
        XCTAssertEqual(sent.first?.content.title, "Session complete: Locked-in Deep Dive")
        XCTAssertEqual(sent.first?.content.body, "50 min · 92% focused · 41 min in the zone.")
        XCTAssertEqual(buttons(sent.first), ["Take a 10-minute break", "Start another"])
    }

    func testSessionCompleteLeavesOutAZoneUnderAMinute() {
        presenter.presentSessionComplete(name: "Quiet Sprint", minutes: 12, focusPercent: 0, zoneMinutes: 0, breakMinutes: 5)
        XCTAssertEqual(sent.first?.content.body, "12 min · 0% focused.")
    }

    func testBreakOverOffersTheUsualLength() {
        presenter.presentBreakOver()
        XCTAssertEqual(sent.first?.content.body, "Ready for another 50 minutes? Blocking comes back when you start.")
        XCTAssertEqual(buttons(sent.first), ["Start 50 minutes", "5 more minutes"])
        XCTAssertEqual(sent.first?.content.userInfo[NotificationInfo.minutes] as? Int, 50)
    }

    func testLimitWarningSaysHowMuchIsUsed() {
        presenter.presentLimitWarning(name: "youtube.com", minutesLeft: 5, minutesToday: 30)
        XCTAssertEqual(sent.first?.content.title, "5 minutes left on youtube.com")
        XCTAssertEqual(sent.first?.content.body, "You've used 25 of your 30 minutes today.")
    }

    func testTrialReminderFollowsTheMasterSwitch() {
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        presenter.presentTrialEndingSoon(endsAt: .now)
        XCTAssertTrue(sent.isEmpty)
        defaults.set(true, forKey: SettingsKeys.showNotifications)
        presenter.presentTrialEndingSoon(endsAt: .now)
        XCTAssertEqual(buttons(sent.first), ["See Free and Pro"])
    }

    // MARK: - Buttons

    func testEachSetOfButtonsIsRegisteredOnce() {
        presenter.presentBreakOver()
        presenter.presentBreakOver()
        XCTAssertEqual(registered.count, 1)

        defaults.set(25, forKey: SessionDefaultsKey.durationMinutes)
        presenter.presentBreakOver()
        XCTAssertEqual(registered.count, 2)
        // Earlier sets stay, so older notifications keep their buttons.
        XCTAssertEqual(registered.last?.count, 2)
        XCTAssertEqual(buttons(sent.last), ["Start 25 minutes", "5 more minutes"])
    }

    func testCategoryIdentifiersKeepTheirKind() {
        sendEverything()
        let kinds = sent.compactMap { NotificationCategory(identifier: $0.content.categoryIdentifier) }
        XCTAssertEqual(kinds, [.nudge, .sessionComplete, .breakOver, .driftPrompt, .wrapUp, .autoStart, .trialEnding])
    }
}
