import AppKit
import Foundation
import Observation

/// Linear's OAuth with PKCE, so the app holds no secret: the browser opens
/// Linear's consent page and comes back to a listener on 127.0.0.1 that only
/// lives for the sign-in, on its own fixed port since the redirect has to be
/// registered as it is. Access tokens last 24 hours; each refresh, which needs
/// only the Client ID, brings a new refresh token.
///
/// `read` is always there; `issues:create` is what Linear documents for
/// creating and updating issues, which covers moving one to done.
enum LinearOAuth {
    static let authorizeEndpoint = "https://linear.app/oauth/authorize"
    static let tokenURL = URL(string: "https://api.linear.app/oauth/token")!
    static let revokeURL = URL(string: "https://api.linear.app/oauth/revoke")!
    static let scopes = "read,issues:create"
    /// Must match the redirect URL registered for the Client ID.
    static let redirectPort: UInt16 = 47182
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

    static func authorizeURL(clientID: String, verifier: String, state: String) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        components?.percentEncodedQuery = PKCE.formEncoded([
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "response_type": "code",
            "scope": scopes,
            "state": state,
            "code_challenge": PKCE.challenge(for: verifier),
            "code_challenge_method": "S256",
        ])
        return components?.url
    }

    /// The code for tokens: no secret, the verifier instead.
    static func exchangeRequest(clientID: String, code: String, verifier: String) -> URLRequest {
        formRequest(tokenURL, ["client_id": clientID, "code": code, "code_verifier": verifier,
                               "grant_type": "authorization_code", "redirect_uri": redirectURI])
    }

    static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        formRequest(tokenURL, ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    /// One for each token held, the refresh token first.
    static func revokeRequests(_ tokens: SignInTokens) -> [URLRequest] {
        var requests: [URLRequest] = []
        if let refresh = tokens.refresh {
            requests.append(formRequest(revokeURL, ["token": refresh, "token_type_hint": "refresh_token"]))
        }
        requests.append(formRequest(revokeURL, ["token": tokens.access, "token_type_hint": "access_token"]))
        return requests
    }

    private static func formRequest(_ url: URL, _ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(PKCE.formEncoded(form).utf8)
        return request
    }

    /// What came back to the listener.
    enum Callback: Equatable {
        case code(String)
        /// The user said no on Linear's page.
        case denied
        /// Not the state FocusGuard sent, or no code: not a sign-in to trust.
        case failed
    }

    static func read(_ callback: [String: String], state: String) -> Callback {
        guard callback["state"] == state else { return .failed }
        if callback["error"] == "access_denied" { return .denied }
        guard let code = callback["code"], !code.isEmpty else { return .failed }
        return .code(code)
    }
}

/// Waits for the browser to come back; `LoopbackReceiver`, or a test's.
protocol RedirectReceiver: AnyObject {
    func start(port: UInt16?) async throws -> UInt16
    func waitForCallback() async throws -> [String: String]
    func stop()
}

extension LoopbackReceiver: RedirectReceiver {}

/// Connecting Linear in Settings: opens the browser and waits for it.
@MainActor
@Observable
final class LinearSignIn {
    enum Phase: Equatable {
        case idle
        case waiting
        case failed
    }

    private(set) var phase = Phase.idle

    /// FocusGuard's Linear app (Info.plist `FGLinearClientID`).
    @ObservationIgnored let clientID: String
    @ObservationIgnored let tokens: RotatingTokens
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// After the tokens are saved.
    @ObservationIgnored var onConnected: () -> Void = {}
    @ObservationIgnored var makeReceiver: () -> RedirectReceiver = {
        LoopbackReceiver(signedIn: String(localized: "Signed in to Linear. You can close this tab and go back to FocusGuard."),
                         refused: String(localized: "FocusGuard didn't get permission from Linear. You can close this tab."))
    }
    @ObservationIgnored private var receiver: RedirectReceiver?
    /// The wait and the exchange; tests wait for it.
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    init(clientID: String, store: TokenStore = TaskTokens.signInKeychain(for: .linear), session: URLSession = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.clientID = clientID
        self.session = session
        self.now = now
        self.tokens = RotatingTokens(store: store, now: now) { refreshToken in
            await TokenRenewal.fetch(LinearOAuth.refreshRequest(clientID: clientID, refreshToken: refreshToken),
                                     session: session, staysOn: LinearTasks.isLinear, now: now())
        }
    }

    /// Nil, which keeps Linear's row as it was, until the app is registered.
    static func bundled() -> LinearSignIn? {
        StatusSync.infoValue("FGLinearClientID").map { LinearSignIn(clientID: $0) }
    }

    func start() {
        guard !UITestMode.isOn, running == nil else { return }
        phase = .waiting
        running = Task { await signIn() }
    }

    /// Gives up waiting for the browser.
    func cancel() {
        running?.cancel()
        running = nil
        receiver?.stop()
        receiver = nil
        phase = .idle
    }

    private func signIn() async {
        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        let receiver = makeReceiver()
        self.receiver = receiver
        do {
            _ = try await receiver.start(port: LinearOAuth.redirectPort)
            guard !Task.isCancelled,
                  let url = LinearOAuth.authorizeURL(clientID: clientID, verifier: verifier, state: state) else {
                receiver.stop()
                return
            }
            openURL(url)
            let callback = try await receiver.waitForCallback()
            guard !Task.isCancelled else { return }
            switch LinearOAuth.read(callback, state: state) {
            case .denied:
                finish(.idle)
            case .failed:
                finish(.failed)
            case .code(let code):
                let request = LinearOAuth.exchangeRequest(clientID: clientID, code: code, verifier: verifier)
                let (data, response) = try await TaskWeb.exchange(request, session: session, staysOn: LinearTasks.isLinear)
                guard !Task.isCancelled else { return }
                guard (200..<300).contains(response.statusCode),
                      let signedIn = TokenAnswer.parse(data)?.tokens(now: now()) else {
                    finish(.failed)
                    return
                }
                tokens.save(signedIn)
                finish(.idle)
                onConnected()
            }
        } catch {
            receiver.stop()
            finish(.failed)
        }
    }

    private func finish(_ phase: Phase) {
        guard !Task.isCancelled else { return }
        running = nil
        receiver = nil
        self.phase = phase
    }
}
