import Foundation
import UserNotifications

/// The trial reminder, sent like the app's other notifications and behind
/// the same "Show notifications" switch.
extension NotificationPresenter: TrialReminding {
    func presentTrialEndingSoon(endsAt: Date) {
        guard allows(.general) else { return }
        UNUserNotificationCenter.current().add(Self.trialEndingSoon(endsAt: endsAt)) { _ in }
    }

    static func trialEndingSoon(endsAt: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Your Pro trial ends in \(Plan.trialReminderDays) days"
        content.body = "It ends on \(endsAt.formatted(.dateTime.day().month(.wide))). "
            + "Nothing renews on its own: after that you're on Free."
        content.sound = nil
        content.interruptionLevel = .active
        return UNNotificationRequest(identifier: "trialEndingSoon", content: content, trigger: nil)
    }
}
