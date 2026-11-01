import EventKit
import Foundation

/// The Integrations switches that sign in to nothing: the calendar beyond
/// auto-start (`SettingsKeys.Calendar`), Reminders and Git.
enum IntegrationSettings {
    /// Each session goes on a calendar as busy time.
    static let sessionsOnCalendar = "integrations.calendar.writeSessions"
    /// The calendar they go on; missing or empty means the default one.
    static let sessionsCalendar = "integrations.calendar.writeCalendarID"
    /// The menu shows the next meeting from 30 minutes before.
    static let nextMeeting = "integrations.calendar.nextMeeting"
    /// The calendars FocusGuard reads; missing or empty means all of them.
    static let readCalendars = "integrations.calendar.readCalendarIDs"
    /// Open reminders are offered as session goals (Pro).
    static let reminders = "integrations.reminders.enabled"
    /// The lists they come from; missing or empty means all of them.
    static let reminderLists = "integrations.reminders.listIDs"
    /// The Git branch is offered as a session goal.
    static let gitBranch = "integrations.git.enabled"
    /// The folder the repos are in; missing means ~/Projects.
    static let gitFolder = "integrations.git.folder"

    /// Next meeting and the Git branch default to on; they ask for nothing
    /// new. Writing to the calendar and Reminders wait to be turned on.
    static func isOn(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? (key == nextMeeting || key == gitBranch)
    }

    static func ids(_ key: String, _ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func gitFolder(_ defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: gitFolder), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects", isDirectory: true)
    }

    /// "~/Projects", for the settings.
    static func shortPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The calendars to read events from, for a predicate: nil for all of
    /// them, also when none of the chosen ones is left.
    static func readCalendars(in store: EKEventStore, _ defaults: UserDefaults = .standard) -> [EKCalendar]? {
        let chosen = Set(ids(readCalendars, defaults))
        guard !chosen.isEmpty else { return nil }
        let found = store.calendars(for: .event).filter { chosen.contains($0.calendarIdentifier) }
        return found.isEmpty ? nil : found
    }
}

/// Calendar and Reminders access, as EventKit has it now.
enum EventKitAccess {
    enum State: Equatable {
        case notDetermined
        case denied
        case granted
    }

    /// Full access to events: reading meetings and writing sessions both need it.
    static var calendars: State { state(.event) }
    static var reminders: State { state(.reminder) }

    private static func state(_ type: EKEntityType) -> State {
        switch EKEventStore.authorizationStatus(for: type) {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .granted
        default: return .denied
        }
    }
}

/// Events FocusGuard wrote, told apart from the user's own: they carry a
/// `focusguard://session` link, and their identifiers are kept
/// (`SessionCalendarWriter`). Only those are ever changed or removed.
enum OwnEvents {
    static let host = "session"
    static let note = "Added by FocusGuard."

    /// `focusguard://session?id=<key>`.
    static func link(key: String) -> URL? {
        var components = URLComponents()
        components.scheme = FocusGuardURL.scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: key)]
        return components.url
    }

    /// The key in an event's link, when FocusGuard wrote it.
    static func key(in url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == FocusGuardURL.scheme, url.host?.lowercased() == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
    }

    static func isOwn(_ event: EKEvent, ids: Set<String>) -> Bool {
        if let id = event.eventIdentifier, ids.contains(id) { return true }
        return key(in: event.url) != nil || event.notes?.hasPrefix(note) == true
    }

    /// Kept by `SessionCalendarWriter`; read here so the calendar readers
    /// can leave FocusGuard's own events out without a writer at hand.
    static func ids(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: SessionCalendarWriter.ownIDsKey) ?? [])
    }
}
