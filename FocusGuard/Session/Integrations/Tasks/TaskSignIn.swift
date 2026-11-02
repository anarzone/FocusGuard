import Foundation

// What GitHub's and Linear's sign-ins share (`GitHubSignIn`, `LinearSignIn`):
// tokens that rotate, kept in the Keychain and refreshed before they run out,
// and the one place the stores get a token, whichever way the user connected.

/// What a sign-in leaves in the Keychain.
struct SignInTokens: Codable, Equatable, Sendable {
    var access: String
    /// Nil for a token that doesn't rotate.
    var refresh: String?
    var expiresAt: Date?
}

/// A token endpoint's answer, GitHub's or Linear's.
struct TokenAnswer: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let error: String?
    /// How often to poll from now on (GitHub's `slow_down`).
    let interval: Int?

    static func parse(_ data: Data) -> TokenAnswer? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(TokenAnswer.self, from: data)
    }

    func tokens(now: Date) -> SignInTokens? {
        guard let accessToken, !accessToken.isEmpty else { return nil }
        return SignInTokens(access: accessToken, refresh: refreshToken,
                            expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) })
    }
}

/// How asking for new tokens went.
enum TokenRenewal: Equatable, Sendable {
    case renewed(SignInTokens)
    /// The service won't refresh: revoked, or unused for too long.
    case turnedDown
    /// Offline, or the service is having trouble. The sign-in stays.
    case unreachable

    /// What says the sign-in is over. GitHub answers these with a 200.
    static let turnedDownErrors: Set<String> = [
        "bad_refresh_token", "invalid_grant", "invalid_client", "unauthorized_client",
        "incorrect_client_credentials", "expired_token", "token_expired",
    ]

    init(data: Data, status: Int, now: Date) {
        let answer = TokenAnswer.parse(data)
        if (200..<300).contains(status), let tokens = answer?.tokens(now: now) {
            self = .renewed(tokens)
        } else if status == 401 || Self.turnedDownErrors.contains(answer?.error ?? "") {
            self = .turnedDown
        } else {
            self = .unreachable
        }
    }

    static func fetch(_ request: URLRequest, session: URLSession, staysOn: @escaping @Sendable (URL) -> Bool,
                      now: Date) async -> TokenRenewal {
        guard let (data, response) = try? await TaskWeb.exchange(request, session: session, staysOn: staysOn) else {
            return .unreachable
        }
        return TokenRenewal(data: data, status: response.statusCode, now: now)
    }
}

/// A sign-in's tokens in the Keychain, refreshed a little before they run
/// out. A refresh token only works once, so two reads at the same moment
/// (Settings and the menu, say) wait on one refresh instead of each spending
/// it. Being offline keeps the sign-in; the service turning the refresh token
/// down ends it, and `wasSignedOut` says so until the user connects again.
final class RotatingTokens: @unchecked Sendable {
    /// The access token is refreshed this long before it runs out.
    static let refreshLead: TimeInterval = 5 * 60

    private enum Outcome: Sendable {
        case fresh(SignInTokens)
        case turnedDown, unreachable
        /// Disconnected while the refresh was on its way.
        case forgotten
    }

    private let store: TokenStore
    private let now: @Sendable () -> Date
    private let renew: @Sendable (String) async -> TokenRenewal
    private let lock = NSLock()
    private var renewing: Task<Outcome, Never>?
    /// Goes up with every sign-in and disconnect: a refresh that started
    /// before one of those keeps nothing.
    private var generation = 0
    private var signedOut = false

    init(store: TokenStore, now: @escaping @Sendable () -> Date = { Date() },
         renew: @escaping @Sendable (String) async -> TokenRenewal) {
        self.store = store
        self.now = now
        self.renew = renew
    }

    var isSignedIn: Bool { read() != nil }
    var wasSignedOut: Bool { lock.withLock { signedOut } }

    func read() -> SignInTokens? {
        store.read().flatMap { try? JSONDecoder().decode(SignInTokens.self, from: Data($0.utf8)) }
    }

    /// A finished sign-in.
    func save(_ tokens: SignInTokens) {
        lock.withLock {
            generation += 1
            signedOut = false
            renewing = nil
            write(tokens)
        }
    }

    /// Disconnect: the Keychain is cleared, and no refresh brings it back.
    func forget() {
        lock.withLock {
            generation += 1
            signedOut = false
            renewing = nil
            store.delete()
        }
    }

