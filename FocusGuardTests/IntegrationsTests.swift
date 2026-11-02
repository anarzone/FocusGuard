import SwiftData
import XCTest
@testable import FocusGuard

// MARK: - Fakes

/// Stands in for EventKit's calendar: keeps the events FocusGuard writes
/// and the user's own, and what was done to which. Its own events carry no
/// link here, so only the kept identifiers tell them apart.
private final class FakeCalendarStore: CalendarStore {
    struct Written: Equatable {
        var draft: SessionEventDraft
        var calendarID: String?
    }

    var written: [String: Written] = [:]
    var userEvents: [CalendarEntry] = []
    /// Every identifier passed to update or remove.
    var touched: [String] = []
    var removed: [String] = []
    var creates = 0
    private var counter = 0

    func calendars() async -> [CalendarChoice] { [] }
    func defaultCalendarID() async -> String? { "default" }

    func events(from start: Date, to end: Date, calendarIDs: [String], ownIDs: Set<String>) async -> [CalendarEntry]? {
        let own = written.map { id, event in
            CalendarEntry(id: id, title: event.draft.title, start: event.draft.start, end: event.draft.end,
                          isAllDay: false, isOwn: false, isDeclined: false)
        }
        return (userEvents + own).filter { $0.start < end && $0.end > start }
    }

    func create(_ draft: SessionEventDraft, calendarID: String?) async -> String? {
        counter += 1
        creates += 1
        let id = "event-\(counter)"
        written[id] = Written(draft: draft, calendarID: calendarID)
        return id
    }

    func update(_ ref: OwnEventRef, to draft: SessionEventDraft) async -> String? {
        touched.append(ref.id)
        guard written[ref.id] != nil else { return nil }
        written[ref.id]?.draft = draft
        return ref.id
    }

    func remove(_ ref: OwnEventRef) async -> Bool {
        touched.append(ref.id)
        removed.append(ref.id)
        written[ref.id] = nil
        return true
    }
}

/// Stands in for Reminders.
private final class FakeReminderStore: ReminderStore {
    var items: [TaskItem] = []
    var completed: Set<String> = []
    var completions: [(String, Bool)] = []

    func lists() async -> [CalendarChoice] { [] }
    func incomplete(listIDs: [String]) async -> [TaskItem]? { items.filter { !completed.contains($0.id) } }
    func setCompleted(_ id: String, _ done: Bool) async -> Bool {
        completions.append((id, done))
        if done { completed.insert(id) } else { completed.remove(id) }
        return true
    }
    func requestAccess() async -> Bool { true }
}

// MARK: - Sessions on the calendar

