import Foundation
import UserNotifications

/// Boundary the EscalationEngine talks to when it wants to nudge the user.
/// Concrete implementation routes to `UNUserNotificationCenter`; tests pass
/// in a recording stub.
@MainActor
protocol DistractionNotifier: AnyObject {
    func presentDistractionWarning(appName: String, currentURL: String?)
}

@MainActor
class NotificationPresenter: DistractionNotifier {
    func presentDistractionWarning(appName: String, currentURL: String? = nil) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = MotivationalMessages.random()
        if let host = currentURL.flatMap({ URL(string: $0)?.host }) {
            content.body = "You've drifted to \(host) (\(appName))."
        } else {
            content.body = "You've drifted to \(appName)."
        }
        content.sound = nil  // calm by default; user can flip in Settings later
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil    // deliver immediately
        )
        center.add(request) { _ in }
    }

    func presentSessionComplete(label: String?, focusMinutes: Int, focusPercent: Int) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Session complete"
        content.body = "\(focusMinutes) min focus · \(focusPercent)% focused" + (label.map { " · \($0)" } ?? "")
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