    static func needsRefresh(_ tokens: SignInTokens, now: Date) -> Bool {
        guard tokens.refresh != nil, let expiresAt = tokens.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < refreshLead
    }

    /// The access token, refreshed first when it's about to run out; nil
    /// when not signed in. Offline, the old one still does until it runs out.
    func token() async throws -> String? {
        guard let tokens = read() else { return nil }
        guard Self.needsRefresh(tokens, now: now()) else { return tokens.access }
        switch await renewal(of: tokens) {
        case .fresh(let fresh): return fresh.access
        case .forgotten:        return nil
        case .turnedDown:       throw TaskSourceProblem.rejected
        case .unreachable:
            guard (tokens.expiresAt ?? .distantFuture) > now() else { throw TaskSourceProblem.unreachable }
            return tokens.access
        }
    }

    /// The service turned `stale` down though it hadn't run out: new tokens,
    /// unless someone else has got them already.
    func renewed(after stale: String) async throws -> String? {
        guard let tokens = read() else { return nil }
        guard tokens.access == stale else { return tokens.access }
        switch await renewal(of: tokens) {
        case .fresh(let fresh): return fresh.access
        case .forgotten:        return nil
        case .turnedDown:       throw TaskSourceProblem.rejected
        case .unreachable:      throw TaskSourceProblem.unreachable
        }
    }

    private func renewal(of tokens: SignInTokens) async -> Outcome {
        let task: Task<Outcome, Never>? = lock.withLock {
            if let renewing { return renewing }
            // Another refresh finished after these were read: its tokens do.
            guard read()?.refresh == tokens.refresh else { return nil }
            let started = generation
            let task = Task { await run(tokens, started: started) }
            renewing = task
            return task
        }
        guard let task else { return read().map(Outcome.fresh) ?? .forgotten }
        return await task.value
    }

    private func run(_ tokens: SignInTokens, started: Int) async -> Outcome {
        let renewal: TokenRenewal
        if let refreshToken = tokens.refresh {
            renewal = await renew(refreshToken)
        } else {
            // Nothing to refresh with: only a new sign-in helps.
            renewal = .turnedDown
        }
        return lock.withLock {
            guard generation == started else { return .forgotten }
            renewing = nil
            switch renewal {
            case .renewed(var fresh):
                fresh.refresh = fresh.refresh ?? tokens.refresh
                write(fresh)
                return .fresh(fresh)
            case .turnedDown:
                store.delete()
                signedOut = true
                return .turnedDown
            case .unreachable:
                return .unreachable
            }
        }
    }

    private func write(_ tokens: SignInTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        store.write(String(decoding: data, as: UTF8.self))
    }
}

/// A token for a request, and how it got here: services can want them sent
/// differently (Linear's personal keys go without "Bearer").
enum TaskCredential: Equatable, Sendable {
    case personal(String)
    case signedIn(String)

    var token: String {
        switch self {
        case .personal(let token), .signedIn(let token): return token
        }
    }
}

/// Where GitHub's and Linear's stores get a token, whichever way the user
/// connected: a sign-in, or a pasted token. Only one is ever kept, since
/// either is only offered while disconnected.
struct TaskCredentials {
    let personal: TokenStore
    /// Nil when the app isn't registered (`FGGitHubClientID` is empty, say).
    let signIn: RotatingTokens?

    var hasToken: Bool { isSignedIn || personal.read()?.isEmpty == false }
    var isSignedIn: Bool { signIn?.isSignedIn == true }
    var wasSignedOut: Bool { signIn?.wasSignedOut == true }

    /// A token good to use now; nil when not connected.
    func current() async throws -> TaskCredential? {
        if let signIn, signIn.isSignedIn {
            return try await signIn.token().map(TaskCredential.signedIn)
        }
        guard let token = personal.read(), !token.isEmpty else { return nil }
        return .personal(token)
    }

    /// Another token for one the service turned down, for one more try. Nil
    /// for a pasted token: there's no other.
    func renewed(after credential: TaskCredential) async throws -> TaskCredential? {
        guard case .signedIn(let stale) = credential, let signIn else { return nil }
        return try await signIn.renewed(after: stale).map(TaskCredential.signedIn)
    }

    func forget() {
        personal.delete()
        signIn?.forget()
    }
}