@MainActor
final class SessionCalendarWriterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: FakeCalendarStore!
    private let nine = Date(timeIntervalSinceReferenceDate: 815_000_000)

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SessionCalendarWriterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(true, forKey: IntegrationSettings.sessionsOnCalendar)
        store = FakeCalendarStore()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        try await super.tearDown()
    }

    private func make() -> SessionCalendarWriter { SessionCalendarWriter(store: store, defaults: defaults) }
    private func minutes(_ m: Double) -> Date { nine.addingTimeInterval(m * 60) }

    func testTitlesNameTheGoal() {
        XCTAssertEqual(SessionCalendarWriter.title("Write the Q4 report"), "Focus · Write the Q4 report")
        XCTAssertEqual(SessionCalendarWriter.title("  "), "Focus")
    }

    func testASessionIsBusyUntilItsPlannedEndThenMovesToItsRealEnd() async throws {
        let writer = make()
        let id = UUID()
        await writer.sessionStarted(id: id, name: "Write the Q4 report", start: nine, plannedMinutes: 50,
                                    openEndedMinutes: 25, now: nine)
        XCTAssertEqual(store.written.count, 1)
        let eventID = try XCTUnwrap(store.written.keys.first)
        XCTAssertEqual(store.written[eventID]?.draft,
                       SessionEventDraft(title: "Focus · Write the Q4 report", start: nine, end: minutes(50),
                                         key: SessionCalendarWriter.key(session: id)))

        await writer.sessionEnded(id: id, name: "Write the Q4 report", start: nine, end: minutes(32))
        XCTAssertEqual(store.written[eventID]?.draft.end, minutes(32))
        XCTAssertNil(writer.entry(forSession: id))
        XCTAssertTrue(writer.ownIDs.contains(eventID))
    }

    func testAnOpenEndedSessionHoldsTheUsualLengthUntilItEnds() async {
        let writer = make()
        let id = UUID()
        await writer.sessionStarted(id: id, name: "Steady Deep Dive", start: nine, plannedMinutes: nil,
                                    openEndedMinutes: 25, now: nine)
        XCTAssertEqual(store.written.values.first?.draft.end, minutes(25))
        await writer.sessionEnded(id: id, name: "Steady Deep Dive", start: nine, end: minutes(95))
        XCTAssertEqual(store.written.values.first?.draft.end, minutes(95))
        XCTAssertEqual(store.written.values.first?.draft.title, "Focus · Steady Deep Dive")
    }

    func testFiveMoreMinutesMovesTheEnd() async {
        let writer = make()
        let id = UUID()
        await writer.sessionStarted(id: id, name: "Plan", start: nine, plannedMinutes: 25, openEndedMinutes: 50, now: nine)
        await writer.sessionChanged(id: id, name: "Plan", start: nine, end: minutes(30))
        XCTAssertEqual(store.written.values.first?.draft.end, minutes(30))
    }

    func testASessionUnderAMinuteComesOffAgain() async {
        let writer = make()
        let id = UUID()
        await writer.sessionStarted(id: id, name: "Oops", start: nine, plannedMinutes: 50, openEndedMinutes: 50, now: nine)
        await writer.sessionEnded(id: id, name: "Oops", start: nine, end: nine.addingTimeInterval(20))
        XCTAssertTrue(store.written.isEmpty)
        XCTAssertEqual(store.removed.count, 1)
    }

    func testSwitchedOffNothingIsWritten() async {
        defaults.set(false, forKey: IntegrationSettings.sessionsOnCalendar)
        let writer = make()
        await writer.sessionStarted(id: UUID(), name: "Plan", start: nine, plannedMinutes: 50, openEndedMinutes: 50, now: nine)
        await writer.planned([minutes(60)], minutes: 50, now: nine)
        XCTAssertEqual(store.creates, 0)
    }

    func testSessionsGoToTheChosenCalendar() async {
        defaults.set("work", forKey: IntegrationSettings.sessionsCalendar)
        await make().sessionStarted(id: UUID(), name: "Plan", start: nine, plannedMinutes: 50, openEndedMinutes: 50, now: nine)
        XCTAssertEqual(store.written.values.first?.calendarID, "work")
    }

    func testAPlannedSlotIsHeldThenTakenOverByTheSessionStartedInIt() async {
        let writer = make()
        let slot = minutes(60)
        await writer.planned([slot, nine.addingTimeInterval(-60)], minutes: 50, now: nine)
        XCTAssertEqual(store.written.count, 1, "only future slots")
        XCTAssertEqual(store.written.values.first?.draft.title, "Focus · planned")
        XCTAssertEqual(store.written.values.first?.draft.end, minutes(110))

        // A session started ten minutes before the slot takes its event over.
        let id = UUID()
        await writer.sessionStarted(id: id, name: "Write the Q4 report", start: minutes(50), plannedMinutes: 50,
                                    openEndedMinutes: 50, now: minutes(50))
        XCTAssertEqual(store.creates, 1, "no second event")
        XCTAssertEqual(store.written.values.first?.draft.title, "Focus · Write the Q4 report")
        XCTAssertEqual(store.written.values.first?.draft.start, minutes(50))
        XCTAssertEqual(writer.entry(forSession: id)?.key, SessionCalendarWriter.key(session: id))

        // It isn't removed when the slot's time runs out.
        await writer.tick(now: minutes(200))
        XCTAssertTrue(store.removed.isEmpty)
    }

    func testAPlannedSlotNobodyStartsComesOffAtItsEnd() async {
        let writer = make()
        await writer.planned([minutes(60)], minutes: 50, now: nine)
        await writer.tick(now: minutes(100))
        XCTAssertEqual(store.written.count, 1, "still on before its end")
        await writer.tick(now: minutes(110))
        XCTAssertTrue(store.written.isEmpty)
    }

    func testSkippingAPlannedSlotTakesItOff() async {
        let writer = make()
        await writer.planned([minutes(60), minutes(180)], minutes: 50, now: nine)
        await writer.skipPlanned(minutes(60))
        XCTAssertEqual(store.written.values.map(\.draft.start), [minutes(180)])
    }

    func testOnlyItsOwnEventsAreEverTouched() async {
        let writer = make()
        store.userEvents = [CalendarEntry(id: "users-own", title: "Focus: menu redesign", start: minutes(30),
                                          end: minutes(120), isAllDay: false, isOwn: false, isDeclined: false)]
        let id = UUID()
        await writer.planned([minutes(60)], minutes: 50, now: nine)
        await writer.sessionStarted(id: id, name: "Plan", start: minutes(55), plannedMinutes: 50, openEndedMinutes: 50,
                                    now: minutes(55))
        await writer.sessionEnded(id: id, name: "Plan", start: minutes(55), end: minutes(80))
        await writer.tick(now: minutes(300))
        await writer.skipPlanned(minutes(30))
        XCTAssertFalse(store.touched.contains("users-own"))
        XCTAssertTrue(Set(store.touched).isSubset(of: Set(writer.ownIDs)))
    }

    func testTheLedgerOutlivesARelaunchAndCatchesUpOnSessionsThatEnded() async {
        let ended = UUID(), deleted = UUID(), running = UUID()
        let first = make()
        for id in [ended, deleted, running] {
            await first.sessionStarted(id: id, name: "Plan", start: nine, plannedMinutes: 50, openEndedMinutes: 50, now: nine)
        }

        let again = make()
        XCTAssertEqual(again.entries.count, 3)
        await again.reconcile { id in
            switch id {
            case ended:   return ("Plan", self.nine, self.minutes(20))
            case running: return ("Plan", self.nine, nil)
            default:      return nil
            }
        }
        XCTAssertEqual(again.entries.compactMap(\.sessionID), [running])
        XCTAssertTrue(store.written.values.contains { $0.draft.end == minutes(20) })
    }
}

