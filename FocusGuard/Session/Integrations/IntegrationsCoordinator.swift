import AppKit
import Foundation

/// The integrations (Settings › Integrations): sessions on the calendar,
/// the next meeting in the menu, open tasks from Reminders, Things, Todoist,
/// Linear, GitHub and Jira as goals and ticking them off (Pro), and the Git
/// branch as a goal.
///
/// EventKit is read and written off the main thread (`EventKitBridge`),
/// and so are the task sources (`TaskStore`); what the menu shows is kept
/// here.
@MainActor
@Observable
final class IntegrationsCoordinator {
    /// The next timed event in the chosen calendars; nil with the switch
    /// off or without access. The menu shows it from 30 minutes before.
    private(set) var nextMeeting: NextMeeting?
    /// Open tasks to offer as goals, from every source switched on, best
    /// first. Empty unless Pro.
    private(set) var taskGoals: [TaskItem] = []
    /// Sources that couldn't be read for a reason the user can fix: a token
    /// turned down, or Things not allowed.
    private(set) var taskProblems: [TaskSource: TaskSourceProblem] = [:]
    /// The branch being worked on, with the switch on.
    private(set) var gitGoal: GitGoal?
    /// Sessions whose goal came from a task, by session.
    private(set) var taskLinks: [UUID: TaskLink] = [:]
    /// What's next on the list after a session's task was ticked off.
    private(set) var nextTasks: [UUID: TaskItem] = [:]
    /// Why a session's task was left as it was, until the next try.
    private(set) var tickNotes: [UUID: String] = [:]

    /// Signing in to GitHub and Linear; nil keeps the pasted token alone,
    /// until the app is registered.
    @ObservationIgnored let githubSignIn: GitHubSignIn?
    @ObservationIgnored let linearSignIn: LinearSignIn?
    @ObservationIgnored let calendarWriter: SessionCalendarWriter
    @ObservationIgnored private let calendar: CalendarStore
    @ObservationIgnored private let reminders: ReminderStore
    @ObservationIgnored private let taskStores: [TaskSource: TaskStore]
    /// What each source gave last; one that can't be reached keeps its own.
    @ObservationIgnored private var tasksBySource: [TaskSource: [TaskItem]] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let entitlements: Entitlements
    /// The app in front and its window title, for the Git branch. AppState
    /// passes the tracker's.
    @ObservationIgnored var frontWindow: () -> (bundleID: String, title: String?)? = { nil }
    @ObservationIgnored private var meetingCheckedAt: Date = .distantPast
    @ObservationIgnored private var slotsCheckedAt: Date = .distantPast

    /// Whether the switch is on; tests turn it on before it ships.
    @ObservationIgnored var isShipped: Bool = FeatureFlags.taskGoals

    private enum Key {
        static let links = "integrations.reminders.sessionLinks"
        /// The task picked under the goal field, until a session starts.
        static let picked = "integrations.reminders.picked"
    }
    /// Links kept, newest last.
    static let linksKept = 30
    /// The next meeting is looked up this often.
    static let meetingInterval: TimeInterval = 60

