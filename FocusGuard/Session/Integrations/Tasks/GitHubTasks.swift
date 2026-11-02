import Foundation

/// Open GitHub issues assigned to the user across repositories, through its
/// REST API with a sign-in (`GitHubSignIn`) or a personal access token, kept
/// in the Keychain. github.com only. Done closes the issue as completed; Undo
/// reopens it.
///
/// `GET /issues` and `GET /user` work with classic and fine-grained tokens,
/// and with a GitHub App's user token. A fine-grained token only sees one
/// owner's repositories, and closing an issue needs its "Issues" write
/// permission; a classic token needs `repo`. A user token only reaches what
/// the user and the app both can, so nothing until the app is installed.
final class GitHubTasks: SignInTaskStore {
    static let base = URL(string: "https://api.github.com")!
    static let apiVersion = "2022-11-28"
    /// Issues come 100 to a page, oldest first; this many pages at most.
    static let pageSize = 100
    static let maxPages = 3
    /// Installations looked through for a repository, at most.
    static let maxInstallations = 5

    let source = TaskSource.github
    private let credentials: TaskCredentials
    private let session: URLSession

    init(tokens: TokenStore = TaskTokens.keychain(for: .github), signIn: RotatingTokens? = nil, session: URLSession = .shared) {
        self.credentials = TaskCredentials(personal: tokens, signIn: signIn)
        self.session = session
    }

    var hasToken: Bool { credentials.hasToken }
    var isSignedIn: Bool { credentials.isSignedIn }
    var wasSignedOut: Bool { credentials.wasSignedOut }

    func openTasks() async throws -> [TaskItem] {
        var items: [TaskItem] = []
        var build: (String) -> URLRequest? = { Self.issuesRequest(token: $0) }
        for _ in 0..<Self.maxPages {
            guard let (data, response) = try await send(build) else { break }
            try Self.check(response, data)
            items += try Self.decode([RawIssue].self, from: data).compactMap(\.item)
            guard let next = Self.nextPage(response.value(forHTTPHeaderField: "Link")) else { break }
            build = { Self.authorized(next, token: $0) }
        }
        return items
    }

    /// One request with a token good to use now. A sign-in's token turned down
    /// with a 401 is refreshed and the request tried once more. Nil when not
    /// connected.
    private func send(_ build: (String) -> URLRequest?) async throws -> (Data, HTTPURLResponse)? {
        guard let credential = try await credentials.current(), let request = build(credential.token) else { return nil }
        let answer = try await TaskWeb.exchange(request, session: session, staysOn: Self.isGitHub)
        guard answer.1.statusCode == 401, let fresh = try await credentials.renewed(after: credential),
              let again = build(fresh.token) else { return answer }
        return try await TaskWeb.exchange(again, session: session, staysOn: Self.isGitHub)
    }

    /// Whether a sign-in reaches any repository at all, for the line in
    /// Settings that says to install the app. A pasted token isn't asked about.
    func repositoryAccess() async -> RepositoryAccess {
        guard isSignedIn,
              let (data, response) = try? await send({ Self.installationsRequest(token: $0) }),
              (200..<300).contains(response.statusCode),
              let list = try? Self.decode(RawInstallations.self, from: data) else { return .unknown }
        var failed = false
        for installation in list.installations.filter({ $0.suspendedAt == nil }).prefix(Self.maxInstallations) {
            guard let (data, response) = try? await send({ Self.repositoriesRequest(token: $0, installation: installation.id) }),
                  (200..<300).contains(response.statusCode),
                  let repositories = try? Self.decode(RawRepositories.self, from: data) else {
                failed = true
                continue
            }
            if repositories.totalCount > 0 { return .reachable }
        }
        return failed ? .unknown : .noRepositories
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        await change(task, completed: completed) == .saved
    }

    func change(_ task: TaskItem, completed: Bool) async -> TaskChange {
        guard let (data, response) = try? await send({ Self.stateRequest(token: $0, id: task.id, open: !completed) })
        else { return .failed }
        switch response.statusCode {
        case 200..<300:
            // A redirect can turn the change into a plain read: only the
            // state that came back says it's saved.
            let saved = try? Self.decode(RawIssue.self, from: data)
            return saved?.state == (completed ? "closed" : "open") ? .saved : .failed
        case 403 where !Self.isRateLimited(response, data), 404, 410, 422:
            return .refused(isSignedIn
                ? String(localized: "GitHub refused the change. You or FocusGuard's GitHub app may not have write access to this repository's issues.")
                : String(localized: "GitHub refused the change. The token needs write access to this repository's issues."))
        default:
            return .failed
        }
    }