// MARK: - Next meeting

final class NextMeetingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func entry(_ id: String, _ title: String, in minutes: Double, allDay: Bool = false, own: Bool = false,
                       declined: Bool = false) -> CalendarEntry {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEntry(id: id, title: title, start: start, end: start.addingTimeInterval(1800),
                             isAllDay: allDay, isOwn: own, isDeclined: declined)
    }

    func testTheNextMeetingSkipsFocusGuardsOwnAllDayDeclinedAndStartedEvents() {
        let entries = [
            entry("now", "Already on", in: -5),
            entry("own", "Focus · planned", in: 5, own: true),
            entry("ledger", "Focus · Plan", in: 6),
            entry("allDay", "Holiday", in: 7, allDay: true),
            entry("declined", "Sync", in: 8, declined: true),
            entry("later", "Design review", in: 90),
            entry("standup", "Standup", in: 25),
        ]
        XCTAssertEqual(NextMeeting.pick(from: entries, now: now, ownIDs: ["ledger"])?.title, "Standup")
    }

    func testItShowsFromHalfAnHourBefore() {
        let meeting = NextMeeting(id: "a", title: "Standup", start: now.addingTimeInterval(25 * 60))
        XCTAssertTrue(meeting.isShown(at: now))
        XCTAssertEqual(meeting.countdown(at: now), "in 25 min")
        XCTAssertFalse(meeting.isShown(at: now.addingTimeInterval(-6 * 60)))   // 31 minutes before
        XCTAssertFalse(meeting.isShown(at: now.addingTimeInterval(25 * 60)))   // it's started
        XCTAssertEqual(meeting.countdown(at: now.addingTimeInterval(25 * 60 - 20)), "in 1 min")
        XCTAssertEqual(NextMeeting(id: "b", title: "Quarterly planning with everyone", start: now).shortTitle, "the meeting")
    }

    func testTheLengthFitsBeforeTheMeeting() {
        let standup = now.addingTimeInterval(25 * 60)
        XCTAssertEqual(MeetingFit.minutes(50, now: now, meeting: standup), 25)
        XCTAssertEqual(MeetingFit.minutes(50, now: now, meeting: now.addingTimeInterval(29 * 60 + 50)), 25)
        XCTAssertNil(MeetingFit.minutes(25, now: now, meeting: standup), "already fits")
        XCTAssertNil(MeetingFit.minutes(50, now: now, meeting: now.addingTimeInterval(8 * 60)), "too little left")
        XCTAssertTrue(MeetingFit.endsBefore(25, now: now, meeting: standup))
        XCTAssertFalse(MeetingFit.endsBefore(30, now: now, meeting: standup))
    }
}

