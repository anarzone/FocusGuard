import SwiftData
import XCTest
@testable import FocusGuard

// Things, Todoist and Linear as session goals (Pro). Nothing here talks to
// Things or the real services: scripts are checked as text, requests as
// built, and answers come from fixtures through a stub URL protocol.

// MARK: - Fakes

/// Answers every request from `handler`, and keeps what was asked.
private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
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
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
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

private final class FakeTokens: TokenStore {
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
}

private final class NoCalendar: CalendarStore {
    func calendars() async -> [CalendarChoice] { [] }
    func defaultCalendarID() async -> String? { nil }
    func events(from start: Date, to end: Date, calendarIDs: [String], ownIDs: Set<String>) async -> [CalendarEntry]? { [] }
    func create(_ draft: SessionEventDraft, calendarID: String?) async -> String? { nil }
    func update(_ ref: OwnEventRef, to draft: SessionEventDraft) async -> String? { nil }
    func remove(_ ref: OwnEventRef) async -> Bool { true }
}

private final class NoReminders: ReminderStore {
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
        await coordinator.verdictChanged(session, byUser: false)
        XCTAssertEqual(todoist.completions.map(\.0), ["rent"])
        XCTAssertTrue(reminders.completions.isEmpty)
        XCTAssertEqual(coordinator.nextTasks[session.id]?.id, "eng")
        XCTAssertFalse(coordinator.taskGoals.contains { $0.id == "rent" })

        await coordinator.undoTick(session: session.id)
        XCTAssertEqual(todoist.completions.last?.1, false)
        XCTAssertNil(coordinator.nextTasks[session.id])
        XCTAssertTrue(coordinator.taskGoals.contains { $0.id == "rent" })
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
