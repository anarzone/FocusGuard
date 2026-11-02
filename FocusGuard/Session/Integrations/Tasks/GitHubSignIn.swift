import AppKit
import Foundation
import Observation

/// GitHub's device flow, for FocusGuard's GitHub App: no secret and no
/// redirect. The app asks for a code, the user enters it on GitHub's page, and
/// the app polls until they've said yes. A GitHub App rather than an OAuth App
/// because an OAuth App would need `repo`, all of the user's private code; this
/// one only asks for Issues.
///
/// Its user tokens last 8 hours; each refresh brings a new refresh token, good
/// for six months, and needs no secret for a token from this flow. GitHub can't
/// revoke one without the app's secret (`DELETE /applications/{id}/token` takes
/// Basic auth), so Disconnect only clears the Keychain: the user can remove the
/// app under GitHub › Settings › Applications.
enum GitHubDeviceFlow {
    static let codeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let page = URL(string: "https://github.com/login/device")!
    static let grantType = "urn:ietf:params:oauth:grant-type:device_code"
    /// What `slow_down` adds to the wait between polls.
    static let slowDownStep: TimeInterval = 5

    /// The code to enter, and for how long.
    struct Code: Decodable, Equatable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String?
        let expiresIn: Int?
        let interval: Int?

        /// How long the code lasts; GitHub's default is 15 minutes.
        var lifetime: TimeInterval { TimeInterval(expiresIn ?? 900) }
        var pollInterval: TimeInterval { TimeInterval(max(interval ?? 5, 1)) }

        /// The page to enter it on, GitHub's own whatever the answer says.
        var pageURL: URL {
            guard let url = verificationUri.flatMap(URL.init(string:)), isLogin(url) else { return page }
            return url
        }
    }

    /// What polling says.
    enum Poll: Equatable, Sendable {
        case signedIn(SignInTokens)
        case pending
        case slowDown(TimeInterval?)
        case expired
        /// The user said no on GitHub's page.
        case denied
        /// Device flow is off in the app's settings.
        case disabled
        /// The Client ID isn't the app's.
        case badClient
        /// Anything else that won't get better by waiting.
        case failed
    }

    // MARK: - Requests

    static func codeRequest(clientID: String) -> URLRequest {
        formRequest(codeURL, ["client_id": clientID])
    }

    static func pollRequest(clientID: String, deviceCode: String) -> URLRequest {
        formRequest(tokenURL, ["client_id": clientID, "device_code": deviceCode, "grant_type": grantType])
    }

    static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        formRequest(tokenURL, ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    private static func formRequest(_ url: URL, _ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("FocusGuard", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(PKCE.formEncoded(form).utf8)
        return request
    }

    /// Codes and refresh tokens only ever go to github.com, over https.
    @Sendable static func isLogin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == page.host && url.port == nil
    }

    // MARK: - The flow

    /// A code to show. `TaskSourceProblem.rejected` means GitHub won't give one
    /// to this app; `.unreachable`, that it can't be asked now.
    static func requestCode(clientID: String, session: URLSession) async throws -> Code {
        let (data, response) = try await TaskWeb.exchange(codeRequest(clientID: clientID), session: session, staysOn: isLogin)
        guard response.statusCode < 500 else { throw TaskSourceProblem.unreachable }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let code = try? decoder.decode(Code.self, from: data) else { throw TaskSourceProblem.rejected }
        return code
    }

    /// One poll's answer. GitHub says all of this with a 200; an answer that
    /// can't be read may be better next time.
    static func poll(data: Data, now: Date) -> Poll {
        guard let answer = TokenAnswer.parse(data) else { return .pending }
        if let tokens = answer.tokens(now: now) { return .signedIn(tokens) }
        switch answer.error {
        case nil, "authorization_pending":     return .pending
        case "slow_down":                      return .slowDown(answer.interval.map(TimeInterval.init))
        case "expired_token", "token_expired": return .expired
        case "access_denied":                  return .denied
        case "device_flow_disabled":           return .disabled
        case "incorrect_client_credentials":   return .badClient
        default:                               return .failed
        }
    }

    /// Polls at the pace GitHub asks for, until there's an answer that isn't
    /// "not yet" or the code runs out. Off the main thread, and it throws when
    /// its task is cancelled. No connection just means trying again next time.
    static func waitForTokens(clientID: String, code: Code, session: URLSession,
                              now: @Sendable () -> Date = { Date() },
                              sleep: @Sendable (TimeInterval) async throws -> Void) async throws -> Poll {
        let deadline = now().addingTimeInterval(code.lifetime)
        var interval = code.pollInterval
        while true {
            try await sleep(interval)
            guard now() < deadline else { return .expired }
            let request = pollRequest(clientID: clientID, deviceCode: code.deviceCode)
            let answer: Poll
            if let (data, _) = try? await TaskWeb.exchange(request, session: session, staysOn: isLogin) {
                answer = poll(data: data, now: now())
            } else {
                answer = .pending
            }
            try Task.checkCancellation()
            switch answer {
            case .pending:             continue
            case .slowDown(let given): interval = max(interval + slowDownStep, given ?? 0)
            default:                   return answer
            }
        }
    }
}

