import AppKit
import Foundation
import Observation

/// Sign-in to Slack for Status in Slack and Discord (Pro), and the four
/// calls it makes: set and clear the user's status, and snooze and
/// unsnooze their notifications (Do Not Disturb).
///
/// FocusGuard's Slack app has PKCE on, so the app holds no secret: the
/// browser opens Slack's consent page with a code challenge, Slack sends
/// the code back to `focusguard://slack-auth` (`FocusGuardURL.slackAuth`),
/// and it's exchanged with the verifier. A custom scheme always gets
/// rotating tokens: the access token lasts 12 hours and is refreshed, with
/// no secret either, before it runs out; each refresh brings a new refresh
/// token, good for 30 days. Both are kept in the Keychain.
///
/// Only two user scopes are asked for, `users.profile:write` and
/// `dnd:write`: FocusGuard can't read messages, channels, or even the
/// status it replaces.
@MainActor
@Observable
final class SlackAccount {
    enum Problem: Equatable {
        /// The sign-in didn't finish: a bad answer from Slack, or offline.
        case connectFailed
        /// Slack turned the tokens down: revoked, or unused for 30 days.
        case signedOut
    }

    /// What's kept in the Keychain.
    struct Tokens: Codable, Equatable {
        var access: String
        /// Nil for a token that doesn't rotate.
        var refresh: String?
        var expiresAt: Date?
        /// When the refresh token came; it lasts 30 days.
        var refreshedAt: Date
    }

    /// A sign-in waiting for the browser.
    struct Pending: Equatable {
        let verifier: String
        let state: String
        let startedAt: Date
    }

    private(set) var isConnected: Bool
    /// The workspace, "Acme".
    private(set) var teamName: String?
    private(set) var problem: Problem?
    private(set) var pending: Pending?
    var isWaiting: Bool { pending != nil }

    /// FocusGuard's Slack app (Info.plist `FGSlackClientID`); nil hides Slack.
    let clientID: String?
    var isConfigured: Bool { clientID != nil }

    @ObservationIgnored private let keychain: TokenStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// Sends a request; tests answer for Slack.
    @ObservationIgnored var send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Change the status, pause notifications. Nothing else.
    nonisolated static let scopes = "users.profile:write,dnd:write"
    /// Registered as the Slack app's redirect URL.
    nonisolated static let redirectURI = "focusguard://slack-auth"
    nonisolated static let teamKey = "integrations.slack.team"
    /// A sign-in waits this long: Slack's code is good for ten minutes.
    nonisolated static let pendingLimit: TimeInterval = 10 * 60
    /// The access token is refreshed this long before it runs out.
    nonisolated static let refreshLead: TimeInterval = 5 * 60
    /// The refresh token is renewed once it's this old, well inside its 30 days.
    nonisolated static let refreshTokenAge: TimeInterval = 20 * 86_400
    /// How long an access token lasts when Slack doesn't say: 12 hours.
    nonisolated static let defaultLifetime = 43_200
    /// The token ran out or isn't taken: refresh and try once more.
    nonisolated static let authErrors: Set<String> = ["token_expired", "invalid_auth"]
    /// Slack won't refresh: the user connects again.
    nonisolated static let signedOutErrors: Set<String> = [
        "invalid_refresh_token", "token_revoked", "token_expired", "invalid_grant", "invalid_auth", "account_inactive",
    ]

    init(clientID: String? = SlackAccount.bundledClientID,
         keychain: TokenStore = KeychainTokenStore(service: "com.anar.focusguard.slack", account: "tokens"),
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.clientID = clientID
        self.keychain = keychain
        self.defaults = defaults
        self.now = now
        self.isConnected = clientID != nil && keychain.read() != nil
        self.teamName = defaults.string(forKey: Self.teamKey)
    }

    nonisolated static var bundledClientID: String? { StatusSync.infoValue("FGSlackClientID") }

    // MARK: - Connecting

    /// Opens Slack's consent page in the browser, where the user picks the
    /// workspace; Slack comes back through `finishConnect`.
    func connect() {
        guard let clientID, !UITestMode.isOn else { return }
        let next = Pending(verifier: PKCE.verifier(), state: PKCE.verifier(), startedAt: now())
        guard let url = Self.authorizeURL(clientID: clientID, verifier: next.verifier, state: next.state) else { return }
        pending = next
        problem = nil
        openURL(url)
    }

