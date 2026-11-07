import Foundation

/// Where a task offered as a goal comes from (Pro).
enum TaskSource: String, Codable, CaseIterable, Sendable {
    case reminders, things, todoist, linear, github, jira

    var name: String {
        switch self {
        case .reminders: return String(localized: "Reminders", comment: "Apple's Reminders app, by its name in this language")
        case .things:    return "Things"
        case .todoist:   return "Todoist"
        case .linear:    return "Linear"
        case .github:    return "GitHub"
        case .jira:      return "Jira"
        }
    }

    /// Settings lists them in this order; it settles ties between them.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Its switch in Settings › Integrations.
    var settingKey: String {
        switch self {
        case .reminders: return IntegrationSettings.reminders
        case .things:    return IntegrationSettings.things
        case .todoist:   return IntegrationSettings.todoist
        case .linear:    return IntegrationSettings.linear
        case .github:    return IntegrationSettings.github
        case .jira:      return IntegrationSettings.jira
        }
    }
}

extension IntegrationSettings {
    /// To-dos in Things' Today list are offered as session goals (Pro).
    static let things = "integrations.things.enabled"
    /// Todoist tasks due today or overdue (Pro); the token is in the Keychain.
    static let todoist = "integrations.todoist.enabled"
    /// Linear issues assigned to the user (Pro); the key is in the Keychain.
    static let linear = "integrations.linear.enabled"
    /// Open GitHub issues assigned to the user (Pro); the token is in the Keychain.
    static let github = "integrations.github.enabled"
    /// Jira Cloud issues assigned to the user (Pro); the token is in the Keychain.
    static let jira = "integrations.jira.enabled"
}

/// An open task, offered as a goal: a reminder, a Things to-do, a Todoist
/// task, or a Linear, GitHub or Jira issue.
struct TaskItem: Equatable, Identifiable, Codable, Sendable {
    var source: TaskSource = .reminders
    /// The source's own identifier.
    let id: String
    let title: String
    /// Where it's filed: the Reminders list, the Things project or area,
    /// the Todoist project, the Linear team, the GitHub repository, the Jira
    /// project.
    let list: String
    let due: Date?
    let created: Date?
    /// Being worked on (a started Linear issue, a Jira one in progress):
    /// offered before ones that aren't due yet.
    var started = false
    /// The Linear state or Jira status it was in, to move it back on Undo.
    var state: String?

    func isSame(as other: TaskItem) -> Bool { source == other.source && id == other.id }
}

extension TaskItem {
    private enum CodingKeys: String, CodingKey {
        case source, id, title, list, due, created, started, state
    }

    /// Reminders saved by 0.3.34 have no source.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(TaskSource.self, forKey: .source) ?? .reminders
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        list = try container.decodeIfPresent(String.self, forKey: .list) ?? ""
        due = try container.decodeIfPresent(Date.self, forKey: .due)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        started = try container.decodeIfPresent(Bool.self, forKey: .started) ?? false
        state = try container.decodeIfPresent(String.self, forKey: .state)
    }
}

/// Open tasks offered as session goals (Pro), from every source switched
/// on. What fits the work in front comes first: a task that names the repo,
/// branch or window being worked in, then one already in progress, then one
/// due today, then one overdue by a week at most, then one due later, then
/// the rest, oldest first. Overdue by more than a week isn't offered: it's
/// been put off, and leading with it is noise.
enum TaskGoals {
    /// At most this many are offered under the goal field, whatever the source.
    static let offered = 2
    /// Overdue by more than this, a task stops being offered.
    static let staleAfterDays = 7