/// Connecting GitHub in Settings: shows the code, opens the page, polls.
@MainActor
@Observable
final class GitHubSignIn {
    enum Phase: Equatable {
        case idle
        case asking
        /// The code, while polling.
        case showing(GitHubDeviceFlow.Code)
        case failed(Failure)
    }

    enum Failure: Equatable {
        /// The code ran out before the user finished.
        case expired
        /// GitHub won't sign this app in: device flow off, or a wrong ID.
        case unavailable
        case unreachable
    }

    private(set) var phase = Phase.idle

    /// FocusGuard's GitHub App (Info.plist `FGGitHubClientID`).
    @ObservationIgnored let clientID: String
    /// Its slug (Info.plist `FGGitHubAppSlug`), for the install page.
    @ObservationIgnored let appSlug: String?
    @ObservationIgnored let tokens: RotatingTokens
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// After the tokens are saved.
    @ObservationIgnored var onConnected: () -> Void = {}
    /// The code and the polling; tests wait for it.
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    init(clientID: String, appSlug: String?, store: TokenStore = TaskTokens.signInKeychain(for: .github),
         session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.clientID = clientID
        self.appSlug = appSlug
        self.session = session
        self.now = now
        self.sleep = sleep
        self.tokens = RotatingTokens(store: store, now: now) { refreshToken in
            await TokenRenewal.fetch(GitHubDeviceFlow.refreshRequest(clientID: clientID, refreshToken: refreshToken),
                                     session: session, staysOn: GitHubDeviceFlow.isLogin, now: now())
        }
    }

    /// Nil, which keeps GitHub's row as it was, until the app is registered.
    static func bundled() -> GitHubSignIn? {
        StatusSync.infoValue("FGGitHubClientID").map {
            GitHubSignIn(clientID: $0, appSlug: StatusSync.infoValue("FGGitHubAppSlug"))
        }
    }

    /// Where the app gets installed on an account or organization.
    var installURL: URL? {
        appSlug.flatMap { URL(string: "https://github.com/apps/\($0)/installations/new") }
    }

    func start() {
        guard !UITestMode.isOn, running == nil else { return }
        phase = .asking
        running = Task { await signIn() }
    }

    /// Stops polling: the Settings row went away, or the user changed their mind.
    func cancel() {
        running?.cancel()
        running = nil
        phase = .idle
    }

    private func signIn() async {
        let code: GitHubDeviceFlow.Code
        do {
            code = try await GitHubDeviceFlow.requestCode(clientID: clientID, session: session)
        } catch {
            finish(.failed(error as? TaskSourceProblem == .rejected ? .unavailable : .unreachable))
            return
        }
        guard !Task.isCancelled else { return }
        phase = .showing(code)
        openURL(code.pageURL)
        guard let answer = try? await GitHubDeviceFlow.waitForTokens(clientID: clientID, code: code, session: session,
                                                                     now: now, sleep: sleep) else {
            finish(.idle)
            return
        }
        guard !Task.isCancelled else { return }
        switch answer {
        case .signedIn(let signedIn):
            tokens.save(signedIn)
            finish(.idle)
            onConnected()
        case .denied:  finish(.idle)
        case .expired: finish(.failed(.expired))
        default:       finish(.failed(.unavailable))
        }
    }

    private func finish(_ phase: Phase) {
        guard !Task.isCancelled else { return }
        running = nil
        self.phase = phase
    }
}
