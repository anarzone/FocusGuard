import SwiftData
import XCTest
@testable import FocusGuard

// Things, Todoist, Linear, GitHub and Jira as session goals (Pro). Nothing
// here talks to Things or the real services: scripts are checked as text,
// requests as built, and answers come from fixtures through a stub URL
// protocol. Tokens are in a fake store, never the Keychain.

// MARK: - Fakes

/// Answers every request from `handler`, and keeps what was asked.
final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    /// Response headers, for paging and rate limits.
    static var headers: ((URLRequest) -> [String: String])?
    /// Todoist asks for tasks and projects at once, so this is locked.
    static var requests: [URLRequest] {
        get { lock.lock(); defer { lock.unlock() }; return seen }
        set { lock.lock(); defer { lock.unlock() }; seen = newValue }
    }
    private static let lock = NSLock()
    private static var seen: [URLRequest] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var asked = request
        if asked.httpBody == nil, let stream = request.httpBodyStream { asked.httpBody = Self.read(stream) }
        Self.lock.lock()
        Self.seen.append(asked)
        Self.lock.unlock()
        let (status, body) = Self.handler?(asked) ?? (500, "")
        let url = request.url ?? URL(fileURLWithPath: "/")
        let headers = Self.headers?(asked)
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            // A redirect goes through the session's delegate, as a real one
            // would; one it turns down is answered with the redirect itself.
            if (300..<400).contains(status), let location = headers?["Location"], let target = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class FakeTokens: TokenStore {
    var token: String?
    init(_ token: String? = nil) { self.token = token }
    func read() -> String? { token }
    func write(_ token: String) { self.token = token }
    func delete() { token = nil }
}

/// A source whose tasks and troubles the test sets.
private final class FakeTaskStore: TaskStore {
    let source: TaskSource
    var items: [TaskItem]
    var problem: TaskSourceProblem?
    var completions: [(String, Bool)] = []
    /// The service won't make the change, and says so.
    var refusal: String?
    private var done: Set<String> = []

    init(_ source: TaskSource, _ items: [TaskItem] = []) {
        self.source = source
        self.items = items
    }

    func openTasks() async throws -> [TaskItem] {
        if let problem { throw problem }
        return items.filter { !done.contains($0.id) }
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        completions.append((task.id, completed))
        if completed { done.insert(task.id) } else { done.remove(task.id) }
        return true
    }

    func change(_ task: TaskItem, completed: Bool) async -> TaskChange {
        if let refusal {
            completions.append((task.id, completed))
            return .refused(refusal)
        }
        return await setCompleted(task, completed) ? .saved : .failed
    }
}

final class NoCalendar: CalendarStore {
    func calendars() async -> [CalendarChoice] { [] }
    func defaultCalendarID() async -> String? { nil }
    func events(from start: Date, to end: Date, calendarIDs: [String], ownIDs: Set<String>) async -> [CalendarEntry]? { [] }
    func create(_ draft: SessionEventDraft, calendarID: String?) async -> String? { nil }
    func update(_ ref: OwnEventRef, to draft: SessionEventDraft) async -> String? { nil }
    func remove(_ ref: OwnEventRef) async -> Bool { true }
}

final class NoReminders: ReminderStore {
    func lists() async -> [CalendarChoice] { [] }
    func incomplete(listIDs: [String]) async -> [TaskItem]? { [] }
    func setCompleted(_ id: String, _ completed: Bool) async -> Bool { false }
    func requestAccess() async -> Bool { false }
}

private let berlin: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
    return calendar
}()

/// 26 Oct 2026 at `hour` in Berlin, a Monday.
private func at(_ hour: Int, day: Int = 26) -> Date {
    berlin.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)) ?? .distantPast
}

// MARK: - Tasks from any source

final class TaskItemTests: XCTestCase {
    func testA0334LinkWithAReminderStillReads() throws {
        let saved = #"{"reminder":{"id":"q4","title":"Write the Q4 report","list":"Work","due":815000000},"linkedAt":815000000,"ticked":true,"undone":false}"#
        let link = try JSONDecoder().decode(TaskLink.self, from: Data(saved.utf8))
        XCTAssertEqual(link.task.source, .reminders)
        XCTAssertEqual(link.task.id, "q4")
        XCTAssertEqual(link.task.list, "Work")
        XCTAssertEqual(link.task.due, Date(timeIntervalSinceReferenceDate: 815_000_000))
        XCTAssertNil(link.task.created)
        XCTAssertTrue(link.ticked)

        let again = try JSONDecoder().decode(TaskLink.self, from: JSONEncoder().encode(link))
        XCTAssertEqual(again, link)
    }

    func testAPickedReminderFrom0334StillReads() throws {
        let saved = #"{"id":"q4","title":"Write the Q4 report","list":"Work"}"#
        let item = try JSONDecoder().decode(TaskItem.self, from: Data(saved.utf8))
        XCTAssertEqual(item, TaskItem(id: "q4", title: "Write the Q4 report", list: "Work", due: nil, created: nil))
    }

    func testALinearIssueKeepsItsSourceAndState() throws {
        let issue = TaskItem(source: .linear, id: "uuid-1", title: "ENG-142 Fix login", list: "Engineering",
                             due: nil, created: nil, started: true, state: "state-started")
        let link = TaskLink(task: issue, linkedAt: at(10))
        let again = try JSONDecoder().decode(TaskLink.self, from: JSONEncoder().encode(link))
        XCTAssertEqual(again.task, issue)
    }

    func testTasksSavedByReleasedBuildsStillRead() throws {
        // Picked tasks and links as 0.3.x builds wrote them, before GitHub and Jira.
        let todoist = #"{"source":"todoist","id":"7Abc","title":"Pay rent","list":"Home","due":815000000,"created":814000000,"started":false}"#
        let picked = try JSONDecoder().decode(TaskItem.self, from: Data(todoist.utf8))
        XCTAssertEqual(picked.source, .todoist)
        XCTAssertEqual(picked.due, Date(timeIntervalSinceReferenceDate: 815_000_000))

        let linear = #"{"task":{"source":"linear","id":"uuid-1","title":"ENG-142 Fix login","list":"Engineering","started":true,"state":"state-started"},"linkedAt":815000000,"ticked":true}"#
        let link = try JSONDecoder().decode(TaskLink.self, from: Data(linear.utf8))
        XCTAssertEqual(link.task.source, .linear)
        XCTAssertEqual(link.task.state, "state-started")
        XCTAssertTrue(link.task.started)
        XCTAssertTrue(link.ticked)

        let things = #"{"source":"things","id":"8xcpS6r4","title":"Walk","list":""}"#
        XCTAssertEqual(try JSONDecoder().decode(TaskItem.self, from: Data(things.utf8)).source, .things)
    }

    func testGitHubAndJiraTasksSurviveSaving() throws {
        let issues = [
            TaskItem(source: .github, id: "acme/app#142", title: "app#142 Fix login", list: "app", due: nil, created: at(9, day: 1)),
            TaskItem(source: .jira, id: "10042", title: "ENG-142 Fix login", list: "Engineering", due: at(0), created: nil, started: true, state: "3"),
        ]
        for issue in issues {
            let link = TaskLink(task: issue, linkedAt: at(10))
            XCTAssertEqual(try JSONDecoder().decode(TaskLink.self, from: JSONEncoder().encode(link)).task, issue)
        }
        XCTAssertEqual(TaskSource.allCases.map(\.rawValue), ["reminders", "things", "todoist", "linear", "github", "jira"])
        XCTAssertEqual(Set(TaskSource.allCases.map(\.settingKey)).count, TaskSource.allCases.count)
    }