    func cancelConnect() {
        pending = nil
    }

    /// Slack's answer, from `focusguard://slack-auth`. A link without the
    /// state FocusGuard sent, or one that comes too late, is ignored.
    func finishConnect(code: String?, state: String?, error: String?) async {
        guard let clientID, let pending, Self.isExpected(state: state, pending: pending, now: now()) else { return }
        self.pending = nil
        guard let code, !code.isEmpty, error == nil else {
            // Cancelling on Slack's page isn't a problem.
            problem = error == "access_denied" ? nil : .connectFailed
            return
        }
        guard let answer: OAuthAnswer = await fetch(Self.oauthRequest(Self.exchangeForm(clientID: clientID, code: code,
                                                                                         verifier: pending.verifier))),
              answer.ok, let signedIn = Self.parseTokens(from: answer, now: now()) else {
            problem = .connectFailed
            return
        }
        save(signedIn)
        teamName = answer.team?.name
        defaults.set(teamName, forKey: Self.teamKey)
        problem = nil
        isConnected = true
    }

    /// Forgets the sign-in, and asks Slack to drop the token.
    func disconnect() async {
        let tokens = readTokens()
        forget()
        problem = nil
        pending = nil
        if let tokens {
            _ = try? await send(Self.formRequest("auth.revoke", [:], token: tokens.access))
        }
    }

    /// At launch: a refresh token getting old is renewed, so the sign-in
    /// doesn't lapse in a quiet month.
    func keepAlive() async {
        guard clientID != nil, let tokens = readTokens(), Self.needsRefresh(tokens, now: now()) else { return }
        _ = await refresh(tokens)
    }

    nonisolated static func isExpected(state: String?, pending: Pending, now: Date) -> Bool {
        state == pending.state && now.timeIntervalSince(pending.startedAt) < pendingLimit
    }

    // MARK: - Status and notifications

    /// The status, which Slack clears by itself at `expires`.
    func setStatus(_ text: String, emoji: String, expires: Date) async -> Bool {
        await call { Self.profileRequest(text: text, emoji: emoji, expires: expires, token: $0) }
    }

    func clearStatus() async -> Bool {
        await call { Self.profileRequest(text: "", emoji: "", expires: nil, token: $0) }
    }

    /// Do Not Disturb for `minutes` from now; a new snooze replaces the last.
    func snooze(minutes: Int) async -> Bool {
        await call { Self.formRequest("dnd.setSnooze", ["num_minutes": String(minutes)], token: $0) }
    }

    func endSnooze() async -> Bool {
        await call { Self.formRequest("dnd.endSnooze", [:], token: $0) }
    }

    /// One Web API call with a fresh token. If Slack says the token ran
    /// out anyway, it's refreshed and the call tried once more.
    private func call(_ request: (String) -> URLRequest?) async -> Bool {
        guard var tokens = await validTokens() else { return false }
        for attempt in 0..<2 {
            guard let built = request(tokens.access), let answer: APIAnswer = await fetch(built) else { return false }
            if answer.ok { return true }
            guard attempt == 0, Self.authErrors.contains(answer.error ?? ""),
                  let fresh = await refresh(tokens) else { return false }
            tokens = fresh
        }
        return false
    }

    // MARK: - Tokens

    /// The stored tokens, refreshed first when the access token is about to
    /// run out or the refresh token is getting old.
    private func validTokens() async -> Tokens? {
        guard clientID != nil, let tokens = readTokens() else { return nil }
        guard Self.needsRefresh(tokens, now: now()) else { return tokens }
        if let fresh = await refresh(tokens) { return fresh }
        // Offline: the old token still does until it runs out.
        guard isConnected, (tokens.expiresAt ?? .distantFuture) > now() else { return nil }
        return tokens
    }

    nonisolated static func needsRefresh(_ tokens: Tokens, now: Date) -> Bool {
        guard tokens.refresh != nil else { return false }
        if let expiresAt = tokens.expiresAt, expiresAt.timeIntervalSince(now) < refreshLead { return true }
        return now.timeIntervalSince(tokens.refreshedAt) >= refreshTokenAge
    }

