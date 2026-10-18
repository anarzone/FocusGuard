import XCTest
import UserNotifications
@testable import FocusGuard

@MainActor
final class NotificationPresenterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sent: [UNNotificationRequest] = []
    private var presenter: NotificationPresenter!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "NotificationPresenterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        sent = []
        presenter = NotificationPresenter(defaults: defaults) { [weak self] in self?.sent.append($0) }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        presenter = nil
        try await super.tearDown()
    }

    private func sendEverything() {
        presenter.presentDistractionWarning(appName: "Safari", currentURL: "https://youtube.com")
        presenter.presentSessionComplete(label: "Deep work", focusMinutes: 42, focusPercent: 84)
        presenter.presentBreakOver()
        presenter.presentDriftPrompt(host: "youtube.com")
        presenter.presentDailySummary(focusMinutes: 200, goalMinutes: 240)
    }

    func testEverythingIsSentByDefault() {
        sendEverything()
        XCTAssertEqual(sent.count, 5)
    }

    func testMasterSwitchSilencesEverything() {
        defaults.set(false, forKey: SettingsKeys.showNotifications)
        sendEverything()
        XCTAssertTrue(sent.isEmpty)
    }

    func testDriftSwitchSilencesOnlyDriftWarnings() {
        defaults.set(false, forKey: SettingsKeys.Escalation.notificationsEnabled)
        sendEverything()
        XCTAssertEqual(sent.count, 4)
        XCTAssertFalse(sent.contains { $0.content.body.contains("drifted to") })
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
}
