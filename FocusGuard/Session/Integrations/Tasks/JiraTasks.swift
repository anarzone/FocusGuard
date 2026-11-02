import Foundation

/// A Jira Cloud site's address. The email and token only ever go over https
/// to a host ending in `.atlassian.net`: this is the one way to an address.
enum JiraSite {
    /// "acme", "acme.atlassian.net" or a pasted page's URL as
    /// "https://acme.atlassian.net"; nil for anything else.
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let written: String
        if text.contains("://") {
            written = text
        } else {
            written = text.contains(".") || text.contains("/") ? "https://\(text)" : "https://\(text).atlassian.net"
        }
        guard let components = URLComponents(string: written), components.scheme == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host, isJiraHost(host) else { return nil }
        return URL(string: "https://\(host)")
    }

    /// For following a redirect: the same rule as the address itself.
    @Sendable static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.port == nil && url.user == nil && url.host.map(isJiraHost) == true
    }

    private static func isJiraHost(_ host: String) -> Bool {
        let label = "[a-z0-9]([a-z0-9-]*[a-z0-9])?"
        return host.range(of: "^\(label)(\\.\(label))*\\.atlassian\\.net$", options: .regularExpression) != nil
    }
}

/// Jira Cloud issues assigned to the user that aren't in a done-category
/// status, through its REST API with Basic auth: the site and email are kept
/// in the defaults, the API token in the Keychain. Done moves the issue
/// through a transition to a done-category status; Undo moves it back to the
/// status it was in. Workflows vary: with no transition that fits, the issue
/// stays as it is.
///
/// Only an unscoped API token works here: a scoped one has to go through
/// api.atlassian.com, and credentials stay on the site's own host.
final class JiraTasks: ConnectedTaskStore {
    /// Jira's own status categories, by their key.
    static let doneCategory = "done"
    static let startedCategory = "indeterminate"
    /// `statusCategory` takes this name whatever language the site is in.
    static let jql = "assignee = currentUser() AND statusCategory != Done ORDER BY duedate ASC, created ASC"
    static let fields = ["summary", "status", "duedate", "created", "project"]
    /// Search comes this many to a page; this many pages at most.
    static let pageSize = 100
    static let maxPages = 3
    /// Failed logins can trip Atlassian's CAPTCHA, which locks out the REST
    /// API too. A token turned down isn't tried again for this long.
    static let rejectedPause: TimeInterval = 3600
    /// Search takes this many issue ids to read fresh.
    static let reconciledKept = 50
    /// A done-category status with one of these in its name isn't finished.
    static let notFinished = ["cancel", "won't", "won’t", "wont", "reject", "declin", "duplicate", "invalid", "abandon", "obsolete"]

    private enum Key {
        static let site = "integrations.jira.site"
        static let email = "integrations.jira.email"
    }

    /// Where the requests go and who they're from.
    struct Credentials: Equatable {
        let site: URL
        let email: String
        let token: String

        /// "email:token" in Base64.
        var authorization: String { "Basic \(Data("\(email):\(token)".utf8).base64EncodedString())" }
    }

    let source = TaskSource.jira
    private let tokens: TokenStore
    private let defaults: UserDefaults
    private let session: URLSession
    private let lock = NSLock()
    /// When the token was last turned down.
    private var rejectedAt: Date?
    /// Issues just moved. Search can lag behind a change, so it's told to
    /// read these fresh.
    private var moved: [Int] = []

    init(tokens: TokenStore = TaskTokens.keychain(for: .jira), defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.tokens = tokens
        self.defaults = defaults
        self.session = session
    }

    /// The address is checked again here, not just when it's typed.
    private var credentials: Credentials? {
        guard let site = defaults.string(forKey: Key.site).flatMap(JiraSite.url(from:)),
              let email = defaults.string(forKey: Key.email), !email.isEmpty,
              let token = tokens.read(), !token.isEmpty else { return nil }
        return Credentials(site: site, email: email, token: token)
    }

    var hasToken: Bool { credentials != nil }

    /// The saved site's host and email.
    var account: (site: String, email: String)? {
        credentials.map { ($0.site.host ?? "", $0.email) }
    }

    func openTasks() async throws -> [TaskItem] {
        guard let credentials else { return [] }
        if isPaused { throw TaskSourceProblem.rejected }
        do {
            let issues = try await search(credentials)
            // Jira can answer a bad token as if nobody were signed in, with
            // no issues, so nothing found is worth a check.
            if issues.isEmpty { try await confirmSignedIn(credentials) }
            return issues.compactMap(\.item)
        } catch TaskSourceProblem.rejected {
            lock.withLock { rejectedAt = .now }
            throw TaskSourceProblem.rejected
        }
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        await change(task, completed: completed) == .saved
    }

