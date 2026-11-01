import Foundation

/// Todoist tasks due today or overdue, through its API v1 with the user's
/// personal token (Todoist › Settings › Integrations › Developer), kept in
/// the Keychain. Done closes the task; Undo reopens it.
final class TodoistTasks: TokenTaskStore {
    static let base = URL(string: "https://api.todoist.com/api/v1")!
    /// Todoist's own filter syntax.
    static let filter = "today | overdue"
    /// Tasks and projects come 200 to a page; this many pages at most.
    static let pageSize = 200
    static let maxPages = 3

    let source = TaskSource.todoist
    private let tokens: TokenStore
    private let session: URLSession

    init(tokens: TokenStore = TaskTokens.keychain(for: .todoist), session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    var hasToken: Bool { tokens.read()?.isEmpty == false }

    func openTasks() async throws -> [TaskItem] {
        guard let token = tokens.read(), !token.isEmpty else { return [] }
        // Project names only label the tasks: without them, tasks still come.
        async let names = try? pages(of: RawProject.self, token: token) { Self.projectsRequest(token: token, cursor: $0) }
        let tasks = try await pages(of: RawTask.self, token: token) { Self.tasksRequest(token: token, cursor: $0) }
        let projects = Dictionary((await names ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return tasks.compactMap { $0.item(projects: projects) }
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        guard let token = tokens.read(), !token.isEmpty,
              let sent = try? await TaskWeb.send(Self.closeRequest(token: token, id: task.id, reopen: !completed), session: session)
        else { return false }
        return (200..<300).contains(sent.1)
    }

    func connect(token: String) async -> TokenCheck {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .rejected }
        do {
            let (_, status) = try await TaskWeb.send(Self.projectsRequest(token: token, cursor: nil, limit: 1), session: session)
            try Self.check(status)
            tokens.write(token)
            return .accepted
        } catch TaskSourceProblem.rejected {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    func disconnect() { tokens.delete() }

    /// Every page, following `next_cursor`.
    private func pages<Item: Decodable>(of _: Item.Type, token: String,
                                        request: (String?) -> URLRequest) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            let (data, status) = try await TaskWeb.send(request(cursor), session: session)
            try Self.check(status)
            let page = try Self.decodePage(Item.self, from: data)
            items += page.results
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return items
    }

    // MARK: - Requests

    static func tasksRequest(token: String, cursor: String?) -> URLRequest {
        var query = [URLQueryItem(name: "query", value: filter), URLQueryItem(name: "limit", value: "\(pageSize)")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return authorized(TaskWeb.url(base, path: "tasks/filter", query: query), token: token)
    }

    static func projectsRequest(token: String, cursor: String?, limit: Int = pageSize) -> URLRequest {
        var query = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return authorized(TaskWeb.url(base, path: "projects", query: query), token: token)
    }

    /// Closes the task, or reopens it.
    static func closeRequest(token: String, id: String, reopen: Bool) -> URLRequest {
        var post = authorized(TaskWeb.url(base, path: "tasks/\(id)/\(reopen ? "reopen" : "close")"), token: token)
        post.httpMethod = "POST"
        return post
    }

    private static func authorized(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// 401 and 403: the token was turned down.
    static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403:  throw TaskSourceProblem.rejected
        default:        throw TaskSourceProblem.unreachable
        }
    }

    // MARK: - Responses

    struct Page<Item: Decodable>: Decodable {
        let results: [Item]
        let nextCursor: String?
    }

    struct RawProject: Decodable {
        let id: String
        let name: String
    }

    struct RawTask: Decodable {
        struct Due: Decodable {
            let date: String
        }

        let id: String
        let content: String
        let projectId: String?
        let due: Due?
        let addedAt: String?
        let checked: Bool?
        let isDeleted: Bool?

        func item(projects: [String: String]) -> TaskItem? {
            let title = TodoistTasks.plain(content)
            guard checked != true, isDeleted != true, !title.isEmpty else { return nil }
            return TaskItem(source: .todoist, id: id, title: title, list: projectId.flatMap { projects[$0] } ?? "",
                            due: TaskDates.parse(due?.date), created: TaskDates.parse(addedAt))
        }
    }

    static func decodePage<Item: Decodable>(_ type: Item.Type, from data: Data) throws -> Page<Item> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Page<Item>.self, from: data)
        } catch {
            throw TaskSourceProblem.unreachable
        }
    }

    /// The task's text without Markdown links: "[Spec](https://…)" is "Spec".
    static func plain(_ content: String) -> String {
        let unlinked = content.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return unlinked.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