// MARK: - Reminders and Git as goals

final class GoalSourcesTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// 26 Oct 2026 at `hour`, a Monday.
    private func at(_ hour: Int, day: Int = 26) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func item(_ title: String, due: Date? = nil, created: Date? = nil, list: String = "Work") -> TaskItem {
        TaskItem(id: title, title: title, list: list, due: due, created: created)
    }

    func testRemindersDueTodayComeFirst() {
        let items = [
            item("Someday", created: at(9, day: 1)),
            item("Someday, added later", created: at(9, day: 2)),
            item("Next week", due: at(9, day: 30)),
            item("Late", due: at(9, day: 20)),
            item("Write the Q4 report", due: at(17)),
            item("Reply to Lena", due: at(8)),
        ]
        XCTAssertEqual(TaskGoals.ordered(items, now: at(10), calendar: calendar).map(\.title),
                       ["Reply to Lena", "Write the Q4 report", "Late", "Next week", "Someday", "Someday, added later"])
        XCTAssertEqual(TaskGoals.dueNote(items[4], now: at(10), calendar: calendar), "today")
        XCTAssertEqual(TaskGoals.dueNote(items[3], now: at(10), calendar: calendar), "overdue")
        XCTAssertNil(TaskGoals.dueNote(items[2], now: at(10), calendar: calendar))
        XCTAssertEqual(TaskGoals.next(after: items[5], in: items, now: at(10), calendar: calendar)?.title,
                       "Write the Q4 report")
    }

    func testSuggestionsComeInTheFieldsOrderUnderTheirHeadings() {
        let reminders = [item("Write the Q4 report", due: at(17)), item("Reply to Lena"), item("Third one")]
        let review = at(10).addingTimeInterval(600)
        let suggestions = GoalSuggestion.make(lastGoal: "Finish the Today page", lastVerdict: .partly,
                                              calendarTitle: "Prepare the design review", calendarStart: review,
                                              tasks: reminders, git: GitGoal(repo: "focusguard", branch: "fix/header-clicks"),
                                              now: at(10), calendar: calendar)
        XCTAssertEqual(suggestions.map(\.text), ["Write the Q4 report", "Reply to Lena", "Prepare the design review",
                                                 "fix/header-clicks", "Finish the Today page"])
        XCTAssertEqual(suggestions.map(\.group), ["Reminders · Work", "Reminders · Work", "Calendar", "Git · focusguard", "Last time"])
        XCTAssertEqual(suggestions.map(\.detail), ["today", nil, HabitFormat.time(review, calendar: calendar), nil, "partly done"])
        XCTAssertEqual(suggestions.first?.source, .task(.reminders, id: "Write the Q4 report", list: "Work"))
    }

    func testTheSameTextIsOfferedOnce() {
        let suggestions = GoalSuggestion.make(lastGoal: "Write the Q4 report", lastVerdict: nil, calendarTitle: nil,
                                              tasks: [item("Write the Q4 report")], now: at(10), calendar: calendar)
        XCTAssertEqual(suggestions.map(\.source), [.task(.reminders, id: "Write the Q4 report", list: "Work")])
    }

    func testOnlyTheUsersOwnDoneTicksTheTaskOff() {
        let link = TaskLink(task: item("Write the Q4 report"), linkedAt: at(10))
        XCTAssertEqual(link.change(for: .done, byUser: true), .tick)
        XCTAssertEqual(link.change(for: .done, byUser: false), .none, "the debrief's verdict is only the model's guess")
        XCTAssertEqual(link.change(for: .partly, byUser: true), .none)

        var ticked = link
        ticked.ticked = true
        XCTAssertEqual(ticked.change(for: .notYet, byUser: true), .untick)
        XCTAssertEqual(ticked.change(for: .done, byUser: true), .none)
    }
}