    /// - Parameter context: what's being worked on: the repo, the branch, the
    ///   front window's title.
    static func ordered(_ items: [TaskItem], now: Date, context: [String] = [], calendar: Calendar = .current) -> [TaskItem] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let stale = calendar.date(byAdding: .day, value: -staleAfterDays, to: today) ?? today
        let words = contextWords(context)
        func rank(_ item: TaskItem) -> Int {
            if !words.isEmpty, !Self.words(in: "\(item.title) \(item.list)").isDisjoint(with: words) { return 0 }
            if item.started { return 1 }
            if let due = item.due, due < tomorrow { return due < today ? 3 : 2 }
            return item.due == nil ? 5 : 4
        }
        return items.filter { item in
            guard let due = item.due, !item.started else { return true }
            return due >= stale
        }
        .sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if let da = a.due, let db = b.due, da != db { return da < db }
            if let ca = a.created, let cb = b.created, ca != cb { return ca < cb }
            let byTitle = a.title.localizedStandardCompare(b.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            if a.source != b.source { return a.source.order < b.source.order }
            return a.id < b.id
        }
    }

    /// Words that can tie a task to the work: four letters or more, or an
    /// issue number, lowercased, without the everyday ones.
    static func words(in text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(parts.filter { word in
            guard !common.contains(word) else { return false }
            return word.count >= 4 || (word.count >= 2 && word.allSatisfy(\.isNumber))
        })
    }

    private static func contextWords(_ context: [String]) -> Set<String> {
        context.reduce(into: Set<String>()) { $0.formUnion(words(in: $1)) }
    }

    /// Too common to tie a task to anything.
    private static let common: Set<String> = [
        "the", "and", "with", "from", "this", "that", "into", "about", "when", "your", "have", "will", "make",
        "main", "master", "develop", "feature", "branch", "task", "tasks", "issue", "issues", "todo", "page",
        "window", "untitled", "edited", "google", "chrome", "safari", "xcode", "code", "visual", "studio",
        "inbox", "today", "reminders", "work", "home", "project", "projects", "update", "review",
    ]

    /// "today", "overdue", or nothing.
    static func dueNote(_ item: TaskItem, now: Date, calendar: Calendar = .current) -> String? {
        guard let due = item.due else { return nil }
        if calendar.isDate(due, inSameDayAs: now) { return String(localized: "today", comment: "When a task offered as a goal is due") }
        return due < calendar.startOfDay(for: now) ? String(localized: "overdue", comment: "When a task offered as a goal is due") : nil
    }

    /// The first open task that isn't the one just done.
    static func next(after done: TaskItem, in items: [TaskItem], now: Date, context: [String] = [], calendar: Calendar = .current) -> TaskItem? {
        ordered(items.filter { !$0.isSame(as: done) }, now: now, context: context, calendar: calendar).first
    }
}

/// Why a source's tasks couldn't be read.
enum TaskSourceProblem: Error, Equatable {
    /// Not now: offline, or Things isn't open. What was read last stays.
    case unreachable
    /// The token was turned down.
    case rejected
    /// macOS doesn't let FocusGuard control the app (Things).
    case notAllowed
}

/// One place tasks come from, for goals and ticking them off.
protocol TaskStore: AnyObject {
    var source: TaskSource { get }
    /// Its open tasks to offer, in any order.
    func openTasks() async throws -> [TaskItem]
    /// Ticks a task off, or opens it again. True when it's saved.
    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool
    /// The same, saying why when the service won't have it.
    func change(_ task: TaskItem, completed: Bool) async -> TaskChange
}

extension TaskStore {
    func change(_ task: TaskItem, completed: Bool) async -> TaskChange {
        await setCompleted(task, completed) ? .saved : .failed
    }
}

/// How ticking a task off, or opening it again, went.
enum TaskChange: Equatable {
    case saved
    /// Not now: nothing to tell the user beyond the task still being as it was.
    case failed
    /// The service won't make this change; the line says why, and the task
    /// is left as it was.
    case refused(String)
}

/// A source signed in with a personal token.
protocol ConnectedTaskStore: TaskStore {
    var hasToken: Bool { get }
    func disconnect()
}

/// One that needs only the token: Todoist, Linear and GitHub.
protocol TokenTaskStore: ConnectedTaskStore {
    /// Checks the token with the service, and keeps it if it's taken.
    func connect(token: String) async -> TokenCheck
}

/// One that can also be signed in to, instead of pasting a token: Linear and
/// GitHub.
protocol SignInTaskStore: TokenTaskStore {
    /// Connected by signing in.
    var isSignedIn: Bool { get }
    /// The service ended the sign-in; the user connects again.
    var wasSignedOut: Bool { get }
}

enum TokenCheck: Equatable {
    case accepted, rejected, unreachable
    /// The address isn't one credentials may go to (Jira).
    case badSite
}

/// A session whose goal came from a task, and whether it was ticked off.
struct TaskLink: Codable, Equatable {
    let task: TaskItem
    /// When the session started, to keep only recent links.
    let linkedAt: Date
    var ticked = false

    /// What to do with the task after the verdict changed.
    enum Change: Equatable {
        case tick, untick, none
    }

    /// The user's own Done ticks it off; anything else takes back a tick
    /// FocusGuard made. The debrief's verdict is the model's guess, and a tick
    /// can close a real issue, so it never ticks anything.
    func change(for verdict: GoalVerdict?, byUser: Bool) -> Change {
        if verdict == .done {
            return !ticked && byUser ? .tick : .none
        }
        return ticked ? .untick : .none
    }
}

extension TaskLink {
    private enum CodingKeys: String, CodingKey {
        /// 0.3.34 saved the task as `reminder`.
        case task, reminder, linkedAt, ticked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decodeIfPresent(TaskItem.self, forKey: .task)
            ?? container.decode(TaskItem.self, forKey: .reminder)
        linkedAt = try container.decode(Date.self, forKey: .linkedAt)
        ticked = try container.decodeIfPresent(Bool.self, forKey: .ticked) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task, forKey: .task)
        try container.encode(linkedAt, forKey: .linkedAt)
        try container.encode(ticked, forKey: .ticked)
    }
}