    func connect(token: String) async -> TokenCheck {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .rejected }
        do {
            let (data, response) = try await TaskWeb.exchange(Self.userRequest(token: token), session: session, staysOn: Self.isGitHub)
            try Self.check(response, data)
            credentials.personal.write(token)
            return .accepted
        } catch TaskSourceProblem.rejected {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    /// Clears the Keychain. A sign-in stays on GitHub's side, which only
    /// revokes with the app's secret (`GitHubDeviceFlow`).
    func disconnect() { credentials.forget() }

    // MARK: - Requests

    static func issuesRequest(token: String) -> URLRequest {
        let query = [URLQueryItem(name: "filter", value: "assigned"), URLQueryItem(name: "state", value: "open"),
                     URLQueryItem(name: "sort", value: "created"), URLQueryItem(name: "direction", value: "asc"),
                     URLQueryItem(name: "per_page", value: "\(pageSize)")]
        return authorized(TaskWeb.url(base, path: "issues", query: query), token: token)
    }

    /// Takes any token, whatever it may do: the check before it's kept.
    static func userRequest(token: String) -> URLRequest {
        authorized(TaskWeb.url(base, path: "user"), token: token)
    }

    static func installationsRequest(token: String) -> URLRequest {
        authorized(TaskWeb.url(base, path: "user/installations", query: [URLQueryItem(name: "per_page", value: "100")]), token: token)
    }

    /// One repository is enough: the answer has the total.
    static func repositoriesRequest(token: String, installation: Int) -> URLRequest {
        authorized(TaskWeb.url(base, path: "user/installations/\(installation)/repositories",
                               query: [URLQueryItem(name: "per_page", value: "1")]), token: token)
    }

    /// Closes the issue as completed, or reopens it; nil for an id that
    /// isn't "owner/repo#142".
    static func stateRequest(token: String, id: String, open: Bool) -> URLRequest? {
        guard let path = issuePath(id) else { return nil }
        var patch = authorized(TaskWeb.url(base, path: path), token: token)
        patch.httpMethod = "PATCH"
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        patch.httpBody = try? JSONEncoder().encode(open ? ["state": "open", "state_reason": "reopened"]
                                                        : ["state": "closed", "state_reason": "completed"])
        return patch
    }

    private static func authorized(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FocusGuard", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// "owner/repo#142" as "repos/owner/repo/issues/142".
    static func issuePath(_ id: String) -> String? {
        let halves = id.split(separator: "#", omittingEmptySubsequences: false)
        let names = halves.first?.split(separator: "/", omittingEmptySubsequences: false) ?? []
        guard halves.count == 2, Int(halves[1]) != nil, names.count == 2,
              names.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil && $0 != "." && $0 != ".." })
        else { return nil }
        return "repos/\(names[0])/\(names[1])/issues/\(halves[1])"
    }

    /// The token only ever goes to GitHub's API, over https.
    @Sendable static func isGitHub(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == base.host && url.port == nil
    }

    /// The `rel="next"` address in a Link header, when it's GitHub's own.
    static func nextPage(_ link: String?) -> URL? {
        for part in (link ?? "").split(separator: ",") where part.contains(#"rel="next""#) {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close,
                  let url = URL(string: String(part[part.index(after: open)..<close])), isGitHub(url) else { return nil }
            return url
        }
        return nil
    }

    // MARK: - Responses

    /// 401, or a 403 that isn't a rate limit: the token was turned down.
    static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300:                                return
        case 401:                                      throw TaskSourceProblem.rejected
        case 403 where !isRateLimited(response, data): throw TaskSourceProblem.rejected
        default:                                       throw TaskSourceProblem.unreachable
        }
    }

    /// GitHub limits with a 403 or 429, marked by these headers or its message.
    static func isRateLimited(_ response: HTTPURLResponse, _ data: Data) -> Bool {
        response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            || response.value(forHTTPHeaderField: "retry-after") != nil
            || String(decoding: data, as: UTF8.self).lowercased().contains("rate limit")
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw TaskSourceProblem.unreachable
        }
    }

    /// `GET /user/installations`.
    struct RawInstallations: Decodable {
        struct Installation: Decodable {
            let id: Int
            let suspendedAt: String?
        }

        let installations: [Installation]
    }

    /// `GET /user/installations/{id}/repositories`.
    struct RawRepositories: Decodable {
        let totalCount: Int
    }

    struct RawIssue: Decodable {
        struct Repository: Decodable {
            let name: String
            let fullName: String
            let archived: Bool?
        }

        /// Only there on a pull request; what's in it doesn't matter.
        struct PullRequest: Decodable {}

        let number: Int
        let title: String?
        let state: String?
        let createdAt: String?
        let repositoryUrl: String?
        let repository: Repository?
        let pullRequest: PullRequest?

        /// "repo#142 Fix login", or nothing for a pull request or an issue
        /// in an archived repository, which can't be closed.
        var item: TaskItem? {
            let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard pullRequest == nil, repository?.archived != true, !name.isEmpty,
                  let fullName = repository?.fullName ?? repositoryUrl.flatMap(Self.fullName(from:)) else { return nil }
            let repo = repository?.name ?? fullName.split(separator: "/").last.map(String.init) ?? fullName
            return TaskItem(source: .github, id: "\(fullName)#\(number)", title: "\(repo)#\(number) \(name)",
                            list: repo, due: nil, created: TaskDates.parse(createdAt))
        }

        /// "https://api.github.com/repos/owner/repo" as "owner/repo".
        private static func fullName(from url: String) -> String? {
            let parts = url.split(separator: "/").suffix(2)
            return parts.count == 2 ? parts.joined(separator: "/") : nil
        }
    }
}

/// Whether a sign-in can reach any of the user's repositories.
enum RepositoryAccess: Equatable, Sendable {
    case reachable
    /// The app isn't installed anywhere the user can see.
    case noRepositories
    /// Couldn't tell, or not signed in.
    case unknown
}
