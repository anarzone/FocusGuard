import XCTest
import UserNotifications
@testable import FocusGuard

/// What each notification button asks the app to do.
final class NotificationCommandTests: XCTestCase {
    private func command(_ action: NotificationAction, _ category: String,
                         _ info: [AnyHashable: Any] = [:]) -> NotificationCommand? {
        NotificationCommand(action: action.rawValue, category: category, info: info)
    }

    func testNudgeButtons() {
        let category = "nudge|Back to Xcode|It's for work"
        XCTAssertEqual(command(.backToWork, category), .backToWork)
        XCTAssertEqual(command(.forWork, category, [NotificationInfo.url: "https://x.com/home", NotificationInfo.bundleId: "com.google.Chrome"]),
                       .allowForSession(url: "https://x.com/home", bundleId: "com.google.Chrome"))
        XCTAssertEqual(NotificationCommand(action: UNNotificationDefaultActionIdentifier, category: category, info: [:]), .backToWork)
    }

    func testSessionAndBreakButtons() {
        let complete = "sessionComplete|Take a 10-minute break|Start another"
        XCTAssertEqual(command(.takeBreak, complete, [NotificationInfo.minutes: 10]), .takeBreak(minutes: 10))
        XCTAssertEqual(command(.startSession, complete, [NotificationInfo.minutes: 10, NotificationInfo.nextMinutes: 50]),
                       .startSession(minutes: 50))
        let breakOver = "breakOver|Start 50 minutes|5 more minutes"
        XCTAssertEqual(command(.startSession, breakOver, [NotificationInfo.minutes: 50]), .startSession(minutes: 50))
        XCTAssertEqual(command(.extendBreak, breakOver), .takeBreak(minutes: 5))
    }

    func testHabitButtons() {
        let since = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(command(.startSession, "autoStart|Start 50 minutes|Not now",
                               [NotificationInfo.since: since.timeIntervalSinceReferenceDate, NotificationInfo.minutes: 50]),
                       .startFromOffer(since: since, minutes: 50))
        XCTAssertEqual(command(.notNow, "autoStart|Start 50 minutes|Not now"), .snoozeAutoStart)

        let slots = [since, since.addingTimeInterval(3600)]
        XCTAssertEqual(command(.planThem, "morningPlan|Plan them|Not today",
                               [NotificationInfo.slots: slots.map(\.timeIntervalSinceReferenceDate)]),
                       .planSessions(slots))
        XCTAssertNil(command(.notToday, "morningPlan|Plan them|Not today"))
        XCTAssertNil(command(.skip, "plannedSession|Start 50 minutes|Skip this one"))
        XCTAssertEqual(command(.startSession, "plannedSession|Start 50 minutes|Skip this one", [NotificationInfo.minutes: 50]),
                       .startSession(minutes: 50))
        XCTAssertEqual(command(.seeToday, "wrapUp|See today"), .openToday)
        XCTAssertEqual(command(.seePlans, "trialEnding|See Free and Pro"), .openPlans)
    }

    func testClickingANotificationOpensSomethingSensible() {
        XCTAssertEqual(NotificationCommand(action: UNNotificationDefaultActionIdentifier, category: "wrapUp|See today", info: [:]), .openToday)
        XCTAssertEqual(NotificationCommand(action: UNNotificationDefaultActionIdentifier, category: "trialEnding|See Free and Pro", info: [:]), .openPlans)
        // The daily-limit warning has no buttons and no category.
        XCTAssertEqual(NotificationCommand(action: UNNotificationDefaultActionIdentifier, category: "", info: [:]), .openToday)
        XCTAssertNil(NotificationCommand(action: UNNotificationDismissActionIdentifier, category: "wrapUp|See today", info: [:]))
    }

    func testButtonTitlesCantConfuseTheKind() {
        // A title with the separator in it still leaves the kind first.
        XCTAssertEqual(NotificationCategory(identifier: "nudge|Back to A|B|It's for work"), .nudge)
        XCTAssertNil(NotificationCategory(identifier: "somethingElse|Go"))
    }
}