    func testUndatedIssuesRankLikeLinears() {
        let items = [
            TaskItem(source: .reminders, id: "someday", title: "Someday", list: "", due: nil, created: at(9, day: 5)),
            TaskItem(source: .github, id: "acme/app#1", title: "app#1 Old", list: "app", due: nil, created: at(9, day: 1)),
            TaskItem(source: .jira, id: "new", title: "ENG-2 To do", list: "ENG", due: nil, created: at(9, day: 3), started: false, state: "1"),
            TaskItem(source: .jira, id: "going", title: "ENG-3 Going", list: "ENG", due: nil, created: at(9, day: 9), started: true, state: "3"),
            TaskItem(source: .jira, id: "dated", title: "ENG-4 Soon", list: "ENG", due: at(0, day: 30), created: nil, state: "1"),
            TaskItem(source: .jira, id: "today", title: "ENG-5 Today", list: "ENG", due: at(0), created: nil, state: "1"),
        ]
        XCTAssertEqual(TaskGoals.ordered(items, now: at(10), calendar: berlin).map(\.id),
                       ["today", "going", "dated", "acme/app#1", "new", "someday"])
        let offered = GoalSuggestion.make(lastGoal: nil, lastVerdict: nil, calendarTitle: nil,
                                          tasks: TaskGoals.ordered(items, now: at(10), calendar: berlin),
                                          now: at(10), calendar: berlin)
        XCTAssertEqual(offered.map(\.text), ["ENG-5 Today", "ENG-3 Going"])
        XCTAssertEqual(GoalSuggestion(text: "app#1 Old", source: .task(.github, id: "acme/app#1", list: "app")).group, "GitHub · app")
    }

    func testStartedIssuesComeAfterWhatsDueButBeforeTheRest() {
        let items = [
            TaskItem(source: .reminders, id: "someday", title: "Someday", list: "", due: nil, created: at(9, day: 1)),
            TaskItem(source: .todoist, id: "later", title: "Next week", list: "Inbox", due: at(9, day: 30), created: nil),
            TaskItem(source: .linear, id: "eng", title: "ENG-142 Fix login", list: "Engineering", due: nil, created: nil, started: true),
            TaskItem(source: .things, id: "late", title: "Late", list: "", due: at(0, day: 20), created: nil),
            TaskItem(source: .todoist, id: "rent", title: "Pay rent", list: "Home", due: at(0), created: nil),
        ]
        XCTAssertEqual(TaskGoals.ordered(items, now: at(10), calendar: berlin).map(\.id),
                       ["rent", "late", "eng", "later", "someday"])
    }

    func testTwoTasksAreOfferedAtMostEachUnderItsSource() {
        let tasks = [
            TaskItem(source: .todoist, id: "rent", title: "Pay rent", list: "Home", due: at(0), created: nil),
            TaskItem(source: .linear, id: "eng", title: "ENG-142 Fix login", list: "Engineering", due: nil, created: nil, started: true),
            TaskItem(source: .things, id: "walk", title: "Walk", list: "", due: nil, created: nil),
        ]
        let suggestions = GoalSuggestion.make(lastGoal: nil, lastVerdict: nil, calendarTitle: nil, tasks: tasks,
                                              now: at(10), calendar: berlin)
        XCTAssertEqual(suggestions.map(\.text), ["Pay rent", "ENG-142 Fix login"])
        XCTAssertEqual(suggestions.map(\.group), ["Todoist · Home", "Linear · Engineering"])
        XCTAssertEqual(suggestions.map(\.detail), ["today", nil])
        XCTAssertEqual(suggestions.first?.source, .task(.todoist, id: "rent", list: "Home"))

        let things = GoalSuggestion.make(lastGoal: nil, lastVerdict: nil, calendarTitle: nil, tasks: [tasks[2]])
        XCTAssertEqual(things.first?.group, "Things")
    }

    func testDatesAsTodoistAndLinearSendThem() {
        XCTAssertEqual(TaskDates.parse("2026-10-26", calendar: berlin), at(0))
        XCTAssertEqual(TaskDates.parse("2026-10-26T15:00:00", calendar: berlin), at(15))
        XCTAssertEqual(TaskDates.parse("2026-10-26T14:00:00Z", calendar: berlin), at(15))
        XCTAssertEqual(TaskDates.parse("2026-10-26T14:00:00.123456Z", calendar: berlin), at(15))
        XCTAssertNil(TaskDates.parse(nil))
        XCTAssertNil(TaskDates.parse("tomorrow"))
        XCTAssertNil(TaskDates.parse("2026-10-26TZ"))
    }

    func testDatesAsJiraSendsThem() {
        XCTAssertEqual(TaskDates.parse("2026-10-26T15:00:00.000+0100", calendar: berlin), at(15))
        XCTAssertEqual(TaskDates.parse("2026-10-26T09:30:00.000-0430", calendar: berlin), at(15))
        XCTAssertEqual(TaskDates.parse("2026-10-26T15:00:00+01:00", calendar: berlin), at(15))
        XCTAssertNil(TaskDates.parse("2026-10-26T15:00:00+1"))
    }
}

// MARK: - Things

