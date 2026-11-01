import AppKit
import Foundation

/// The integrations that sign in to nothing (Settings › Integrations):
/// sessions on the calendar, the next meeting in the menu, open reminders
/// as goals and ticking them off (Pro), and the Git branch as a goal.
///
/// EventKit is read and written off the main thread (`EventKitBridge`);
/// what the menu shows is kept here.
@MainActor
@Observable
final class IntegrationsCoordinator {
    /// The next timed event in the chosen calendars; nil with the switch
    /// off or without access. The menu shows it from 30 minutes before.
    private(set) var nextMeeting: NextMeeting?
    /// Open reminders to offer as goals, best first. Empty unless Pro and
    /// switched on.
    private(set) var reminderGoals: [ReminderItem] = []
    /// The branch being worked on, with the switch on.
    private(set) var gitGoal: GitGoal?
    /// Sessions whose goal came from a reminder, by session.
    private(set) var taskLinks: [UUID: TaskLink] = [:]
    /// What's next on the list after a session's reminder was ticked off.
    private(set) var nextTasks: [UUID: ReminderItem] = [:]

    @ObservationIgnored let calendarWriter: SessionCalendarWriter
    @ObservationIgnored private let calendar: CalendarStore
    @ObservationIgnored private let reminders: ReminderStore
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
        /// The reminder picked under the goal field, until a session starts.
        static let picked = "integrations.reminders.picked"
    }
    /// Links kept, newest last.
    static let linksKept = 30
    /// The next meeting is looked up this often.
    static let meetingInterval: TimeInterval = 60

    init(calendar: CalendarStore, reminders: ReminderStore, entitlements: Entitlements? = nil,
         defaults: UserDefaults = .standard) {
        self.calendar = calendar
        self.reminders = reminders
        self.defaults = defaults
        self.entitlements = entitlements ?? .shared
        self.calendarWriter = SessionCalendarWriter(store: calendar, defaults: defaults)
        if let data = defaults.data(forKey: Key.links),
           let saved = try? JSONDecoder().decode([String: TaskLink].self, from: data) {
            taskLinks = Dictionary(uniqueKeysWithValues: saved.compactMap { key, link in UUID(uuidString: key).map { ($0, link) } })
        }
    }

    convenience init() {
        let bridge = EventKitBridge()
        self.init(calendar: bridge, reminders: bridge)
    }

    /// Reminders as goals and ticking them off: Pro, and switched on.
    var remindersOn: Bool {
        isShipped && entitlements.isUnlocked(.taskGoals) && IntegrationSettings.isOn(IntegrationSettings.reminders, defaults)
    }

    // MARK: - Refreshing

    /// When the menu opens: the next meeting, the reminders and the branch.
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

    /// Reminders (Pro) and the Git branch, for the goal field.
    func refreshGoalSources(now: Date = .now) async {
        if remindersOn {
            let items = await reminders.incomplete(listIDs: IntegrationSettings.ids(IntegrationSettings.reminderLists, defaults)) ?? []
            let ordered = ReminderGoals.ordered(items, now: now)
            if ordered != reminderGoals { reminderGoals = ordered }
        } else if !reminderGoals.isEmpty {
            reminderGoals = []
        }

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
        linkPickedReminder(to: session)
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

    // MARK: - Reminders as goals

    /// A suggestion was picked under the goal field: a reminder is kept
    /// until the session starts, to tick it off after.
    func goalPicked(_ suggestion: GoalSuggestion) {
        guard case .reminder(let id, _) = suggestion.source,
              let item = reminderGoals.first(where: { $0.id == id }),
              let data = try? JSONEncoder().encode(item) else {
            defaults.removeObject(forKey: Key.picked)
            return
        }
        defaults.set(data, forKey: Key.picked)
    }

    /// The reminder picked for the next session, if any.
    var pickedReminder: ReminderItem? {
        defaults.data(forKey: Key.picked).flatMap { try? JSONDecoder().decode(ReminderItem.self, from: $0) }
    }

    /// "Start 25 min" on the next reminder: it's picked for the session
    /// about to start.
    func pick(_ item: ReminderItem) {
        if let data = try? JSONEncoder().encode(item) { defaults.set(data, forKey: Key.picked) }
    }

    /// The picked reminder goes with the session, while the goal is still
    /// its title (an edited goal is the user's own).
    private func linkPickedReminder(to session: Session) {
        guard let item = pickedReminder else { return }
        defaults.removeObject(forKey: Key.picked)
        guard remindersOn, let goal = session.goal,
              goal.caseInsensitiveCompare(String(item.title.prefix(SessionGoal.maxLength))) == .orderedSame else { return }
        taskLinks[session.id] = TaskLink(reminder: item, linkedAt: session.startedAt)
        saveLinks()
    }

    // MARK: - Ticking off

    /// The goal's verdict changed, from the debrief or the user: Done ticks
    /// the reminder off, anything else takes back a tick FocusGuard made.
    func verdictChanged(_ session: Session, byUser: Bool, now: Date = .now) async {
        guard let link = taskLinks[session.id], entitlements.isUnlocked(.taskGoals) else { return }
        switch link.change(for: session.goalVerdict, byUser: byUser) {
        case .tick:   await setTicked(true, session: session.id, now: now)
        case .untick: await setTicked(false, session: session.id, now: now)
        case .none:   break
        }
    }

    /// "Undo": the reminder is open again, and the debrief won't tick it.
    func undoTick(session id: UUID) async {
        guard taskLinks[id]?.ticked == true else { return }
        await setTicked(false, session: id)
        taskLinks[id]?.undone = true
        saveLinks()
    }

    /// "Tick off", after an undo.
    func tickOff(session id: UUID) async {
        await setTicked(true, session: id)
    }

    private func setTicked(_ ticked: Bool, session id: UUID, now: Date = .now) async {
        guard let link = taskLinks[id], link.ticked != ticked,
              await reminders.setCompleted(link.reminder.id, ticked) else { return }
        taskLinks[id]?.ticked = ticked
        if ticked { taskLinks[id]?.undone = false }
        saveLinks()
        if ticked {
            reminderGoals.removeAll { $0.id == link.reminder.id }
            let open = await reminders.incomplete(listIDs: IntegrationSettings.ids(IntegrationSettings.reminderLists, defaults)) ?? []
            nextTasks[id] = ReminderGoals.next(after: link.reminder.id, in: open, now: now)
        } else {
            nextTasks[id] = nil
        }
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
}