// MARK: - Git branch

final class GitGoalFinderTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("GitGoalFinderTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    /// A repo at `path` under the root on `head`, last changed `age` seconds ago.
    @discardableResult
    private func repo(_ path: String, head: String, age: TimeInterval) throws -> URL {
        let repo = root.appendingPathComponent(path)
        let git = repo.appendingPathComponent(".git")
        try fileManager.createDirectory(at: git.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let headFile = git.appendingPathComponent("HEAD")
        try "\(head)\n".write(to: headFile, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: headFile.path)
        return repo
    }

    func testFindsReposTwoDeepButNotInsideOtherRepos() throws {
        try repo("alpha", head: "ref: refs/heads/main", age: 100)
        try repo("Own/FocusGuard", head: "ref: refs/heads/feat/integrations-local", age: 50)
        try repo("Own/FocusGuard/vendor/inner", head: "ref: refs/heads/x", age: 10)
        try fileManager.createDirectory(at: root.appendingPathComponent("a/b/too-deep/.git"), withIntermediateDirectories: true)
        let names = GitGoalFinder.repos(in: root).map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["FocusGuard", "alpha"])
    }

    func testReadsTheBranchFromHEAD() throws {
        let feature = try repo("app", head: "ref: refs/heads/fix/header-clicks", age: 0)
        let detached = try repo("detached", head: "3810167e0c1d5d8f1fa1c2b3a4d5e6f708192a3b", age: 0)
        XCTAssertEqual(GitGoalFinder.branch(of: feature), "fix/header-clicks")
        XCTAssertNil(GitGoalFinder.branch(of: detached))
    }

    func testFollowsAWorktreesGitFile() throws {
        let gitdir = root.appendingPathComponent("main-repo/.git/worktrees/wt")
        try fileManager.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try "ref: refs/heads/feat/worktree\n".write(to: gitdir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("wt")
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitdir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitGoalFinder.branch(of: worktree), "feat/worktree")
    }

    func testTheEditorsRepoWinsElseTheOneChangedLast() throws {
        try repo("focusguard", head: "ref: refs/heads/fix/header-clicks", age: 3600)
        try repo("focusguard-site", head: "ref: refs/heads/copy-tweaks", age: 7200)
        try repo("lexis", head: "ref: refs/heads/cafe-menu", age: 60)

        XCTAssertEqual(GitGoalFinder.goal(in: root, editorTitle: "SessionGoal.swift — focusguard"),
                       GitGoal(repo: "focusguard", branch: "fix/header-clicks"))
        XCTAssertEqual(GitGoalFinder.goal(in: root, editorTitle: "index.html — focusguard-site")?.repo, "focusguard-site")
        XCTAssertEqual(GitGoalFinder.goal(in: root, editorTitle: "FocusGuard.xcodeproj")?.repo, "focusguard")
        XCTAssertEqual(GitGoalFinder.goal(in: root, editorTitle: "Untitled — notes")?.repo, "lexis")
        XCTAssertEqual(GitGoalFinder.goal(in: root, editorTitle: nil)?.branch, "cafe-menu")
    }

    func testAMainBranchIsNoGoal() throws {
        try repo("app", head: "ref: refs/heads/main", age: 0)
        XCTAssertNil(GitGoalFinder.goal(in: root, editorTitle: nil))
    }

    func testKnowsTheEditors() {
        XCTAssertTrue(GitGoalFinder.isEditor("com.apple.dt.Xcode"))
        XCTAssertTrue(GitGoalFinder.isEditor("com.jetbrains.intellij"))
        XCTAssertTrue(GitGoalFinder.isEditor("com.todesktop.230313mzl4w4u92"))
        XCTAssertFalse(GitGoalFinder.isEditor("com.apple.Safari"))
        XCTAssertFalse(GitGoalFinder.isEditor(nil))
    }
}