final class ThingsTasksTests: XCTestCase {
    func testTheScriptReadsTodayByItsIDSoAnyLanguageWorks() {
        let script = ThingsScripts.today
        XCTAssertTrue(script.contains(#"tell application id "com.culturedcode.ThingsMac""#))
        XCTAssertTrue(script.contains(#"to dos of list id "TMTodayListSource""#))
        XCTAssertTrue(script.contains("completion date of t is missing value"))
        XCTAssertTrue(script.contains("class of t is not project"))
    }

    func testTickingAndUndoSetTheStatus() {
        XCTAssertEqual(ThingsScripts.setStatus(of: "8xcpS6r4", completed: true), """
        tell application id "com.culturedcode.ThingsMac"
            set status of to do id "8xcpS6r4" to completed
        end tell
        return "ok"
        """)
        XCTAssertTrue(ThingsScripts.setStatus(of: "8xcpS6r4", completed: false).contains(#"to do id "8xcpS6r4" to open"#))
        XCTAssertTrue(ThingsScripts.setStatus(of: #"a"b\c"#, completed: true).contains(#"to do id "a\"b\\c" to"#))
    }

    func testReadsTodayAsTasksDueToday() {
        let f = String(ThingsScripts.field)
        let r = String(ThingsScripts.record)
        let output = [
            ["id-1", "Write the Q4 report", "Work", "", "2026-10-1-36000"],
            ["id-2", "Renew passport", "Errands", "2026-10-20-0", ""],
            ["id-3", "Book the venue", "", "2026-11-2-0", ""],
            ["", "No id", "", "", ""],
            ["id-5"],
        ].map { $0.joined(separator: f) }.joined(separator: r) + r
        let items = ThingsScripts.parse(output, now: at(10), calendar: berlin)
        XCTAssertEqual(items.map(\.id), ["id-1", "id-2", "id-3"])
        XCTAssertEqual(items.map(\.source), [.things, .things, .things])
        XCTAssertEqual(items.map(\.list), ["Work", "Errands", ""])
        XCTAssertEqual(items[0].created, at(10, day: 1))
        XCTAssertEqual(items.map { TaskGoals.dueNote($0, now: at(10), calendar: berlin) }, ["today", "overdue", "today"])
        XCTAssertTrue(ThingsScripts.parse("", now: at(10)).isEmpty)
    }
}

// MARK: - Todoist

final class TodoistTasksTests: XCTestCase {
    private static let tasksPage = """
    {"results":[
      {"id":"6XGgmFVcrG5RRjVr","project_id":"inbox","content":"Buy milk","due":{"date":"2026-10-26","is_recurring":false,"lang":"en","string":"today"},
       "added_at":"2026-10-20T10:30:00.123456Z","checked":false,"is_deleted":false,"priority":1,"labels":[]},
      {"id":"7Abc","project_id":"work","content":"Review [the spec](https://example.com/spec)","due":{"date":"2026-10-25T15:00:00Z"},
       "added_at":"2026-10-01T08:00:00Z","checked":false,"is_deleted":false},
      {"id":"8Def","project_id":"gone","content":"  ","due":null,"added_at":null,"checked":false,"is_deleted":false}
    ],"next_cursor":null}
    """
    private static let projectsPage = #"{"results":[{"id":"inbox","name":"Inbox"},{"id":"work","name":"Work"}],"next_cursor":null}"#

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.requests = []
        super.tearDown()
    }

    func testAsksForTodayAndOverdueWithTheToken() {
        let request = TodoistTasks.tasksRequest(token: "tok", cursor: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://api.todoist.com/api/v1/tasks/filter?query=today%20%7C%20overdue&limit=200")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(TodoistTasks.tasksRequest(token: "tok", cursor: "a+b").url?.query,
                       "query=today%20%7C%20overdue&limit=200&cursor=a%2Bb")
    }

    func testClosesAndReopens() {
        let close = TodoistTasks.closeRequest(token: "tok", id: "7Abc", reopen: false)
        XCTAssertEqual(close.url?.absoluteString, "https://api.todoist.com/api/v1/tasks/7Abc/close")
        XCTAssertEqual(close.httpMethod, "POST")
        XCTAssertEqual(close.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(TodoistTasks.closeRequest(token: "tok", id: "7Abc", reopen: true).url?.path, "/api/v1/tasks/7Abc/reopen")
    }

    func testReadsTasksUnderTheirProjects() async throws {
        StubProtocol.handler = { request in
            request.url?.path == "/api/v1/projects" ? (200, Self.projectsPage) : (200, Self.tasksPage)
        }
        let store = TodoistTasks(tokens: FakeTokens("tok"), session: StubProtocol.session())
        let items = try await store.openTasks().sorted { $0.id < $1.id }
        XCTAssertEqual(items.map(\.title), ["Buy milk", "Review the spec"])
        XCTAssertEqual(items.map(\.list), ["Inbox", "Work"])
        XCTAssertEqual(items.map(\.source), [.todoist, .todoist])
        XCTAssertEqual(items[1].due, TaskDates.parse("2026-10-25T15:00:00Z"))
        XCTAssertEqual(items[0].created, TaskDates.parse("2026-10-20T10:30:00Z"))
    }

    func testFollowsTheCursor() async throws {
        StubProtocol.handler = { request in
            if request.url?.path == "/api/v1/projects" { return (200, Self.projectsPage) }
            if request.url?.query?.contains("cursor=next%2B1") == true {
                return (200, #"{"results":[{"id":"2","content":"Second page","project_id":"inbox"}],"next_cursor":null}"#)
            }
            return (200, #"{"results":[{"id":"1","content":"First page","project_id":"inbox"}],"next_cursor":"next+1"}"#)
        }
        let store = TodoistTasks(tokens: FakeTokens("tok"), session: StubProtocol.session())
        let titles = try await store.openTasks().map(\.title)
        XCTAssertEqual(Set(titles), ["First page", "Second page"])
    }

    func testATurnedDownTokenIsRejected() async {
        StubProtocol.handler = { _ in (401, "Unauthorized") }
        let store = TodoistTasks(tokens: FakeTokens("old"), session: StubProtocol.session())
        do {
            _ = try await store.openTasks()
            XCTFail("a 401 should be rejected")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
    }

    func testWithoutATokenNothingIsAsked() async throws {
        let store = TodoistTasks(tokens: FakeTokens(), session: StubProtocol.session())
        let items = try await store.openTasks()
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        XCTAssertFalse(store.hasToken)
    }

    func testConnectKeepsOnlyATokenTodoistTakes() async {
        let tokens = FakeTokens()
        let store = TodoistTasks(tokens: tokens, session: StubProtocol.session())
        StubProtocol.handler = { _ in (401, "") }
        let rejected = await store.connect(token: "wrong")
        XCTAssertEqual(rejected, .rejected)
        XCTAssertNil(tokens.token)

        StubProtocol.handler = { _ in (200, Self.projectsPage) }
        let accepted = await store.connect(token: "  right \n")
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(tokens.token, "right")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer right")

        store.disconnect()
        XCTAssertNil(tokens.token)
    }

    func testDoneClosesTheTask() async {
        StubProtocol.handler = { _ in (200, "null") }
        let store = TodoistTasks(tokens: FakeTokens("tok"), session: StubProtocol.session())
        let task = TaskItem(source: .todoist, id: "7Abc", title: "Review the spec", list: "Work", due: nil, created: nil)
        let closed = await store.setCompleted(task, true)
        let reopened = await store.setCompleted(task, false)
        XCTAssertTrue(closed)
        XCTAssertTrue(reopened)
        XCTAssertEqual(StubProtocol.requests.map { $0.url?.path }, ["/api/v1/tasks/7Abc/close", "/api/v1/tasks/7Abc/reopen"])
    }

    func testMarkdownLinksReadAsText() {
        XCTAssertEqual(TodoistTasks.plain("Read [the spec](https://x.y/z) and [notes](n)"), "Read the spec and notes")
        XCTAssertEqual(TodoistTasks.plain("  Plain  "), "Plain")
    }
}

// MARK: - Linear

final class LinearTasksTests: XCTestCase {
    private static let issues = """
    {"data":{"viewer":{"assignedIssues":{"nodes":[
      {"id":"uuid-1","identifier":"ENG-142","title":"Fix login","dueDate":null,"createdAt":"2026-10-01T09:00:00.000Z",
       "state":{"id":"state-started","type":"started"},"team":{"name":"Engineering"}},
      {"id":"uuid-2","identifier":"ENG-150","title":"Write release notes","dueDate":"2026-10-26","createdAt":"2026-10-02T09:00:00.000Z",
       "state":{"id":"state-todo","type":"unstarted"},"team":{"name":"Engineering"}}
    ]}}}}
    """
    private static let authError = """
    {"errors":[{"message":"Authentication required, not authenticated",
      "extensions":{"type":"authentication error","code":"AUTHENTICATION_ERROR","userError":true}}]}
    """

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.requests = []
        super.tearDown()
    }

    private func body(_ request: URLRequest?) -> LinearTasks.Body? {
        request?.httpBody.flatMap { try? JSONDecoder().decode(LinearTasks.Body.self, from: $0) }
    }

    func testAPersonalKeyGoesInAuthorizationAsItIs() {
        let request = LinearTasks.request(LinearTasks.issuesQuery, key: "lin_api_123")
        XCTAssertEqual(request.url?.absoluteString, "https://api.linear.app/graphql")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "lin_api_123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body(request), LinearTasks.Body(query: LinearTasks.issuesQuery, variables: nil))
        XCTAssertTrue(LinearTasks.issuesQuery.contains(#"assignedIssues(first: 50, filter: { state: { type: { in: ["started", "unstarted"] } } })"#))
    }

    func testReadsIssuesWithTheirIdentifier() async throws {
        StubProtocol.handler = { _ in (200, Self.issues) }
        let store = LinearTasks(tokens: FakeTokens("lin_api_123"), session: StubProtocol.session())
        let items = try await store.openTasks()
        XCTAssertEqual(items.map(\.title), ["ENG-142 Fix login", "ENG-150 Write release notes"])
        XCTAssertEqual(items.map(\.list), ["Engineering", "Engineering"])
        XCTAssertEqual(items.map(\.started), [true, false])
        XCTAssertEqual(items.map(\.state), ["state-started", "state-todo"])
        XCTAssertEqual(items[1].due, TaskDates.parse("2026-10-26"))
    }

    func testAnAuthenticationErrorIsRejected() async {
        StubProtocol.handler = { _ in (400, Self.authError) }
        let store = LinearTasks(tokens: FakeTokens("revoked"), session: StubProtocol.session())
        do {
            _ = try await store.openTasks()
            XCTFail("an authentication error should be rejected")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        let check = await store.connect(token: "revoked")
        XCTAssertEqual(check, .rejected)

        StubProtocol.handler = { _ in (500, "") }
        let down = await store.connect(token: "fine")
        XCTAssertEqual(down, .unreachable)
    }

    func testDoneMovesToTheFirstCompletedStateAndUndoMovesBack() async {
        StubProtocol.handler = { request in
            let query = (request.httpBody.flatMap { try? JSONDecoder().decode(LinearTasks.Body.self, from: $0) })?.query ?? ""
            if query == LinearTasks.doneStatesQuery {
                return (200, #"{"data":{"issue":{"team":{"states":{"nodes":[{"id":"done-b","position":3},{"id":"done-a","position":2}]}}}}}"#)
            }
            return (200, #"{"data":{"issueUpdate":{"success":true}}}"#)
        }
        let store = LinearTasks(tokens: FakeTokens("lin_api_123"), session: StubProtocol.session())
        let issue = TaskItem(source: .linear, id: "uuid-1", title: "ENG-142 Fix login", list: "Engineering",
                             due: nil, created: nil, started: true, state: "state-started")

        let done = await store.setCompleted(issue, true)
        XCTAssertTrue(done)
        XCTAssertEqual(StubProtocol.requests.map { body($0) }, [
            LinearTasks.Body(query: LinearTasks.doneStatesQuery, variables: ["id": "uuid-1"]),
            LinearTasks.Body(query: LinearTasks.moveMutation, variables: ["id": "uuid-1", "stateId": "done-a"]),
        ])

        StubProtocol.requests = []
        let undone = await store.setCompleted(issue, false)
        XCTAssertTrue(undone)
        XCTAssertEqual(StubProtocol.requests.map { body($0) }, [
            LinearTasks.Body(query: LinearTasks.moveMutation, variables: ["id": "uuid-1", "stateId": "state-started"]),
        ])
    }
}

// MARK: - GitHub

final class GitHubTasksTests: XCTestCase {
    private static let page = """
    [
      {"id":1,"number":142,"title":"Fix login","state":"open","created_at":"2026-10-01T09:00:00Z",
       "repository_url":"https://api.github.com/repos/acme/app",
       "repository":{"name":"app","full_name":"acme/app","archived":false}},
      {"id":2,"number":143,"title":"A pull request","state":"open","created_at":"2026-10-02T09:00:00Z",
       "repository_url":"https://api.github.com/repos/acme/app",
       "repository":{"name":"app","full_name":"acme/app"},
       "pull_request":{"url":"https://api.github.com/repos/acme/app/pulls/143","merged_at":null}},
      {"id":3,"number":7,"title":"No repository object","state":"open","created_at":"2026-10-03T09:00:00Z",
       "repository_url":"https://api.github.com/repos/acme/site"},
      {"id":4,"number":8,"title":"In an archived repository","state":"open",
       "repository_url":"https://api.github.com/repos/acme/old",
       "repository":{"name":"old","full_name":"acme/old","archived":true}},
      {"id":5,"number":9,"title":"  ","state":"open","repository_url":"https://api.github.com/repos/acme/app"}
    ]
    """

    private let issue = TaskItem(source: .github, id: "acme/app#142", title: "app#142 Fix login", list: "app", due: nil, created: nil)

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.headers = nil
        StubProtocol.requests = []
        super.tearDown()
    }

    private func store(_ token: String? = "ghp_tok") -> GitHubTasks {
        GitHubTasks(tokens: FakeTokens(token), session: StubProtocol.session())
    }

    func testAsksForOpenIssuesAssignedToTheUserOldestFirst() {
        let request = GitHubTasks.issuesRequest(token: "tok")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.github.com/issues?filter=assigned&state=open&sort=created&direction=asc&per_page=100")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    func testReadsIssuesLeavingOutPullRequestsAndArchivedRepositories() async throws {
        StubProtocol.handler = { _ in (200, Self.page) }
        let items = try await store().openTasks()
        XCTAssertEqual(items.map(\.title), ["app#142 Fix login", "site#7 No repository object"])
        XCTAssertEqual(items.map(\.id), ["acme/app#142", "acme/site#7"])
        XCTAssertEqual(items.map(\.list), ["app", "site"])
        XCTAssertEqual(items.map(\.source), [.github, .github])
        XCTAssertEqual(items[0].created, TaskDates.parse("2026-10-01T09:00:00Z"))
        XCTAssertNil(items[0].due)
        XCTAssertFalse(items[0].started)
    }

    func testFollowsTheLinkHeader() async throws {
        let next = "https://api.github.com/issues?filter=assigned&state=open&per_page=100&page=2"
        StubProtocol.handler = { request in
            let second = request.url?.query?.contains("page=2") == true
            return (200, second
                    ? #"[{"number":2,"title":"Second","repository_url":"https://api.github.com/repos/a/b"}]"#
                    : #"[{"number":1,"title":"First","repository_url":"https://api.github.com/repos/a/b"}]"#)
        }
        StubProtocol.headers = { request in
            request.url?.query?.contains("page=2") == true
                ? ["Link": #"<https://api.github.com/issues?page=1>; rel="prev", <https://api.github.com/issues?page=1>; rel="first""#]
                : ["Link": "<\(next)>; rel=\"next\", <https://api.github.com/issues?page=2>; rel=\"last\""]
        }
        let items = try await store().openTasks()
        XCTAssertEqual(items.map(\.title), ["b#1 First", "b#2 Second"])
        XCTAssertEqual(StubProtocol.requests.last?.url?.absoluteString, next)
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_tok")
    }

    func testStopsAfterTheLastPageAllowed() async throws {
        StubProtocol.handler = { _ in (200, "[]") }
        StubProtocol.headers = { _ in ["Link": #"<https://api.github.com/issues?page=9>; rel="next""#] }
        _ = try await store().openTasks()
        XCTAssertEqual(StubProtocol.requests.count, GitHubTasks.maxPages)
    }

    func testTheTokenOnlyFollowsLinksToGitHub() {
        XCTAssertNil(GitHubTasks.nextPage(#"<https://evil.example/issues?page=2>; rel="next""#))
        XCTAssertNil(GitHubTasks.nextPage(#"<http://api.github.com/issues?page=2>; rel="next""#))
        XCTAssertNil(GitHubTasks.nextPage(#"<https://api.github.com.evil.example/issues>; rel="next""#))
        XCTAssertNil(GitHubTasks.nextPage(nil))
        XCTAssertEqual(GitHubTasks.nextPage(#"<https://api.github.com/issues?page=2>; rel="next""#)?.host, "api.github.com")
    }

    func testARedirectElsewhereIsntFollowed() async {
        StubProtocol.handler = { request in
            request.url?.host == "api.github.com" ? (302, "") : (200, "[]")
        }
        StubProtocol.headers = { _ in ["Location": "https://evil.example/issues"] }
        do {
            _ = try await store().openTasks()
            XCTFail("a redirect elsewhere can't be read")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .unreachable)
        }
        XCTAssertEqual(StubProtocol.requests.compactMap { $0.url?.host }, ["api.github.com"])
    }

    func testDoneClosesAsCompletedAndUndoReopens() async throws {
        StubProtocol.handler = { request in
            let body = (request.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
            return (200, "{\"number\":142,\"state\":\"\(body["state"] ?? "")\"}")
        }
        let tasks = store()
        let closed = await tasks.setCompleted(issue, true)
        let reopened = await tasks.setCompleted(issue, false)
        XCTAssertTrue(closed)
        XCTAssertTrue(reopened)
        XCTAssertEqual(StubProtocol.requests.map(\.httpMethod), ["PATCH", "PATCH"])
        XCTAssertEqual(StubProtocol.requests.map { $0.url?.absoluteString },
                       Array(repeating: "https://api.github.com/repos/acme/app/issues/142", count: 2))
        let bodies = StubProtocol.requests.compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } }
        XCTAssertEqual(bodies, [["state": "closed", "state_reason": "completed"], ["state": "open", "state_reason": "reopened"]])
    }

    func testAnAnswerWithTheOldStateIsntSaved() async {
        StubProtocol.handler = { _ in (200, #"{"number":142,"state":"open"}"#) }
        let change = await store().change(issue, completed: true)
        XCTAssertEqual(change, .failed)
    }

    func testAReadOnlyTokenIsRefusedWithALine() async {
        for status in [403, 404] {
            StubProtocol.handler = { _ in (status, #"{"message":"Resource not accessible by personal access token"}"#) }
            guard case .refused(let why) = await store().change(issue, completed: true) else {
                return XCTFail("\(status) should be refused")
            }
            XCTAssertFalse(why.isEmpty)
        }
    }

    func testARateLimitIsntARefusalOrARejection() async {
        StubProtocol.handler = { _ in (403, #"{"message":"API rate limit exceeded for user"}"#) }
        let change = await store().change(issue, completed: true)
        XCTAssertEqual(change, .failed)
        do {
            _ = try await store().openTasks()
            XCTFail("a rate limit can't be read")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .unreachable)
        }
        StubProtocol.handler = { _ in (403, "{}") }
        StubProtocol.headers = { _ in ["x-ratelimit-remaining": "0"] }
        let check = await store().connect(token: "fine")
        XCTAssertEqual(check, .unreachable)
    }

    func testABadTokenIsRejected() async {
        StubProtocol.handler = { _ in (401, #"{"message":"Bad credentials"}"#) }
        do {
            _ = try await store("old").openTasks()
            XCTFail("a 401 should be rejected")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
    }

    func testAnIDThatIsntAnIssueAsksNothing() async {
        for id in ["acme/app", "acme#142", "acme/app#x", "../x#1", "a/b/c#1", "acme/..#1", "a b/c#1"] {
            XCTAssertNil(GitHubTasks.issuePath(id), id)
        }
        let task = TaskItem(source: .github, id: "../../user#1", title: "", list: "", due: nil, created: nil)
        let change = await store().change(task, completed: true)
        XCTAssertEqual(change, .failed)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testConnectChecksTheTokenBeforeKeepingIt() async {
        let tokens = FakeTokens()
        let store = GitHubTasks(tokens: tokens, session: StubProtocol.session())
        StubProtocol.handler = { _ in (401, "") }
        let rejected = await store.connect(token: "wrong")
        XCTAssertEqual(rejected, .rejected)
        XCTAssertNil(tokens.token)
        XCTAssertFalse(store.hasToken)

        StubProtocol.handler = { _ in (500, "") }
        let down = await store.connect(token: "fine")
        XCTAssertEqual(down, .unreachable)
        XCTAssertNil(tokens.token)

        StubProtocol.handler = { _ in (200, #"{"login":"octocat"}"#) }
        let accepted = await store.connect(token: "  right \n")
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(tokens.token, "right")
        XCTAssertEqual(StubProtocol.requests.last?.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer right")

        store.disconnect()
        XCTAssertNil(tokens.token)
    }

    func testWithoutATokenNothingIsAsked() async throws {
        let items = try await store(nil).openTasks()
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
}

// MARK: - Jira

final class JiraSiteTests: XCTestCase {
    func testTakesTheSiteHoweverItsTyped() {
        for typed in ["acme", " acme \n", "ACME", "acme.atlassian.net", "Acme.Atlassian.NET", "https://acme.atlassian.net",
                      "https://acme.atlassian.net/", "https://acme.atlassian.net/jira/software/projects/ENG/boards/1?x=1#y",
                      "acme.atlassian.net/jira/your-work"] {
            XCTAssertEqual(JiraSite.url(from: typed)?.absoluteString, "https://acme.atlassian.net", typed)
        }
        XCTAssertEqual(JiraSite.url(from: "my-team-2")?.absoluteString, "https://my-team-2.atlassian.net")
    }

    func testRefusesEverythingElse() {
        for typed in ["", "   ", "http://acme.atlassian.net", "ftp://acme.atlassian.net", "evil.com", "https://evil.com",
                      "atlassian.net", ".atlassian.net", "https://atlassian.net", "acme.atlassian.net.evil.com",
                      "https://acme.atlassian.net.evil.com/", "evilatlassian.net", "https://evilatlassian.net",
                      "acme.atlassian.com", "api.atlassian.com", "acme.jira.com",
                      "https://acme.atlassian.net@evil.com", "acme.atlassian.net@evil.com", "user:pass@acme.atlassian.net",
                      "https://user:pass@acme.atlassian.net", "https://acme.atlassian.net:8443", "acme.atlassian.net:443",
                      "https://evil.com/acme.atlassian.net", "https://evil.com?x=.atlassian.net", "https://evil.com#.atlassian.net",
                      "https://evil.com%2f.atlassian.net", "evil.com\\.atlassian.net", "acme.atlassian.net.", "-acme.atlassian.net",
                      "ac me", "ac me.atlassian.net", "localhost:8080", "acme/evil", "аcme.atlassian.net", "javascript:alert(1)"] {
            XCTAssertNil(JiraSite.url(from: typed), typed)
        }
    }

    func testARedirectIsHeldToTheSameRule() throws {
        let allowed = ["https://acme.atlassian.net/rest/api/3/myself", "https://renamed.atlassian.net/x"]
        for text in allowed { XCTAssertTrue(JiraSite.isAllowed(try XCTUnwrap(URL(string: text))), text) }
        let refused = ["http://acme.atlassian.net/", "https://evil.com/", "https://acme.atlassian.net.evil.com/",
                       "https://acme.atlassian.net:8443/", "https://u@acme.atlassian.net/"]
        for text in refused { XCTAssertFalse(JiraSite.isAllowed(try XCTUnwrap(URL(string: text))), text) }
    }
}

final class JiraTasksTests: XCTestCase {
    private static let page = """
    {"isLast":true,"issues":[
      {"id":"10042","key":"ENG-142","self":"https://acme.atlassian.net/rest/api/3/issue/10042","fields":{
        "summary":"Fix login","duedate":null,"created":"2026-10-01T09:00:00.000+0200",
        "project":{"key":"ENG","name":"Engineering"},
        "status":{"id":"3","name":"In Progress","statusCategory":{"id":4,"key":"indeterminate","name":"In Progress"}}}},
      {"id":"10043","key":"ENG-150","fields":{
        "summary":"Write release notes","duedate":"2026-10-26","created":"2026-10-02T09:00:00.000+0200",
        "project":{"key":"ENG","name":"Engineering"},
        "status":{"id":"1","name":"To Do","statusCategory":{"id":2,"key":"new","name":"To Do"}}}},
      {"id":"10044","key":"ENG-151","fields":{"summary":"  ","status":{"id":"1"}}},
      {"id":"10045","key":"ENG-152","fields":{"summary":"Lagging behind","status":{"id":"9","statusCategory":{"key":"done"}}}}
    ]}
    """
    private static let me = #"{"accountId":"5b10a2844c20165700ede21g","emailAddress":"me@acme.test"}"#
    /// To Do from In Progress, "Won't Do" and "Done", and "Close" needing a field.
    private static let transitions = """
    {"transitions":[
      {"id":"11","name":"Stop","hasScreen":false,"isAvailable":true,"to":{"id":"1","name":"To Do","statusCategory":{"key":"new"}}},
      {"id":"21","name":"Won't do","isAvailable":true,"to":{"id":"6","name":"Won't Do","statusCategory":{"key":"done"}}},
      {"id":"31","name":"Finish","isAvailable":true,"to":{"id":"7","name":"Done","statusCategory":{"key":"done"}}}
    ]}
    """

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let issue = TaskItem(source: .jira, id: "10042", title: "ENG-142 Fix login", list: "Engineering",
                                 due: nil, created: nil, started: true, state: "3")
    private let credentials = JiraTasks.Credentials(site: URL(string: "https://acme.atlassian.net")!, email: "me@acme.test", token: "tok")

    override func setUp() {
        super.setUp()
        suiteName = "JiraTasksTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        StubProtocol.handler = nil
        StubProtocol.headers = nil
        StubProtocol.requests = []
        super.tearDown()
    }

    /// A store already connected to acme.
    private func connected(tokens: FakeTokens = FakeTokens("tok")) -> JiraTasks {
        defaults.set("acme.atlassian.net", forKey: "integrations.jira.site")
        defaults.set("me@acme.test", forKey: "integrations.jira.email")
        return JiraTasks(tokens: tokens, defaults: defaults, session: StubProtocol.session())
    }

    private func searchBody(_ request: URLRequest?) -> JiraTasks.SearchBody? {
        request?.httpBody.flatMap { try? JSONDecoder().decode(JiraTasks.SearchBody.self, from: $0) }
    }

    private func moves() -> [String] {
        StubProtocol.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/transitions") == true }.compactMap {
            $0.httpBody.flatMap { try? JSONDecoder().decode(JiraTasks.MoveBody.self, from: $0) }?.transition.id
        }
    }

    /// Answers by endpoint, with a move that goes through.
    private func answer(transitions: String = JiraTasksTests.transitions, move: Int = 204, status: String = "{}") {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/transitions") { return request.httpMethod == "POST" ? (move, "") : (200, transitions) }
            if path.hasSuffix("/myself") { return (200, Self.me) }
            return (200, status)
        }
    }

    // MARK: Requests

    func testSearchUsesTheCurrentEndpointWithBasicAuth() {
        let request = JiraTasks.searchRequest(credentials, nextPageToken: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://acme.atlassian.net/rest/api/3/search/jql")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("me@acme.test:tok".utf8).base64EncodedString())
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = searchBody(request)
        XCTAssertEqual(body?.jql, "assignee = currentUser() AND statusCategory != Done ORDER BY duedate ASC, created ASC")
        XCTAssertEqual(body?.fields, ["summary", "status", "duedate", "created", "project"])
        XCTAssertEqual(body?.maxResults, 100)
        XCTAssertNil(body?.nextPageToken)
        XCTAssertNil(body?.reconcileIssues)
    }

    func testOtherRequests() {
        XCTAssertEqual(JiraTasks.myselfRequest(credentials).url?.absoluteString, "https://acme.atlassian.net/rest/api/3/myself")
        XCTAssertEqual(JiraTasks.transitionsRequest(credentials, id: "10042").url?.absoluteString,
                       "https://acme.atlassian.net/rest/api/3/issue/10042/transitions?expand=transitions.fields")
        XCTAssertEqual(JiraTasks.statusRequest(credentials, id: "10042").url?.absoluteString,
                       "https://acme.atlassian.net/rest/api/3/issue/10042?fields=status")
        let move = JiraTasks.moveRequest(credentials, id: "10042", transition: "31")
        XCTAssertEqual(move.httpMethod, "POST")
        XCTAssertEqual(move.url?.path, "/rest/api/3/issue/10042/transitions")
        XCTAssertEqual(move.httpBody.flatMap { try? JSONDecoder().decode(JiraTasks.MoveBody.self, from: $0) },
                       JiraTasks.MoveBody(transition: .init(id: "31")))
    }

    // MARK: Reading

    func testReadsIssuesWithTheirKeyAndStatus() async throws {
        StubProtocol.handler = { _ in (200, Self.page) }
        let items = try await connected().openTasks()
        XCTAssertEqual(items.map(\.title), ["ENG-142 Fix login", "ENG-150 Write release notes"])
        XCTAssertEqual(items.map(\.id), ["10042", "10043"])
        XCTAssertEqual(items.map(\.list), ["Engineering", "Engineering"])
        XCTAssertEqual(items.map(\.source), [.jira, .jira])
        XCTAssertEqual(items.map(\.started), [true, false])
        XCTAssertEqual(items.map(\.state), ["3", "1"])
        XCTAssertNil(items[0].due)
        XCTAssertEqual(items[1].due, TaskDates.parse("2026-10-26"))
        XCTAssertEqual(items[0].created, TaskDates.parse("2026-10-01T07:00:00Z"))
    }

    func testFollowsNextPageToken() async throws {
        func raw(_ id: String) -> String { #"{"id":"\#(id)","key":"K-\#(id)","fields":{"summary":"S","status":{"id":"1"}}}"# }
        StubProtocol.handler = { [self] request in
            searchBody(request)?.nextPageToken == "next+1=="
                ? (200, #"{"isLast":true,"issues":[\#(raw("2"))]}"#)
                : (200, #"{"isLast":false,"nextPageToken":"next+1==","issues":[\#(raw("1"))]}"#)
        }
        let items = try await connected().openTasks()
        XCTAssertEqual(items.map(\.id), ["1", "2"])
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testStopsAfterTheLastPageAllowedAndWithoutAToken() async throws {
        func answer(_ extra: String) -> String { #"{\#(extra)"issues":[{"id":"1","fields":{"summary":"S"}}]}"# }
        StubProtocol.handler = { _ in (200, answer(#""nextPageToken":"more","#)) }
        _ = try await connected().openTasks()
        XCTAssertEqual(StubProtocol.requests.count, JiraTasks.maxPages)

        StubProtocol.requests = []
        StubProtocol.handler = { _ in (200, answer("")) }
        _ = try await connected().openTasks()
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testAnEmptySearchChecksWhosAsking() async throws {
        // Jira can answer a bad token as if nobody were signed in.
        StubProtocol.handler = { request in
            request.url?.path.hasSuffix("/myself") == true ? (401, "") : (200, #"{"isLast":true,"issues":[]}"#)
        }
        let store = connected()
        do {
            _ = try await store.openTasks()
            XCTFail("nobody signed in should be rejected")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }

        StubProtocol.handler = { request in
            request.url?.path.hasSuffix("/myself") == true ? (200, Self.me) : (200, #"{"isLast":true,"issues":[]}"#)
        }
        let items = try await connected().openTasks()
        XCTAssertTrue(items.isEmpty)
    }

    func testABadQueryFromABadTokenIsRejectedToo() async {
        StubProtocol.handler = { request in
            request.url?.path.hasSuffix("/myself") == true ? (401, "") : (400, #"{"errorMessages":["Invalid"]}"#)
        }
        do {
            _ = try await connected().openTasks()
            XCTFail("should be rejected")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
    }

    func testARejectedTokenIsntTriedAgainForAWhile() async {
        StubProtocol.handler = { _ in (401, "") }
        let store = connected()
        for _ in 0..<3 {
            do {
                _ = try await store.openTasks()
                XCTFail("should be rejected")
            } catch {
                XCTAssertEqual(error as? TaskSourceProblem, .rejected)
            }
        }
        XCTAssertEqual(StubProtocol.requests.count, 1)
        let change = await store.change(issue, completed: true)
        XCTAssertEqual(change, .failed)
        XCTAssertEqual(StubProtocol.requests.count, 1)

        // A new token is tried straight away, and lifts the pause.
        StubProtocol.handler = { request in
            request.url?.path.hasSuffix("/myself") == true ? (200, Self.me) : (200, Self.page)
        }
        let check = await store.connect(site: "acme", email: "me@acme.test", token: "new")
        XCTAssertEqual(check, .accepted)
        let items = try? await store.openTasks()
        XCTAssertEqual(items?.count, 2)
    }

    func testASiteThatCantBeReachedIsUnreachable() async {
        StubProtocol.handler = { _ in (503, "") }
        do {
            _ = try await connected().openTasks()
            XCTFail("should be unreachable")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .unreachable)
        }
    }

    // MARK: Only ever to the site

    func testASavedAddressElsewhereSendsNothing() async throws {
        defaults.set("evil.com", forKey: "integrations.jira.site")
        defaults.set("me@acme.test", forKey: "integrations.jira.email")
        let store = JiraTasks(tokens: FakeTokens("tok"), defaults: defaults, session: StubProtocol.session())
        XCTAssertFalse(store.hasToken)
        let items = try await store.openTasks()
        XCTAssertTrue(items.isEmpty)
        let change = await store.change(issue, completed: true)
        XCTAssertEqual(change, .failed)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testConnectRefusesAnotherHostWithoutAsking() async {
        let tokens = FakeTokens()
        let store = JiraTasks(tokens: tokens, defaults: defaults, session: StubProtocol.session())
        for site in ["evil.com", "http://acme.atlassian.net", "acme.atlassian.net.evil.com", "https://acme.atlassian.net@evil.com"] {
            let check = await store.connect(site: site, email: "me@acme.test", token: "tok")
            XCTAssertEqual(check, .badSite, site)
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        XCTAssertNil(tokens.token)
    }

    func testARedirectOffTheSiteIsntFollowed() async {
        StubProtocol.handler = { request in
            request.url?.host == "acme.atlassian.net" ? (302, "") : (200, Self.me)
        }
        StubProtocol.headers = { _ in ["Location": "https://evil.example/rest/api/3/myself"] }
        let tokens = FakeTokens()
        let store = JiraTasks(tokens: tokens, defaults: defaults, session: StubProtocol.session())
        let check = await store.connect(site: "acme", email: "me@acme.test", token: "tok")
        XCTAssertEqual(check, .unreachable)
        XCTAssertEqual(StubProtocol.requests.compactMap { $0.url?.host }, ["acme.atlassian.net"])
        XCTAssertNil(tokens.token)
    }

    // MARK: Connecting

    func testConnectKeepsOnlyWhatJiraTakes() async {
        let tokens = FakeTokens()
        let store = JiraTasks(tokens: tokens, defaults: defaults, session: StubProtocol.session())

        StubProtocol.handler = { _ in (401, "") }
        let rejected = await store.connect(site: "acme", email: "me@acme.test", token: "wrong")
        XCTAssertEqual(rejected, .rejected)
        XCTAssertNil(tokens.token)
        XCTAssertFalse(store.hasToken)
        XCTAssertNil(store.account)

        StubProtocol.handler = { _ in (500, "") }
        let down = await store.connect(site: "acme", email: "me@acme.test", token: "fine")
        XCTAssertEqual(down, .unreachable)
        XCTAssertNil(tokens.token)

        let empty = await store.connect(site: "acme", email: "  ", token: "fine")
        XCTAssertEqual(empty, .rejected)

        StubProtocol.handler = { _ in (200, Self.me) }
        let accepted = await store.connect(site: "https://ACME.atlassian.net/jira", email: " me@acme.test ", token: " right\n")
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(tokens.token, "right")
        XCTAssertTrue(store.hasToken)
        XCTAssertEqual(store.account?.site, "acme.atlassian.net")
        XCTAssertEqual(store.account?.email, "me@acme.test")
        XCTAssertEqual(defaults.string(forKey: "integrations.jira.site"), "acme.atlassian.net")
        XCTAssertEqual(StubProtocol.requests.last?.url?.absoluteString, "https://acme.atlassian.net/rest/api/3/myself")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("me@acme.test:right".utf8).base64EncodedString())

        store.disconnect()
        XCTAssertNil(tokens.token)
        XCTAssertFalse(store.hasToken)
        XCTAssertNil(defaults.string(forKey: "integrations.jira.email"))
    }

    func testTheTokenIsntInTheDefaults() async {
        StubProtocol.handler = { _ in (200, Self.me) }
        let store = JiraTasks(tokens: FakeTokens(), defaults: defaults, session: StubProtocol.session())
        _ = await store.connect(site: "acme", email: "me@acme.test", token: "s3cret")
        let saved = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(saved.values.contains { "\($0)".contains("s3cret") })
    }

    // MARK: Choosing a transition

    private func decoded(_ json: String) throws -> [JiraTasks.RawTransition] {
        try JiraTasks.decode(JiraTasks.Transitions.self, from: Data(json.utf8)).transitions
    }

    func testDonePrefersAStatusCalledDoneOverOnesThatDropTheWork() throws {
        XCTAssertEqual(JiraTasks.doneTransition(in: try decoded(Self.transitions))?.id, "31")
    }

    func testDoneTakesTheFirstOtherDoneCategoryStatus() throws {
        let json = """
        {"transitions":[
          {"id":"1","name":"Start","to":{"id":"3","name":"In Progress","statusCategory":{"key":"indeterminate"}}},
          {"id":"2","name":"Resolve","to":{"id":"8","name":"Resolved","statusCategory":{"key":"done"}}},
          {"id":"3","name":"Close","to":{"id":"9","name":"Closed","statusCategory":{"key":"done"}}}
        ]}
        """
        XCTAssertEqual(JiraTasks.doneTransition(in: try decoded(json))?.id, "2")
    }

    func testDoneWontUseACancelledStatusUnavailableOnesOrRequiredFields() throws {
        let json = """
        {"transitions":[
          {"id":"1","name":"Cancel","to":{"id":"6","name":"Cancelled","statusCategory":{"key":"done"}}},
          {"id":"2","name":"Finish","isAvailable":false,"to":{"id":"7","name":"Done","statusCategory":{"key":"done"}}},
          {"id":"3","name":"Finish","fields":{"customfield_1":{"required":true,"hasDefaultValue":false,"name":"Root cause"}},
           "to":{"id":"7","name":"Done","statusCategory":{"key":"done"}}}
        ]}
        """
        XCTAssertNil(JiraTasks.doneTransition(in: try decoded(json)))
    }

    func testAFieldWithADefaultOrOptionalDoesntStopATransition() throws {
        let json = """
        {"transitions":[
          {"id":"3","name":"Finish","hasScreen":true,"fields":{
            "resolution":{"required":true,"hasDefaultValue":true},
            "comment":{"required":false,"hasDefaultValue":false}},
           "to":{"id":"7","name":"Done","statusCategory":{"key":"done"}}}
        ]}
        """
        XCTAssertEqual(JiraTasks.doneTransition(in: try decoded(json))?.id, "3")
    }

    // MARK: Moving

    func testDoneMovesThroughTheDoneTransition() async {
        answer()
        let saved = await connected().setCompleted(issue, true)
        XCTAssertTrue(saved)
        XCTAssertEqual(moves(), ["31"])
        XCTAssertEqual(StubProtocol.requests.first?.url?.query, "expand=transitions.fields")
    }

    func testUndoMovesBackToTheStatusItWasIn() async {
        let back = """
        {"transitions":[
          {"id":"41","name":"Reopen","to":{"id":"1","name":"To Do","statusCategory":{"key":"new"}}},
          {"id":"42","name":"Back to work","to":{"id":"3","name":"In Progress","statusCategory":{"key":"indeterminate"}}}
        ]}
        """
        answer(transitions: back)
        let saved = await connected().setCompleted(issue, false)
        XCTAssertTrue(saved)
        XCTAssertEqual(moves(), ["42"])
    }

    func testWithNoTransitionThatFitsTheIssueIsLeftAlone() async {
        let none = #"{"transitions":[{"id":"11","name":"Stop","to":{"id":"1","name":"To Do","statusCategory":{"key":"new"}}}]}"#
        answer(transitions: none, status: #"{"id":"10042","fields":{"status":{"id":"3","statusCategory":{"key":"indeterminate"}}}}"#)
        let store = connected()

        guard case .refused(let done) = await store.change(issue, completed: true) else { return XCTFail("should be refused") }
        XCTAssertFalse(done.isEmpty)
        XCTAssertTrue(moves().isEmpty)

        let inDone = TaskItem(source: .jira, id: "10042", title: "ENG-142 Fix login", list: "", due: nil, created: nil, state: "99")
        guard case .refused(let back) = await store.change(inDone, completed: false) else { return XCTFail("should be refused") }
        XCTAssertNotEqual(done, back)
        XCTAssertTrue(moves().isEmpty)
    }

    func testAnIssueWithNoTransitionsOrNoLongerThereIsRefused() async {
        StubProtocol.handler = { _ in (404, #"{"errorMessages":["Issue does not exist"]}"#) }
        guard case .refused = await connected().change(issue, completed: true) else { return XCTFail("should be refused") }
    }

    func testAnIssueAlreadyThereCountsAsSaved() async {
        answer(transitions: #"{"transitions":[]}"#, status: #"{"id":"10042","fields":{"status":{"id":"7","statusCategory":{"key":"done"}}}}"#)
        let done = await connected().change(issue, completed: true)
        XCTAssertEqual(done, .saved)
        XCTAssertTrue(moves().isEmpty)

        answer(transitions: #"{"transitions":[]}"#, status: #"{"id":"10042","fields":{"status":{"id":"3","statusCategory":{"key":"indeterminate"}}}}"#)
        let back = await connected().change(issue, completed: false)
        XCTAssertEqual(back, .saved)
    }

    func testATransitionThatFailsIsRefusedCleanly() async {
        // A required field the screen data didn't show, a conflict, no permission.
        for status in [400, 403, 404, 409, 422] {
            answer(move: status)
            guard case .refused = await connected().change(issue, completed: true) else {
                return XCTFail("\(status) should be refused")
            }
        }
        answer(move: 500)
        let down = await connected().change(issue, completed: true)
        XCTAssertEqual(down, .failed)
    }

    func testASearchAfterAMoveReadsThatIssueFresh() async throws {
        answer(status: Self.page)
        let store = connected()
        let saved = await store.setCompleted(issue, true)
        XCTAssertTrue(saved)
        StubProtocol.requests = []
        StubProtocol.handler = { _ in (200, Self.page) }
        _ = try await store.openTasks()
        XCTAssertEqual(searchBody(StubProtocol.requests.first)?.reconcileIssues, [10042])
    }

    func testWithoutCredentialsNothingIsAsked() async throws {
        let store = JiraTasks(tokens: FakeTokens(), defaults: defaults, session: StubProtocol.session())
        let items = try await store.openTasks()
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(store.hasToken)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
}

// MARK: - The coordinator, with every source

@MainActor
final class TaskSourcesCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var reminders: FakeTaskStore!
    private var todoist: FakeTaskStore!
    private var linear: FakeTaskStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TaskSourcesCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        let today = Calendar.current.startOfDay(for: .now)
        reminders = FakeTaskStore(.reminders, [TaskItem(id: "plan", title: "Plan the week", list: "Work", due: nil, created: nil)])
        todoist = FakeTaskStore(.todoist, [
            TaskItem(source: .todoist, id: "rent", title: "Pay rent", list: "Home", due: today, created: nil),
            TaskItem(source: .todoist, id: "bank", title: "Call the bank", list: "Home", due: today.addingTimeInterval(-86_400), created: nil),
        ])
        linear = FakeTaskStore(.linear, [TaskItem(source: .linear, id: "eng", title: "ENG-142 Fix login", list: "Engineering",
                                                  due: nil, created: nil, started: true, state: "started")])
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    private func make(on sources: [TaskSource] = [.reminders, .todoist, .linear]) -> IntegrationsCoordinator {
        let entitlements = Entitlements(defaults: defaults)
        entitlements.startTrialIfNeeded(for: .taskGoals)
        for source in TaskSource.allCases { defaults.set(sources.contains(source), forKey: source.settingKey) }
        defaults.set(false, forKey: IntegrationSettings.gitBranch)
        let coordinator = IntegrationsCoordinator(calendar: NoCalendar(), reminders: NoReminders(),
                                                  tasks: [reminders, todoist, linear],
                                                  entitlements: entitlements, defaults: defaults)
        coordinator.isShipped = true
        return coordinator
    }

    private func session(goal: String?) -> Session {
        let session = Session(startedAt: .now, plannedDurationMinutes: 25)
        session.goal = goal
        context.insert(session)
        return session
    }

    func testTasksFromEverySourceComeTogetherBestFirst() async {
        let coordinator = make()
        await coordinator.refreshGoalSources()
        XCTAssertEqual(coordinator.taskGoals.map(\.id), ["rent", "bank", "eng", "plan"])

        defaults.set(false, forKey: IntegrationSettings.todoist)
        await coordinator.refreshTasks()
        XCTAssertEqual(coordinator.taskGoals.map(\.id), ["eng", "plan"])
    }

    func testATurnedDownTokenIsShownAndASourceThatCantBeReachedKeepsItsTasks() async {
        let coordinator = make()
        await coordinator.refreshTasks()

        todoist.problem = .unreachable
        await coordinator.refreshTasks()
        XCTAssertEqual(coordinator.taskGoals.filter { $0.source == .todoist }.count, 2)
        XCTAssertNil(coordinator.taskProblems[.todoist])

        todoist.problem = .rejected
        await coordinator.refreshTasks()
        XCTAssertTrue(coordinator.taskGoals.allSatisfy { $0.source != .todoist })
        XCTAssertEqual(coordinator.taskProblems[.todoist], .rejected)

        todoist.problem = nil
        await coordinator.refreshTasks()
        XCTAssertNil(coordinator.taskProblems[.todoist])
    }

    func testDoneTicksTheTaskOffInItsOwnSourceAndOffersTheNextFromAny() async {
        todoist.items = [todoist.items[0]]
        let coordinator = make()
        await coordinator.refreshTasks()
        coordinator.goalPicked(GoalSuggestion(text: "Pay rent", source: .task(.todoist, id: "rent", list: "Home")))
        XCTAssertEqual(coordinator.pickedTask?.source, .todoist)

        let session = session(goal: "Pay rent")
        await coordinator.sessionStarted(session, startedByEvent: false)
        XCTAssertEqual(coordinator.taskLinks[session.id]?.task.source, .todoist)

        session.goalVerdict = .done
        await coordinator.verdictChanged(session, byUser: true)
        XCTAssertEqual(todoist.completions.map(\.0), ["rent"])
        XCTAssertTrue(reminders.completions.isEmpty)
        XCTAssertEqual(coordinator.nextTasks[session.id]?.id, "eng")
        XCTAssertFalse(coordinator.taskGoals.contains { $0.id == "rent" })

        await coordinator.undoTick(session: session.id)
        XCTAssertEqual(todoist.completions.last?.1, false)
        XCTAssertNil(coordinator.nextTasks[session.id])
        XCTAssertTrue(coordinator.taskGoals.contains { $0.id == "rent" })
    }

    func testAServiceThatRefusesLeavesTheTaskUntickedWithALine() async {
        let coordinator = make()
        await coordinator.refreshTasks()
        coordinator.goalPicked(GoalSuggestion(text: "Pay rent", source: .task(.todoist, id: "rent", list: "Home")))
        let session = session(goal: "Pay rent")
        await coordinator.sessionStarted(session, startedByEvent: false)

        todoist.refusal = "No transition"
        session.goalVerdict = .done
        await coordinator.verdictChanged(session, byUser: true)
        XCTAssertEqual(coordinator.taskLinks[session.id]?.ticked, false)
        XCTAssertEqual(coordinator.tickNotes[session.id], "No transition")
        XCTAssertNil(coordinator.nextTasks[session.id])

        // The next try that works clears the line.
        todoist.refusal = nil
        await coordinator.tickOff(session: session.id)
        XCTAssertEqual(coordinator.taskLinks[session.id]?.ticked, true)
        XCTAssertNil(coordinator.tickNotes[session.id])
    }

    func testAnUndoThatsRefusedStaysTicked() async {
        let coordinator = make()
        await coordinator.refreshTasks()
        coordinator.goalPicked(GoalSuggestion(text: "Pay rent", source: .task(.todoist, id: "rent", list: "Home")))
        let session = session(goal: "Pay rent")
        await coordinator.sessionStarted(session, startedByEvent: false)
        session.goalVerdict = .done
        await coordinator.verdictChanged(session, byUser: true)

        todoist.refusal = "No way back"
        await coordinator.undoTick(session: session.id)
        XCTAssertEqual(coordinator.taskLinks[session.id]?.ticked, true)
        XCTAssertEqual(coordinator.tickNotes[session.id], "No way back")

        todoist.refusal = nil
        await coordinator.undoTick(session: session.id)
        XCTAssertEqual(coordinator.taskLinks[session.id]?.ticked, false)
        XCTAssertNil(coordinator.tickNotes[session.id])
    }

    func testGitHubAndJiraComeWithTheRestAndSwitchOffAlone() async {
        let github = FakeTaskStore(.github, [TaskItem(source: .github, id: "acme/app#1", title: "app#1 Old", list: "app", due: nil, created: nil)])
        let jira = FakeTaskStore(.jira, [TaskItem(source: .jira, id: "10042", title: "ENG-142 Fix login", list: "Engineering",
                                                  due: nil, created: nil, started: true, state: "3")])
        let entitlements = Entitlements(defaults: defaults)
        entitlements.startTrialIfNeeded(for: .taskGoals)
        for source in TaskSource.allCases { defaults.set(source == .github || source == .jira, forKey: source.settingKey) }
        defaults.set(false, forKey: IntegrationSettings.gitBranch)
        let coordinator = IntegrationsCoordinator(calendar: NoCalendar(), reminders: NoReminders(), tasks: [github, jira],
                                                  entitlements: entitlements, defaults: defaults)
        coordinator.isShipped = true
        await coordinator.refreshTasks()
        XCTAssertEqual(coordinator.taskGoals.map(\.id), ["10042", "acme/app#1"])

        jira.problem = .unreachable
        await coordinator.refreshTasks()
        XCTAssertEqual(coordinator.taskGoals.count, 2)

        github.problem = .rejected
        await coordinator.refreshTasks()
        XCTAssertEqual(coordinator.taskGoals.map(\.id), ["10042"])
        XCTAssertEqual(coordinator.taskProblems[.github], .rejected)

        defaults.set(false, forKey: IntegrationSettings.jira)
        await coordinator.refreshTasks()
        XCTAssertTrue(coordinator.taskGoals.isEmpty)
    }

    func testATaskFromASourceSwitchedOffIsntLinked() async {
        let coordinator = make()
        await coordinator.refreshTasks()
        coordinator.goalPicked(GoalSuggestion(text: "Pay rent", source: .task(.todoist, id: "rent", list: "Home")))
        defaults.set(false, forKey: IntegrationSettings.todoist)
        let session = session(goal: "Pay rent")
        await coordinator.sessionStarted(session, startedByEvent: false)
        XCTAssertNil(coordinator.taskLinks[session.id])
    }

    func testLinksSavedBy0334StillTickOffTheirReminder() {
        let id = UUID()
        let saved = #"{"\#(id.uuidString)":{"reminder":{"id":"plan","title":"Plan the week","list":"Work"},"linkedAt":815000000,"ticked":false,"undone":false}}"#
        defaults.set(Data(saved.utf8), forKey: "integrations.reminders.sessionLinks")
        let coordinator = make()
        XCTAssertEqual(coordinator.taskLinks[id]?.task.source, .reminders)
        XCTAssertEqual(coordinator.taskLinks[id]?.task.id, "plan")
    }
}
