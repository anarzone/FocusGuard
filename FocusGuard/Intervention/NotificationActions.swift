import Foundation
import UserNotifications

/// What a click on a notification, or one of its buttons, asks for.
enum NotificationCommand: Equatable {
    /// "Back to Xcode".
    case backToWork
    /// "It's for work": stop nudging about this page or app this session.
    case allowForSession(url: String?, bundleId: String?)
    case takeBreak(minutes: Int)
    /// Nil minutes: the usual length.
    case startSession(minutes: Int?)
    /// The auto-start offer's "Start 50 minutes": counts from `since` while
    /// that focus is still going.
    case startFromOffer(since: Date, minutes: Int?)
    /// The auto-start offer's "Not now".
    case snoozeAutoStart
    /// The morning plan's "Plan them".
    case planSessions([Date])
    case openToday
    case openPlans

    /// Nil for buttons that only dismiss ("Not today", "Skip this one").
    init?(action: String, category identifier: String, info: [AnyHashable: Any]) {
        guard let category = NotificationCategory(identifier: identifier) else {
            // Notifications without buttons (the daily-limit warning): a
            // click just opens Today.
            if action == UNNotificationDefaultActionIdentifier { self = .openToday; return }
            return nil
        }
        let minutes = info[NotificationInfo.minutes] as? Int

        if action == UNNotificationDefaultActionIdentifier {
            switch category {
            case .nudge:       self = .backToWork
            case .trialEnding: self = .openPlans
            default:           self = .openToday
            }
            return
        }

        switch (category, NotificationAction(rawValue: action)) {
        case (.nudge, .backToWork?):
            self = .backToWork
        case (.nudge, .forWork?):
            self = .allowForSession(url: info[NotificationInfo.url] as? String,
                                    bundleId: info[NotificationInfo.bundleId] as? String)
        case (.sessionComplete, .takeBreak?):
            self = .takeBreak(minutes: minutes ?? 10)
        case (.sessionComplete, .startSession?):
            self = .startSession(minutes: info[NotificationInfo.nextMinutes] as? Int)
        case (.breakOver, .extendBreak?):
            self = .takeBreak(minutes: 5)
        case (.breakOver, .startSession?), (.driftPrompt, .startSession?), (.plannedSession, .startSession?):
            self = .startSession(minutes: minutes)
        case (.autoStart, .startSession?):
            guard let since = info[NotificationInfo.since] as? Double else {
                self = .startSession(minutes: minutes)
                return
            }
            self = .startFromOffer(since: Date(timeIntervalSinceReferenceDate: since), minutes: minutes)
        case (.autoStart, .notNow?):
            self = .snoozeAutoStart
        case (.morningPlan, .planThem?):
            let slots = (info[NotificationInfo.slots] as? [Double]) ?? []
            self = .planSessions(slots.map(Date.init(timeIntervalSinceReferenceDate:)))
        case (.wrapUp, .seeToday?):
            self = .openToday
        case (.trialEnding, .seePlans?):
            self = .openPlans
        default:
            return nil
        }
    }
}

/// Receives notification clicks and button presses, and shows FocusGuard's
/// notifications even while one of its windows is in front.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Carries a command out. Set by AppState.
    @MainActor var perform: (NotificationCommand) -> Void = { _ in }

    @MainActor func attach() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let command = NotificationCommand(action: response.actionIdentifier,
                                          category: content.categoryIdentifier, info: content.userInfo)
        Task { @MainActor in
            if let command { self.perform(command) }
            completionHandler()
        }
    }
}