    func change(_ task: TaskItem, completed: Bool) async -> TaskChange {
        guard let credentials, !isPaused else { return .failed }
        let refused = TaskChange.refused(completed
            ? String(localized: "Jira has no transition to done that FocusGuard can use. The issue is unchanged.")
            : String(localized: "Jira has no transition back that FocusGuard can use. The issue stays done."))
        do {
            let available = try await transitions(of: task.id, credentials)
            let fitting = completed ? Self.doneTransition(in: available) : task.state.flatMap { Self.transition(to: $0, in: available) }
            guard let fitting else {
                // It may have got there in Jira itself during the session.
                guard try await isThere(task, completed: completed, credentials) else { return refused }
                remember(task)
                return .saved
            }
            let (_, response) = try await send(Self.moveRequest(credentials, id: task.id, transition: fitting.id))
            switch response.statusCode {
            case 200..<300:
                remember(task)
                return .saved
            // A required field it didn't ask for, a conflict, no permission.
            case 400, 403, 404, 409, 422:
                return refused
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Checks the three with Jira and keeps them if they're taken.
    func connect(site: String, email: String, token: String) async -> TokenCheck {
        guard let url = JiraSite.url(from: site) else { return .badSite }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !token.isEmpty else { return .rejected }
        let credentials = Credentials(site: url, email: email, token: token)
        do {
            try await confirmSignedIn(credentials)
            defaults.set(url.host, forKey: Key.site)
            defaults.set(email, forKey: Key.email)
            tokens.write(token)
            lock.withLock { rejectedAt = nil }
            return .accepted
        } catch TaskSourceProblem.rejected {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    func disconnect() {
        tokens.delete()
        defaults.removeObject(forKey: Key.site)
        defaults.removeObject(forKey: Key.email)
        lock.withLock {
            rejectedAt = nil
            moved = []
        }
    }

    private var isPaused: Bool {
        lock.withLock { rejectedAt.map { Date.now.timeIntervalSince($0) < Self.rejectedPause } ?? false }
    }

    private func remember(_ task: TaskItem) {
        guard let id = Int(task.id) else { return }
        lock.withLock { moved = (moved.filter { $0 != id } + [id]).suffix(Self.reconciledKept) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await TaskWeb.exchange(request, session: session, staysOn: JiraSite.isAllowed)
    }

    /// Every page, following `nextPageToken`.
    private func search(_ credentials: Credentials) async throws -> [RawIssue] {
        let reconciled = lock.withLock { moved }
        var issues: [RawIssue] = []
        var token: String?
        for _ in 0..<Self.maxPages {
            let (data, response) = try await send(Self.searchRequest(credentials, nextPageToken: token, reconcile: reconciled))
            // Nobody signed in has no current user, which can read as a bad query.
            if response.statusCode == 400 { try await confirmSignedIn(credentials) }
            try Self.check(response.statusCode)
            let page = try Self.decode(SearchPage.self, from: data)
            issues += page.issues
            guard page.isLast != true, let next = page.nextPageToken, !next.isEmpty else { break }
            token = next
        }
        return issues
    }

    /// `/myself` is a 401 for anyone Jira doesn't know.
    private func confirmSignedIn(_ credentials: Credentials) async throws {
        let (data, response) = try await send(Self.myselfRequest(credentials))
        try Self.check(response.statusCode)
        _ = try Self.decode(Myself.self, from: data)
    }

    private func transitions(of id: String, _ credentials: Credentials) async throws -> [RawTransition] {
        let (data, response) = try await send(Self.transitionsRequest(credentials, id: id))
        if response.statusCode == 404 { return [] }
        try Self.check(response.statusCode)
        return try Self.decode(Transitions.self, from: data).transitions
    }

    private func isThere(_ task: TaskItem, completed: Bool, _ credentials: Credentials) async throws -> Bool {
        let (data, response) = try await send(Self.statusRequest(credentials, id: task.id))
        if response.statusCode == 404 { return false }
        try Self.check(response.statusCode)
        let status = try Self.decode(RawIssue.self, from: data).fields.status
        return completed ? status?.statusCategory?.key == Self.doneCategory : status?.id == task.state
    }

    // MARK: - Requests

    /// The current search (the old `/rest/api/3/search` is being removed).
    /// `POST` is the form that takes `reconcileIssues` as documented.
    static func searchRequest(_ credentials: Credentials, nextPageToken: String?, reconcile: [Int] = []) -> URLRequest {
        var post = authorized(credentials, path: "rest/api/3/search/jql")
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try? JSONEncoder().encode(SearchBody(jql: jql, fields: fields, maxResults: pageSize, nextPageToken: nextPageToken,
                                                             reconcileIssues: reconcile.isEmpty ? nil : reconcile))
        return post
    }

    static func myselfRequest(_ credentials: Credentials) -> URLRequest {
        authorized(credentials, path: "rest/api/3/myself")
    }

    /// What's available from the issue's status now, with what each asks for.
    static func transitionsRequest(_ credentials: Credentials, id: String) -> URLRequest {
        authorized(credentials, path: "rest/api/3/issue/\(id)/transitions", query: [URLQueryItem(name: "expand", value: "transitions.fields")])
    }

    static func moveRequest(_ credentials: Credentials, id: String, transition: String) -> URLRequest {
        var post = authorized(credentials, path: "rest/api/3/issue/\(id)/transitions")
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try? JSONEncoder().encode(MoveBody(transition: .init(id: transition)))
        return post
    }

    static func statusRequest(_ credentials: Credentials, id: String) -> URLRequest {
        authorized(credentials, path: "rest/api/3/issue/\(id)", query: [URLQueryItem(name: "fields", value: "status")])
    }

    private static func authorized(_ credentials: Credentials, path: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: TaskWeb.url(credentials.site, path: path, query: query), timeoutInterval: 15)
        request.setValue(credentials.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Each request says who it's from: no session left over from another account.
        request.httpShouldHandleCookies = false
        return request
    }

    struct SearchBody: Codable, Equatable {
        let jql: String
        let fields: [String]
        let maxResults: Int
        let nextPageToken: String?
        let reconcileIssues: [Int]?
    }

    struct MoveBody: Codable, Equatable {
        struct Transition: Codable, Equatable {
            let id: String
        }

        let transition: Transition
    }

    // MARK: - Transitions

    /// The transition to a done-category status: one to a status called
    /// Done if there is one, else the first in Jira's order. Not to a status
    /// that sounds like the work was dropped, like Cancelled.
    static func doneTransition(in transitions: [RawTransition]) -> RawTransition? {
        let done = transitions.filter { $0.isUsable && $0.to?.statusCategory?.key == doneCategory }.filter { transition in
            let name = (transition.to?.name ?? transition.name ?? "").lowercased()
            return !notFinished.contains { name.contains($0) }
        }
        return done.first { $0.to?.name?.caseInsensitiveCompare("Done") == .orderedSame } ?? done.first
    }

    static func transition(to status: String, in transitions: [RawTransition]) -> RawTransition? {
        transitions.first { $0.isUsable && $0.to?.id == status }
    }

    // MARK: - Responses

    /// 401 and 403: the email or token was turned down.
    static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403:  throw TaskSourceProblem.rejected
        default:        throw TaskSourceProblem.unreachable
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw TaskSourceProblem.unreachable
        }
    }

    struct SearchPage: Decodable {
        let issues: [RawIssue]
        let nextPageToken: String?
        let isLast: Bool?
    }

    struct Myself: Decodable {
        let accountId: String
    }

    struct Transitions: Decodable {
        let transitions: [RawTransition]
    }

    struct RawStatus: Decodable {
        struct Category: Decodable {
            let key: String?
        }

        let id: String?
        let name: String?
        let statusCategory: Category?
    }

    struct RawTransition: Decodable {
        /// A field on the transition's screen.
        struct Field: Decodable {
            let required: Bool?
            let hasDefaultValue: Bool?
        }

        let id: String
        let name: String?
        let to: RawStatus?
        let isAvailable: Bool?
        let fields: [String: Field]?

        /// FocusGuard can't fill in a screen, so nothing may be left for it
        /// to fill in.
        var isUsable: Bool {
            isAvailable != false && !(fields ?? [:]).values.contains { $0.required == true && $0.hasDefaultValue != true }
        }
    }

    struct RawIssue: Decodable {
        struct Fields: Decodable {
            struct Project: Decodable {
                let name: String?
            }

            let summary: String?
            let status: RawStatus?
            let duedate: String?
            let created: String?
            let project: Project?
        }

        let id: String
        let key: String?
        let fields: Fields

        /// "ENG-142 Fix login"; one in progress counts as started, like Linear's.
        var item: TaskItem? {
            let name = (fields.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let category = fields.status?.statusCategory?.key
            guard !name.isEmpty, category != JiraTasks.doneCategory else { return nil }
            return TaskItem(source: .jira, id: id, title: key.map { "\($0) \(name)" } ?? name, list: fields.project?.name ?? "",
                            due: TaskDates.parse(fields.duedate), created: TaskDates.parse(fields.created),
                            started: category == JiraTasks.startedCategory, state: fields.status?.id)
        }
    }
}
