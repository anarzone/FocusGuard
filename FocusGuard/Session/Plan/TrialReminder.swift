import Foundation
import UserNotifications

/// The trial reminder, sent like the app's other notifications and behind
/// the same "Show notifications" switch.
extension NotificationPresenter: TrialReminding {
    func presentTrialEndingSoon(endsAt: Date) {
        let buttons = category(.trialEnding, [(.seePlans, "See Free and Pro")])
        deliver(Self.trialEndingSoon(endsAt: endsAt, category: buttons), as: .general)
    }

    static func trialEndingSoon(endsAt: Date, category: String? = nil) -> UNNotificationRequest {
        request(
            "trialEndingSoon",
            title: "Your Pro trial ends in \(Plan.trialReminderDays) days",
            body: "It ends on \(endsAt.formatted(.dateTime.day().month(.wide))). "
                + "Nothing renews on its own: after that you're on Free.",
            category: category
        )
    }
}