    /// New tokens for old. Slack turning the refresh token down ends the
    /// sign-in; no answer at all leaves it for next time.
    private func refresh(_ tokens: Tokens) async -> Tokens? {
        guard let clientID, let refreshToken = tokens.refresh,
              let answer: OAuthAnswer = await fetch(Self.oauthRequest(Self.refreshForm(clientID: clientID,
                                                                                       refreshToken: refreshToken)))
        else { return nil }
        guard answer.ok, let fresh = Self.parseTokens(from: answer, now: now()) else {
            if Self.signedOutErrors.contains(answer.error ?? "") {
                forget()
                problem = .signedOut
            }
            return nil
        }
        save(fresh)
        return fresh
    }

    private func readTokens() -> Tokens? {
        keychain.read().flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
    }

    private func save(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        keychain.write(String(decoding: data, as: UTF8.self))
    }

    private func forget() {
        keychain.delete()
        isConnected = false
        teamName = nil
        defaults.removeObject(forKey: Self.teamKey)
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async -> T? {
        guard let (data, _) = try? await send(request) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The user's tokens from an answer. The first exchange has them under
    /// `authed_user`; a refresh has them at the top, as a "user" token.
    nonisolated static func parseTokens(from answer: OAuthAnswer, now: Date) -> Tokens? {
        let user = answer.authed_user
        let fromUser = user?.access_token != nil
        let access = fromUser ? user?.access_token : (answer.token_type == "bot" ? nil : answer.access_token)
        guard let access, !access.isEmpty else { return nil }
        let refreshToken = fromUser ? user?.refresh_token : answer.refresh_token
        let lifetime = (fromUser ? user?.expires_in : answer.expires_in) ?? defaultLifetime
        return Tokens(access: access, refresh: refreshToken,
                      expiresAt: refreshToken == nil ? nil : now.addingTimeInterval(TimeInterval(lifetime)),
                      refreshedAt: now)
    }

    // MARK: - Requests

    nonisolated static func authorizeURL(clientID: String, verifier: String, state: String) -> URL? {
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")
        components?.percentEncodedQuery = PKCE.formEncoded([
            "client_id": clientID,
            "user_scope": scopes,
            "redirect_uri": redirectURI,
            "state": state,
            "code_challenge": PKCE.challenge(for: verifier),
            "code_challenge_method": "S256",
        ])
        return components?.url
    }

    /// The code for tokens: no secret, the verifier instead.
    nonisolated static func exchangeForm(clientID: String, code: String, verifier: String) -> [String: String] {
        ["client_id": clientID, "code": code, "code_verifier": verifier, "redirect_uri": redirectURI]
    }

    nonisolated static func refreshForm(clientID: String, refreshToken: String) -> [String: String] {
        ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]
    }

    nonisolated static func oauthRequest(_ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: api("oauth.v2.access"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(PKCE.formEncoded(form).utf8)
        return request
    }

    /// `users.profile.set` as JSON. Empty text and emoji clear the status.
    nonisolated static func profileRequest(text: String, emoji: String, expires: Date?, token: String) -> URLRequest? {
        let profile: [String: Any] = [
            "status_text": text,
            "status_emoji": emoji,
            "status_expiration": expires.map { Int($0.timeIntervalSince1970) } ?? 0,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: ["profile": profile], options: [.sortedKeys])
        else { return nil }
        var request = URLRequest(url: api("users.profile.set"))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    nonisolated static func formRequest(_ method: String, _ form: [String: String], token: String) -> URLRequest {
        var request = URLRequest(url: api(method))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(PKCE.formEncoded(form).utf8)
        return request
    }

    private nonisolated static func api(_ method: String) -> URL {
        // Slack's host and a method name: always a URL.
        URL(string: "https://slack.com/api/\(method)")!
    }

    // MARK: - Answers

    /// Every Web API answer: `ok`, and `error` when it isn't.
    struct APIAnswer: Decodable {
        let ok: Bool
        let error: String?
    }

    /// `oauth.v2.access`, for a sign-in or a refresh.
    struct OAuthAnswer: Decodable {
        struct User: Decodable {
            let id: String?
            let access_token: String?
            let refresh_token: String?
            let expires_in: Int?
        }

        struct Team: Decodable {
            let id: String?
            let name: String?
        }

        let ok: Bool
        let error: String?
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let token_type: String?
        let authed_user: User?
        let team: Team?
    }
}
