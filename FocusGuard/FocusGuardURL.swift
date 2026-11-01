import Foundation

/// The app's own links, `focusguard://…`, registered in project.yml and
/// opened by `AppDelegate`. The paused-tab page calls them today; widgets,
/// Control Center and Shortcuts can add their routes here rather than
/// registering another scheme.
enum FocusGuardURL: Equatable {
    /// Back to the last focus app.
    case back
    /// Reopen this paused tab when the session ends.
    case reopenLater(pauseID: String)
    /// Undo `reopenLater`: the tab stays paused.
    case keepPaused(pauseID: String)
    /// Start a break of this many minutes.
    case startBreak(minutes: Int)
    /// Slack's sign-in coming back (`SlackAccount`): a code, or an error
    /// such as "access_denied", with the state FocusGuard sent.
    case slackAuth(code: String?, state: String, error: String?)

    static let scheme = "focusguard"
    static let breakMinutes = 1...60

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let route = ([components.host ?? ""] + url.pathComponents.filter { $0 != "/" })
            .filter { !$0.isEmpty }
            .joined(separator: "/")
            .lowercased()
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }

        switch route {
        case "back":
            self = .back
        case "tab/reopen-later":
            guard let id = value("id"), PausedPage.isValidID(id) else { return nil }
            self = .reopenLater(pauseID: id)
        case "tab/keep-paused":
            guard let id = value("id"), PausedPage.isValidID(id) else { return nil }
            self = .keepPaused(pauseID: id)
        case "break":
            let minutes = value("minutes").flatMap(Int.init) ?? 10
            self = .startBreak(minutes: min(max(minutes, Self.breakMinutes.lowerBound), Self.breakMinutes.upperBound))
        case "slack-auth":
            guard let state = value("state") else { return nil }
            self = .slackAuth(code: value("code"), state: state, error: value("error"))
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .back:
            components.host = "back"
        case .reopenLater(let id):
            components.host = "tab"
            components.path = "/reopen-later"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .keepPaused(let id):
            components.host = "tab"
            components.path = "/keep-paused"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .startBreak(let minutes):
            components.host = "break"
            components.queryItems = [URLQueryItem(name: "minutes", value: String(minutes))]
        case .slackAuth(let code, let state, let error):
            components.host = "slack-auth"
            components.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state),
                                     URLQueryItem(name: "error", value: error)].filter { $0.value != nil }
        }
        return components.url ?? URL(string: "\(Self.scheme)://back")!
    }
}
