import Foundation
import UserNotifications

/// The trial reminder, sent like the app's other notifications and behind
/// the same "Show notifications" switch.
extension NotificationPresenter: TrialReminding {
    func presentTrialEndingSoon(endsAt: Date) {
        let buttons = category(.trialEnding, [(.seePlans, String(localized: "See Free and Pro"))])
        let request = Self.trialEndingSoon(endsAt: endsAt, category: buttons)
        deliver(request, as: .general, moment: trialMoment(title: request.content.title, body: request.content.body))
    }

    static func trialEndingSoon(endsAt: Date, category: String? = nil) -> UNNotificationRequest {
        request(
            "trialEndingSoon",
            title: String(localized: "Your Pro trial ends in \(Plan.trialReminderDays) days", comment: "Plural on the days: ends in 1 day"),
            body: String(localized: "It ends on \(endsAt.formatted(.dateTime.day().month(.wide))). Nothing renews on its own: after that you're on Free."),
            category: category
        )
    }
}
