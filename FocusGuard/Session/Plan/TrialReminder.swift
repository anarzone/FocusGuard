import Foundation
import UserNotifications

/// The trial reminder, sent like the app's other notifications and behind
/// the same "Show notifications" switch.
extension NotificationPresenter: TrialReminding {
    /// True when it counts as sent now. On the island that comes later, when
    /// the card really shows (`Entitlements.noteTrialReminderShown`).
    @discardableResult
    func presentTrialEndingSoon(endsAt: Date, now: Date = .now) -> Bool {
        let buttons = category(.trialEnding, [(.seePlans, String(localized: "See plans"))])
        let request = Self.trialEndingSoon(endsAt: endsAt, category: buttons)
        let left = max(1, Int((endsAt.timeIntervalSince(now) / 86_400).rounded(.up)))
        return deliver(request, as: .general, moment: trialMoment(daysLeft: left)) == .sent && macOSAllows()
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
