import Foundation
import UserNotifications

/// Boundary the EscalationEngine talks to when it wants to nudge the user.
/// Concrete implementation routes to `UNUserNotificationCenter`; tests pass
/// in a recording stub.
@MainActor
protocol DistractionNotifier: AnyObject {
    func presentDistractionWarning(appName: String, currentURL: String?)
}

/// What a nudge says about the session it interrupts. AppState provides it
/// when the nudge goes out.
struct NudgeContext: Equatable {
    /// "Evening focus".
    var sessionName: String
    /// Whole minutes left in a timed session; nil when it's open-ended.
    var minutesLeft: Int?
    /// The focus app "Back to …" returns to, while it's running.
    var backTo: String?
    /// The drifting app's bundle id, so "It's for work" knows what to allow.
    var bundleId: String?
}

/// Every notification FocusGuard sends, with its buttons. The buttons'
/// answers come back through `NotificationRouter`.
@MainActor
class NotificationPresenter: DistractionNotifier, LimitNotifying {
    /// What a notification is, for deciding whether settings allow it.
    enum Kind {
        /// The in-session "you've drifted" nudge. Silenced by either switch.
        case driftWarning
        /// Everything else: session complete, break over, drift prompt,
        /// habits, limits, the trial. Silenced only by the master switch.
        case general
    }

    let defaults: UserDefaults
    private let send: (UNNotificationRequest) -> Void
    private let register: (Set<UNNotificationCategory>) -> Void
    private let categories: NotificationCategories

    /// The running session, for the nudge's words. Set by AppState.
    var nudgeContext: () -> NudgeContext? = { nil }

    /// - Parameters:
    ///   - defaults: where the notification switches live; tests pass their own.
    ///   - send: delivers a request; defaults to the system notification center.
    ///   - register: hands macOS the buttons; defaults to the system
    ///     notification center, with the buttons every live presenter has used.
    init(defaults: UserDefaults = .standard,
         send: ((UNNotificationRequest) -> Void)? = nil,
         register: ((Set<UNNotificationCategory>) -> Void)? = nil) {
        self.defaults = defaults
        self.categories = register == nil ? .shared : NotificationCategories()
        self.send = send ?? { request in
            // Ask for the categories first: the reply comes after any
            // `setNotificationCategories` already sent, so a new set of
            // buttons is in place before the notification shows.
            let center = UNUserNotificationCenter.current()
            center.getNotificationCategories { _ in center.add(request) { _ in } }
        }
        self.register = register ?? { UNUserNotificationCenter.current().setNotificationCategories($0) }
    }

    /// Settings → General → "Show notifications" is the master switch;
    /// Settings → Escalation → "Motivational notification" covers drift
    /// warnings only. Both default to on. Read at send time so a change
    /// applies straight away.
    func allows(_ kind: Kind) -> Bool {
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        guard flag(SettingsKeys.showNotifications) else { return false }
        if kind == .driftWarning { return flag(SettingsKeys.Escalation.notificationsEnabled) }
        return true
    }

    func deliver(_ request: UNNotificationRequest, as kind: Kind, force: Bool = false) {
        guard force || allows(kind) else { return }
        send(request)
    }

    /// The length "Start 50 minutes" starts: the one the menu would.
    var usualMinutes: Int { FocusActions.usualMinutes(defaults) }

    // MARK: - Buttons

    /// The category for these buttons. Titles change with the moment ("Back
    /// to Xcode", "Start 50 minutes") and macOS keeps buttons per category,
    /// so each set of titles gets its own: "nudge|Back to Xcode|It's for work".
    /// A new one is registered before the notification that uses it.
    func category(_ base: NotificationCategory, _ buttons: [(NotificationAction, String)]) -> String {
        guard !buttons.isEmpty else { return base.rawValue }
        let id = ([base.rawValue] + buttons.map(\.1)).joined(separator: NotificationCategory.separator)
        if categories.byID[id] == nil {
            categories.byID[id] = UNNotificationCategory(
                identifier: id,
                actions: buttons.map { UNNotificationAction(identifier: $0.0.rawValue, title: $0.1, options: $0.0.options) },
                intentIdentifiers: [],
                options: []
            )
            register(Set(categories.byID.values))
        }
        return id
    }