    /// - Parameters:
    ///   - tasks: where tasks come from; Reminders (from `reminders`), Things,
    ///     Todoist, Linear, GitHub and Jira when nil.
    ///   - githubSignIn: its tokens are the ones `tasks` should use. The app's
    ///     own, from Info.plist, when `tasks` is nil.
    ///   - linearSignIn: the same.
    init(calendar: CalendarStore, reminders: ReminderStore, tasks: [TaskStore]? = nil,
         entitlements: Entitlements? = nil, defaults: UserDefaults = .standard,
         githubSignIn: GitHubSignIn? = nil, linearSignIn: LinearSignIn? = nil) {
        self.calendar = calendar
        self.reminders = reminders
        let github = tasks == nil ? GitHubSignIn.bundled() : githubSignIn
        let linear = tasks == nil ? LinearSignIn.bundled() : linearSignIn
        self.githubSignIn = github
        self.linearSignIn = linear
        let stores = tasks ?? [ReminderTasks(store: reminders, defaults: defaults), ThingsTasks(), TodoistTasks(),
                               LinearTasks(signIn: linear?.tokens), GitHubTasks(signIn: github?.tokens), JiraTasks(defaults: defaults)]
        self.taskStores = Dictionary(stores.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        self.defaults = defaults
        self.entitlements = entitlements ?? .shared
        self.calendarWriter = SessionCalendarWriter(store: calendar, defaults: defaults)
        if let data = defaults.data(forKey: Key.links),
           let saved = try? JSONDecoder().decode([String: TaskLink].self, from: data) {
            taskLinks = Dictionary(uniqueKeysWithValues: saved.compactMap { key, link in UUID(uuidString: key).map { ($0, link) } })
        }
        github?.onConnected = { [weak self] in self?.signedIn(.github) }
        linear?.onConnected = { [weak self] in self?.signedIn(.linear) }
    }

    convenience init() {
        let bridge = EventKitBridge()
        self.init(calendar: bridge, reminders: bridge)
    }

    /// A source's tasks as goals and ticking them off: Pro, and switched on.
    func isOn(_ source: TaskSource) -> Bool {
        isShipped && entitlements.isUnlocked(.taskGoals) && IntegrationSettings.isOn(source.settingKey, defaults)
    }

    // MARK: - Refreshing

    /// When the menu opens: the next meeting, the tasks and the branch.
    func refreshForMenu(now: Date = .now) async {
        async let meeting: Void = refreshNextMeeting(now: now)
        async let goals: Void = refreshGoalSources(now: now)
        _ = await (meeting, goals)
    }

    func refreshNextMeeting(now: Date = .now) async {
        meetingCheckedAt = now
        guard IntegrationSettings.isOn(IntegrationSettings.nextMeeting, defaults) else {
            if nextMeeting != nil { nextMeeting = nil }
            return
        }
        let entries = await calendar.events(from: now, to: now.addingTimeInterval(3 * 3600),
                                            calendarIDs: IntegrationSettings.ids(IntegrationSettings.readCalendars, defaults),
                                            ownIDs: Set(calendarWriter.ownIDs))
        let next = entries.flatMap { NextMeeting.pick(from: $0, now: now, ownIDs: Set(calendarWriter.ownIDs)) }
        if next != nextMeeting { nextMeeting = next }
    }

    /// Tasks (Pro) and the Git branch, for the goal field.
    func refreshGoalSources(now: Date = .now) async {
        async let tasks: Void = refreshTasks(now: now)
        await refreshGitGoal()
        _ = await tasks
    }

    private func refreshGitGoal() async {
        guard IntegrationSettings.isOn(IntegrationSettings.gitBranch, defaults) else {
            if gitGoal != nil { gitGoal = nil }
            return
        }
        let folder = IntegrationSettings.gitFolder(defaults)
        let front = frontWindow()
        let title = GitGoalFinder.isEditor(front?.bundleID) ? front?.title : nil
        let goal = await Task.detached(priority: .utility) {
            GitGoalFinder.goal(in: folder, editorTitle: title)
        }.value
        if goal != gitGoal { gitGoal = goal }
    }

    /// The tracker's tick: the next meeting every minute, and planned slots
    /// that ran out come off the calendar.
    func tick(now: Date = .now) {
        if now.timeIntervalSince(meetingCheckedAt) >= Self.meetingInterval {
            meetingCheckedAt = now
            Task { await refreshNextMeeting(now: now) }
        }
        if now.timeIntervalSince(slotsCheckedAt) >= Self.meetingInterval {
            slotsCheckedAt = now
            Task { await calendarWriter.tick(now: now) }
        }
    }

    // MARK: - Sessions

    /// - Parameter startedByEvent: the user's own calendar event started it,
    ///   so it's on the calendar already.
    func sessionStarted(_ session: Session, startedByEvent: Bool, now: Date = .now) async {
        linkPickedTask(to: session)
        guard !startedByEvent else { return }
        await calendarWriter.sessionStarted(id: session.id, name: Self.name(of: session), start: session.startedAt,
                                            plannedMinutes: session.plannedDurationMinutes,
                                            openEndedMinutes: FocusActions.usualMinutes(defaults), now: now)
    }

    /// "5 more min": the event follows the new end.
    func sessionExtended(_ session: Session) async {
        guard let planned = session.plannedDurationMinutes else { return }
        let end = session.startedAt.addingTimeInterval(session.pausedSeconds + TimeInterval(planned * 60))
        await calendarWriter.sessionChanged(id: session.id, name: Self.name(of: session), start: session.startedAt, end: end)
    }

    func sessionEnded(_ session: Session) async {
        guard let end = session.endedAt else { return }
        await calendarWriter.sessionEnded(id: session.id, name: Self.name(of: session), start: session.startedAt, end: end)
    }

    /// At launch: events of sessions that ended while FocusGuard was closed.
    func reconcile(lookup: (UUID) -> Session?) async {
        await calendarWriter.reconcile { id in
            lookup(id).map { (Self.name(of: $0), $0.startedAt, $0.endedAt) }
        }
    }

    /// "Focus · <goal or session name>".
    static func name(of session: Session) -> String {
        session.goal ?? session.displayName
    }

    // MARK: - Morning plan

    func planned(_ slots: [Date], minutes: Int, now: Date = .now) async {
        await calendarWriter.planned(slots, minutes: minutes, now: now)
    }

    func skipPlanned(_ slot: Date) async {
        await calendarWriter.skipPlanned(slot)
    }

    // MARK: - Tasks as goals

    /// Reads every source switched on, all at once. A source that can't be
    /// reached keeps what it gave last; one switched off gives nothing.
    func refreshTasks(now: Date = .now) async {
        let stores = TaskSource.allCases.filter { isOn($0) }.compactMap { taskStores[$0] }
        for source in TaskSource.allCases where !isOn(source) {
            tasksBySource[source] = nil
            setProblem(nil, for: source)
        }
        let results = await withTaskGroup(of: (TaskSource, Result<[TaskItem], TaskSourceProblem>).self) { group in
            for store in stores {
                group.addTask { await Self.read(store) }
            }
            var all: [(TaskSource, Result<[TaskItem], TaskSourceProblem>)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (source, result) in results {
            switch result {
            case .success(let items):
                tasksBySource[source] = items
                setProblem(nil, for: source)
            case .failure(.unreachable):
                break
            case .failure(let problem):
                tasksBySource[source] = nil
                setProblem(problem, for: source)
            }
        }
        publishTasks(now: now)
    }

    nonisolated private static func read(_ store: TaskStore) async -> (TaskSource, Result<[TaskItem], TaskSourceProblem>) {
        do {
            return (store.source, .success(try await store.openTasks()))
        } catch {
            return (store.source, .failure(error as? TaskSourceProblem ?? .unreachable))
        }
    }

    private func publishTasks(now: Date) {
        let ordered = TaskGoals.ordered(tasksBySource.values.flatMap { $0 }, now: now)
        if ordered != taskGoals { taskGoals = ordered }
    }

    private func setProblem(_ problem: TaskSourceProblem?, for source: TaskSource) {
        if taskProblems[source] != problem { taskProblems[source] = problem }
    }

    /// A suggestion was picked under the goal field: a task is kept until
    /// the session starts, to tick it off after.
    func goalPicked(_ suggestion: GoalSuggestion) {
        guard case .task(let source, let id, _) = suggestion.source,
              let item = taskGoals.first(where: { $0.source == source && $0.id == id }),
              let data = try? JSONEncoder().encode(item) else {
            defaults.removeObject(forKey: Key.picked)
            return
        }
        defaults.set(data, forKey: Key.picked)
    }

    /// The task picked for the next session, if any.
    var pickedTask: TaskItem? {
        defaults.data(forKey: Key.picked).flatMap { try? JSONDecoder().decode(TaskItem.self, from: $0) }
    }

    /// "Start 25 min" on the next task: it's picked for the session about
    /// to start.
    func pick(_ item: TaskItem) {
        if let data = try? JSONEncoder().encode(item) { defaults.set(data, forKey: Key.picked) }
    }

    /// The picked task goes with the session, while the goal is still its
    /// title (an edited goal is the user's own).
    private func linkPickedTask(to session: Session) {
        guard let item = pickedTask else { return }
        defaults.removeObject(forKey: Key.picked)
        guard isOn(item.source), let goal = session.goal,
              goal.caseInsensitiveCompare(String(item.title.prefix(SessionGoal.maxLength))) == .orderedSame else { return }
        taskLinks[session.id] = TaskLink(task: item, linkedAt: session.startedAt)
        saveLinks()
    }

    // MARK: - Ticking off

    /// The goal's verdict changed, from the debrief or the user: Done ticks
    /// the task off, anything else takes back a tick FocusGuard made.
    func verdictChanged(_ session: Session, byUser: Bool, now: Date = .now) async {
        guard let link = taskLinks[session.id], entitlements.isUnlocked(.taskGoals) else { return }
        switch link.change(for: session.goalVerdict, byUser: byUser) {
        case .tick:   await setTicked(true, session: session.id, now: now)
        case .untick: await setTicked(false, session: session.id, now: now)
        case .none:   break
        }
    }

    /// "Undo": the task is open again, and the debrief won't tick it.
    func undoTick(session id: UUID) async {
        guard taskLinks[id]?.ticked == true else { return }
        await setTicked(false, session: id)
        guard taskLinks[id]?.ticked == false else { return }
        taskLinks[id]?.undone = true
        saveLinks()
    }

    /// "Tick off", after an undo.
    func tickOff(session id: UUID) async {
        await setTicked(true, session: id)
    }

    /// Ticks the session's task off in its own app, or opens it again; the
    /// goals offered follow, and after a tick so does what's next.
    private func setTicked(_ ticked: Bool, session id: UUID, now: Date = .now) async {
        guard let link = taskLinks[id], link.ticked != ticked, let store = taskStores[link.task.source] else { return }
        let change = await store.change(link.task, completed: ticked)
        if case .refused(let why) = change { tickNotes[id] = why } else { tickNotes[id] = nil }
        guard change == .saved else { return }
        taskLinks[id]?.ticked = ticked
        if ticked { taskLinks[id]?.undone = false }
        saveLinks()
        let source = link.task.source
        if ticked { tasksBySource[source]?.removeAll { $0.isSame(as: link.task) } }
        if isOn(source), let open = try? await store.openTasks() { tasksBySource[source] = open }
        publishTasks(now: now)
        nextTasks[id] = ticked ? TaskGoals.next(after: link.task, in: taskGoals, now: now) : nil
    }

    private func saveLinks() {
        if taskLinks.count > Self.linksKept {
            let oldest = taskLinks.sorted { $0.value.linkedAt < $1.value.linkedAt }.prefix(taskLinks.count - Self.linksKept)
            for (key, _) in oldest { taskLinks[key] = nil }
        }
        let saved = Dictionary(uniqueKeysWithValues: taskLinks.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Key.links) }
    }

    // MARK: - Settings

    func calendarChoices() async -> [CalendarChoice] { await calendar.calendars() }
    func defaultCalendarID() async -> String? { await calendar.defaultCalendarID() }
    func reminderLists() async -> [CalendarChoice] { await reminders.lists() }

    /// Asks macOS for Reminders, in front so the prompt shows.
    func requestRemindersAccess() async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return await reminders.requestAccess()
    }

    /// Reads Things now, in front, so macOS asks once whether FocusGuard
    /// may control it.
    func requestThingsAccess() async {
        NSApp.activate(ignoringOtherApps: true)
        await refreshTasks()
    }

    /// Whether a source that signs in has its token saved.
    func isConnected(_ source: TaskSource) -> Bool {
        (taskStores[source] as? ConnectedTaskStore)?.hasToken ?? false
    }

    /// Connected by signing in, rather than with a pasted token.
    func isSignedIn(_ source: TaskSource) -> Bool {
        (taskStores[source] as? SignInTaskStore)?.isSignedIn ?? false
    }

    /// The service ended the sign-in; Settings offers to connect again.
    func wasSignedOut(_ source: TaskSource) -> Bool {
        (taskStores[source] as? SignInTaskStore)?.wasSignedOut ?? false
    }

    /// Settings offers signing in to this source, not just a pasted token.
    func offersSignIn(_ source: TaskSource) -> Bool {
        switch source {
        case .github: return githubSignIn != nil
        case .linear: return linearSignIn != nil
        default:      return false
        }
    }

    /// A sign-in finished: its tasks are read straight after.
    private func signedIn(_ source: TaskSource) {
        setProblem(nil, for: source)
        Task { await refreshTasks() }
    }

    /// Whether GitHub's sign-in reaches any repository, for Settings.
    func githubRepositoryAccess() async -> RepositoryAccess {
        await (taskStores[.github] as? GitHubTasks)?.repositoryAccess() ?? .unknown
    }

    /// Checks a pasted token with the service and keeps it if it's taken;
    /// its tasks are read straight after.
    func connect(_ source: TaskSource, token: String) async -> TokenCheck {
        guard let store = taskStores[source] as? TokenTaskStore else { return .rejected }
        let check = await store.connect(token: token)
        if check == .accepted {
            setProblem(nil, for: source)
            await refreshTasks()
        }
        return check
    }

    /// The same for Jira, which needs its site and email too.
    func connectJira(site: String, email: String, token: String) async -> TokenCheck {
        guard let store = taskStores[.jira] as? JiraTasks else { return .rejected }
        let check = await store.connect(site: site, email: email, token: token)
        if check == .accepted {
            setProblem(nil, for: .jira)
            await refreshTasks()
        }
        return check
    }

    /// The Jira site and email saved, for Settings.
    var jiraAccount: (site: String, email: String)? {
        (taskStores[.jira] as? JiraTasks)?.account
    }

    /// Forgets the token; the source's tasks go too.
    func disconnect(_ source: TaskSource) {
        (taskStores[source] as? ConnectedTaskStore)?.disconnect()
        tasksBySource[source] = nil
        setProblem(nil, for: source)
        publishTasks(now: .now)
    }
}