// MARK: - The coordinator

@MainActor
final class IntegrationsCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var calendarStore: FakeCalendarStore!
    private var reminderStore: FakeReminderStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "IntegrationsCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        calendarStore = FakeCalendarStore()
        reminderStore = FakeReminderStore()
        reminderStore.items = [
            TaskItem(id: "q4", title: "Write the Q4 report", list: "Work", due: .now, created: nil),
            TaskItem(id: "lena", title: "Reply to Lena about the contract", list: "Work", due: nil, created: nil),
        ]
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    private func make(pro: Bool = true, remindersOn: Bool = true) -> IntegrationsCoordinator {
        let entitlements = Entitlements(defaults: defaults)
        if pro { entitlements.startTrialIfNeeded(for: .taskGoals) }
        defaults.set(remindersOn, forKey: IntegrationSettings.reminders)
        defaults.set(false, forKey: IntegrationSettings.gitBranch)
        let coordinator = IntegrationsCoordinator(calendar: calendarStore, reminders: reminderStore,
                                                  tasks: [ReminderTasks(store: reminderStore, defaults: defaults)],
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

    func testRemindersAreOfferedOnlyOnProWithTheSwitchOn() async {
        let free = make(pro: false)
        await free.refreshGoalSources()
        XCTAssertTrue(free.taskGoals.isEmpty)

        let off = make(remindersOn: false)
        await off.refreshGoalSources()
        XCTAssertTrue(off.taskGoals.isEmpty)

        let on = make()
        await on.refreshGoalSources()
        XCTAssertEqual(on.taskGoals.map(\.id), ["q4", "lena"])
    }

    func testAPickedReminderIsTickedOffWhenTheGoalIsDoneWithUndo() async {
        let coordinator = make()
        await coordinator.refreshGoalSources()
        let pick = GoalSuggestion(text: "Write the Q4 report", source: .task(.reminders, id: "q4", list: "Work"))
        coordinator.goalPicked(pick)

        let session = session(goal: "Write the Q4 report")
        await coordinator.sessionStarted(session, startedByEvent: false)
        XCTAssertEqual(coordinator.taskLinks[session.id]?.task.id, "q4")
        XCTAssertNil(coordinator.pickedTask)

        session.goalVerdict = .done
        // The debrief saying Done leaves the reminder open.
        await coordinator.verdictChanged(session, byUser: false)
        XCTAssertTrue(reminderStore.completed.isEmpty)
        XCTAssertEqual(coordinator.taskLinks[session.id]?.ticked, false)

        await coordinator.verdictChanged(session, byUser: true)
        XCTAssertEqual(reminderStore.completed, ["q4"])
        XCTAssertEqual(coordinator.taskLinks[session.id]?.ticked, true)
        XCTAssertEqual(coordinator.nextTasks[session.id]?.id, "lena")

        await coordinator.undoTick(session: session.id)
        XCTAssertTrue(reminderStore.completed.isEmpty)
        XCTAssertNil(coordinator.nextTasks[session.id])

        // The debrief saying Done again doesn't either.
        await coordinator.verdictChanged(session, byUser: false)
        XCTAssertTrue(reminderStore.completed.isEmpty)
        // The user's own Done does.
        await coordinator.verdictChanged(session, byUser: true)
        XCTAssertEqual(reminderStore.completed, ["q4"])
    }

    func testAnEditedGoalIsntLinkedToTheReminder() async {
        let coordinator = make()
        await coordinator.refreshGoalSources()
        coordinator.goalPicked(GoalSuggestion(text: "Write the Q4 report", source: .task(.reminders, id: "q4", list: "Work")))
        let session = session(goal: "Write the Q4 report intro only")
        await coordinator.sessionStarted(session, startedByEvent: false)
        XCTAssertNil(coordinator.taskLinks[session.id])
    }

    func testPickingSomethingElseForgetsThePickedReminder() async {
        let coordinator = make()
        await coordinator.refreshGoalSources()
        coordinator.goalPicked(GoalSuggestion(text: "Write the Q4 report", source: .task(.reminders, id: "q4", list: "Work")))
        coordinator.goalPicked(GoalSuggestion(text: "Standup notes", source: .calendar))
        XCTAssertNil(coordinator.pickedTask)
    }

    func testASessionStartedByTheUsersOwnEventIsntWrittenAgain() async {
        defaults.set(true, forKey: IntegrationSettings.sessionsOnCalendar)
        let coordinator = make()
        await coordinator.sessionStarted(session(goal: nil), startedByEvent: true)
        XCTAssertEqual(calendarStore.creates, 0)
        let mine = session(goal: "Plan the week")
        await coordinator.sessionStarted(mine, startedByEvent: false)
        XCTAssertEqual(calendarStore.written.values.first?.draft.title, "Focus · Plan the week")
    }

    func testTheNextMeetingLeavesOutFocusGuardsOwnSessions() async {
        let coordinator = make()
        let now = Date()
        defaults.set(true, forKey: IntegrationSettings.sessionsOnCalendar)
        await coordinator.sessionStarted(session(goal: "Plan the week"), startedByEvent: false, now: now)
        // Its own session event starts now; push a copy into the future as if planned.
        await coordinator.planned([now.addingTimeInterval(10 * 60)], minutes: 25, now: now)
        calendarStore.userEvents = [CalendarEntry(id: "standup", title: "Standup", start: now.addingTimeInterval(25 * 60),
                                                  end: now.addingTimeInterval(55 * 60), isAllDay: false,
                                                  isOwn: false, isDeclined: false)]
        await coordinator.refreshNextMeeting(now: now)
        XCTAssertEqual(coordinator.nextMeeting?.title, "Standup")

        defaults.set(false, forKey: IntegrationSettings.nextMeeting)
        await coordinator.refreshNextMeeting(now: now)
        XCTAssertNil(coordinator.nextMeeting)
    }
}

// MARK: - Skipping a planned session

final class PlannedSessionCommandTests: XCTestCase {
    func testSkipThisOneNamesTheSlot() {
        let slot = Date(timeIntervalSinceReferenceDate: 815_000_000)
        XCTAssertEqual(NotificationCommand(action: NotificationAction.skip.rawValue,
                                           category: "plannedSession|Start 50 minutes|Skip this one",
                                           info: [NotificationInfo.slot: slot.timeIntervalSinceReferenceDate]),
                       .skipPlannedSession(at: slot))
    }
}