    static func request(_ id: String = UUID().uuidString, title: String, body: String,
                        category: String? = nil, info: [String: Any] = [:],
                        level: UNNotificationInterruptionLevel = .active) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil  // calm by default
        content.interruptionLevel = level
        if let category { content.categoryIdentifier = category }
        content.userInfo = info
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }

    // MARK: - During a session

    /// "Still on x.com?" with "Back to Xcode" and "It's for work".
    func presentDistractionWarning(appName: String, currentURL: String? = nil) {
        deliver(distractionWarning(appName: appName, currentURL: currentURL, context: nudgeContext()),
                as: .driftWarning)
    }

    /// Settings' "Send test notification": always delivers, so the user can
    /// check macOS lets notifications through even with nudges switched off.
    func presentTestNotification() {
        deliver(distractionWarning(appName: String(localized: "Test app"), currentURL: nil, context: nil), as: .driftWarning, force: true)
    }

    private func distractionWarning(appName: String, currentURL: String?, context: NudgeContext?) -> UNNotificationRequest {
        let place = BlockRequest.displayHost(currentURL) ?? appName
        let body: String
        if let context {
            switch (context.minutesLeft, context.backTo) {
            case let (minutes?, app?):
                body = String(localized: "\(context.sessionName) has \(minutes) minutes left. \(app) is one click away.", comment: "Plural on minutes: 1 minute / 2 minutes")
            case let (minutes?, nil):
                body = String(localized: "\(context.sessionName) has \(minutes) minutes left.", comment: "Plural on minutes: 1 minute / 2 minutes")
            case let (nil, app?):
                body = String(localized: "\(context.sessionName) is still running. \(app) is one click away.")
            case (nil, nil):
                body = String(localized: "\(context.sessionName) is still running.")
            }
        } else {
            body = String(localized: "You've drifted to \(place).")
        }
        var info: [String: Any] = [:]
        if let currentURL { info[NotificationInfo.url] = currentURL }
        if let id = context?.bundleId { info[NotificationInfo.bundleId] = id }
        let back = context?.backTo.map { String(localized: "Back to \($0)") } ?? String(localized: "Back to work")
        return Self.request(title: String(localized: "Still on \(place)?"), body: body,
                            category: category(.nudge, [(.backToWork, back), (.forWork, String(localized: "It's for work"))]),
                            info: info)
    }

    /// "Session complete: Locked-in Deep Dive", with a break and another session.
    func presentSessionComplete(name: String, minutes: Int, focusPercent: Int?, zoneMinutes: Int, breakMinutes: Int) {
        let body: String
        if let focusPercent {
            body = zoneMinutes > 0
                ? String(localized: "\(minutes) min · \(focusPercent)% focused · \(zoneMinutes) min in the zone.", comment: "Compact minutes")
                : String(localized: "\(minutes) min · \(focusPercent)% focused.", comment: "Compact minutes")
        } else {
            body = String(localized: "\(minutes) min", comment: "Compact minutes") + "."
        }
        let request = Self.request(
            title: String(localized: "Session complete: \(name)"),
            body: body,
            category: category(.sessionComplete, [(.takeBreak, String(localized: "Take a \(breakMinutes)-minute break")),
                                                  (.startSession, String(localized: "Start another"))]),
            info: [NotificationInfo.minutes: breakMinutes, NotificationInfo.nextMinutes: usualMinutes]
        )
        deliver(request, as: .general)
    }

    /// Shown when a break timer hits zero. Friendly nudge — no urgency.
    func presentBreakOver() {
        let minutes = usualMinutes
        let request = Self.request(
            "breakOver",
            title: String(localized: "Break's over"),
            body: String(localized: "Ready for another \(minutes) minutes? Blocking comes back when you start.", comment: "Plural on minutes: 1 minute / 2 minutes"),
            category: category(.breakOver, [(.startSession, String(localized: "Start \(minutes) minutes", comment: "Plural on minutes: 1 minute / 2 minutes")),
                                            (.extendBreak, String(localized: "5 more minutes"))]),
            info: [NotificationInfo.minutes: minutes]
        )
        deliver(request, as: .general)
    }

    // MARK: - Around the day

    /// Shown when the PatternDetector spots repeated visits to the same
    /// distraction host while no session is active.
    func presentDriftPrompt(host: String) {
        let minutes = usualMinutes
        let request = Self.request(
            "driftPrompt-\(host)",
            title: String(localized: "Drifting?"),
            body: String(localized: "You've been on \(host) a few times in the last 10 min. Start a focus session?"),
            category: category(.driftPrompt, [(.startSession, String(localized: "Start \(minutes) minutes", comment: "Plural on minutes: 1 minute / 2 minutes"))]),
            info: [NotificationInfo.minutes: minutes]
        )
        deliver(request, as: .general)
    }

    /// Five minutes before a daily limit runs out, while the user is on it.
    func presentLimitWarning(name: String, minutesLeft: Int, minutesToday: Int) {
        let used = max(0, minutesToday - minutesLeft)
        let request = Self.request(
            "limitWarning-\(name)",
            title: String(localized: "\(minutesLeft) minutes left on \(name)", comment: "Plural on minutesLeft: 1 minute / 2 minutes"),
            body: String(localized: "You've used \(used) of your \(minutesToday) minutes today.", comment: "Plural on minutesToday: 1 minute / 2 minutes")
        )
        deliver(request, as: .general)
    }
}

/// Every set of buttons used so far, by category identifier. macOS replaces
/// the whole list each time it's set, so the app's presenters (AppState's,
/// and the trial reminder's) share one.
@MainActor
final class NotificationCategories {
    static let shared = NotificationCategories()
    var byID: [String: UNNotificationCategory] = [:]
}

/// What a notification is, and so which buttons it has. A category's
/// identifier is this plus the button titles (`NotificationPresenter.category`).
enum NotificationCategory: String, CaseIterable {
    case nudge, sessionComplete, breakOver, driftPrompt
    case morningPlan, plannedSession, autoStart, wrapUp, trialEnding

    static let separator = "|"

    /// The kind of notification a category identifier belongs to.
    init?(identifier: String) {
        let base = identifier.components(separatedBy: Self.separator).first ?? identifier
        self.init(rawValue: base)
    }
}

/// The buttons on FocusGuard's notifications.
enum NotificationAction: String, CaseIterable {
    case backToWork, forWork
    case takeBreak, startSession, extendBreak
    case planThem, notToday, skip, notNow
    case seeToday, seePlans

    /// Buttons that open a window bring FocusGuard forward.
    var options: UNNotificationActionOptions {
        switch self {
        case .seeToday, .seePlans: return [.foreground]
        default: return []
        }
    }
}

/// Keys in a notification's `userInfo`.
enum NotificationInfo {
    /// A session or break length, in minutes.
    static let minutes = "minutes"
    /// "Start another": the next session's length.
    static let nextMinutes = "nextMinutes"
    /// The drifting page.
    static let url = "url"
    static let bundleId = "bundleId"
    /// When the auto-start offer's focus began (seconds since 1970).
    static let since = "since"
    /// The morning plan's free slots (seconds since 1970).
    static let slots = "slots"
    /// The planned slot a "Time for your session" notification is about.
    static let slot = "slot"
}
