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

    /// Shown when a break timer hits zero. Friendly nudge — no urgency.
    func presentBreakOver() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Break's over"
        content.body = "Ready to start another session?"
        content.sound = nil
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: "breakOver", content: content, trigger: nil)
        center.add(request) { _ in }
    }

    /// Shown when the PatternDetector spots repeated visits to the same
    /// distraction host while no session is active.
    func presentDriftPrompt(host: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Drifting?"
        content.body = "You've been on \(host) a few times in the last 10 min — start a focus session?"
        content.sound = nil
        content.interruptionLevel = .active
        content.categoryIdentifier = "driftPrompt"
        let request = UNNotificationRequest(identifier: "driftPrompt-\(host)", content: content, trigger: nil)
        center.add(request) { _ in }
    }

    /// End-of-day wrap-up. Fired once per day after 9pm local time when the
    /// user's been inactive long enough that we're comfortable saying the day
    /// is "done".
    func presentDailySummary(focusMinutes: Int, goalMinutes: Int) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        if focusMinutes >= goalMinutes {
            content.title = "Goal hit"
            let over = focusMinutes - goalMinutes
            content.body = over > 0
                ? "\(FocusGoal.format(minutes: focusMinutes)) of focus today — \(FocusGoal.format(minutes: over)) over your \(FocusGoal.format(minutes: goalMinutes)) goal."
                : "You hit your \(FocusGoal.format(minutes: goalMinutes)) focus goal today."
        } else {
            content.title = "Day's wrap-up"
            let short = goalMinutes - focusMinutes
            content.body = "\(FocusGoal.format(minutes: focusMinutes)) of focus today — \(FocusGoal.format(minutes: short)) short of your \(FocusGoal.format(minutes: goalMinutes)) goal."
        }
        content.sound = nil
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: "dailySummary", content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
