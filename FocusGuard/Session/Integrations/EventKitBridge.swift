import EventKit
import Foundation

/// A calendar or a Reminders list, as the settings list it.
struct CalendarChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The account it's in: "iCloud", "Google".
    let account: String
    /// Whether FocusGuard can add events to it.
    let canWrite: Bool
}

/// A calendar event as FocusGuard reads it.
struct CalendarEntry: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// One FocusGuard wrote (`OwnEvents`).
    let isOwn: Bool
    let isDeclined: Bool
}

/// What FocusGuard writes for a session, or for a planned one.
struct SessionEventDraft: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    /// Ties the event to its session or slot (`OwnEvents.link`).
    let key: String
}

/// An event FocusGuard wrote: its identifier, and the key in its link to
/// find it by if the calendar gave it a new identifier.
struct OwnEventRef: Equatable, Sendable {
    let id: String
    let key: String
    /// When it started, to look for it around.
    let start: Date
}

/// The calendar as `SessionCalendarWriter` and `IntegrationsCoordinator`
/// use it. EventKit's own (`EventKitBridge`) works off the main thread;
/// tests pass a fake.
protocol CalendarStore: AnyObject {
    func calendars() async -> [CalendarChoice]
    /// The identifier of the calendar new events go to by default.
    func defaultCalendarID() async -> String?
    /// Events overlapping the range, in the chosen calendars (all when
    /// empty). Nil without access.
    func events(from start: Date, to end: Date, calendarIDs: [String], ownIDs: Set<String>) async -> [CalendarEntry]?
    /// Adds a busy event; returns its identifier, nil when it couldn't.
    func create(_ draft: SessionEventDraft, calendarID: String?) async -> String?
    /// Moves or renames one of FocusGuard's own events; returns its
    /// identifier now, nil when it's gone.
    func update(_ ref: OwnEventRef, to draft: SessionEventDraft) async -> String?
    /// Removes one of FocusGuard's own events. True when it's gone.
    func remove(_ ref: OwnEventRef) async -> Bool
}

/// Reminders, for goals and ticking them off.
protocol ReminderStore: AnyObject {
    func lists() async -> [CalendarChoice]
    /// Open reminders in the chosen lists (all when empty); nil without access.
    func incomplete(listIDs: [String]) async -> [TaskItem]?
    /// Ticks a reminder off, or back on. True when it's saved.
    func setCompleted(_ id: String, _ completed: Bool) async -> Bool
    func requestAccess() async -> Bool
}

/// EventKit, off the main thread. Calendars and Reminders share one store,
/// made again when access changes so a store from before a grant doesn't
/// stay blind.
actor EventKitBridge: CalendarStore, ReminderStore {
    /// Made on first use, off the main thread.
    private var store: EKEventStore?
    private var madeWith: (EKAuthorizationStatus, EKAuthorizationStatus)?

    private func current() -> EKEventStore {
        let now = (EKEventStore.authorizationStatus(for: .event), EKEventStore.authorizationStatus(for: .reminder))
        if let store, let madeWith, madeWith == now { return store }
        let fresh = EKEventStore()
        store = fresh
        madeWith = now
        return fresh
    }

    // MARK: - Calendar

    func calendars() -> [CalendarChoice] {
        guard EventKitAccess.calendars == .granted else { return [] }
        return current().calendars(for: .event).map(Self.choice).sorted(by: Self.order)
    }

    func defaultCalendarID() -> String? {
        guard EventKitAccess.calendars == .granted else { return nil }
        return current().defaultCalendarForNewEvents?.calendarIdentifier
    }

    func events(from start: Date, to end: Date, calendarIDs: [String], ownIDs: Set<String>) -> [CalendarEntry]? {
        guard EventKitAccess.calendars == .granted, end > start else { return nil }
        let store = current()
        let chosen = Set(calendarIDs)
        let calendars = chosen.isEmpty ? nil : store.calendars(for: .event).filter { chosen.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(withStart: start, end: end,
                                                 calendars: calendars?.isEmpty == false ? calendars : nil)
        return store.events(matching: predicate).compactMap { event in
            guard let from = event.startDate, let to = event.endDate else { return nil }
            return CalendarEntry(id: event.eventIdentifier ?? "", title: event.title ?? "", start: from, end: to,
                                 isAllDay: event.isAllDay, isOwn: OwnEvents.isOwn(event, ids: ownIDs),
                                 isDeclined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined)
        }
    }

    func create(_ draft: SessionEventDraft, calendarID: String?) -> String? {
        guard EventKitAccess.calendars == .granted else { return nil }
        let store = current()
        let chosen = calendarID.flatMap { store.calendar(withIdentifier: $0) }
        guard let calendar = chosen?.allowsContentModifications == true ? chosen : store.defaultCalendarForNewEvents,
              calendar.allowsContentModifications else { return nil }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.notes = OwnEvents.shownNote
        apply(draft, to: event)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func update(_ ref: OwnEventRef, to draft: SessionEventDraft) -> String? {
        guard EventKitAccess.calendars == .granted else { return nil }
        let store = current()
        guard let event = find(ref, in: store) else { return nil }
        apply(draft, to: event)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func remove(_ ref: OwnEventRef) -> Bool {
        guard EventKitAccess.calendars == .granted else { return false }
        let store = current()
        guard let event = find(ref, in: store) else { return true }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    private func apply(_ draft: SessionEventDraft, to event: EKEvent) {
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = max(draft.end, draft.start.addingTimeInterval(60))
        event.availability = .busy
        event.url = OwnEvents.link(key: draft.key)
    }

    /// The event by its identifier, or else by the key in its link near
    /// where it was; only ever one FocusGuard wrote.
    private func find(_ ref: OwnEventRef, in store: EKEventStore) -> EKEvent? {
        if !ref.id.isEmpty, let event = store.event(withIdentifier: ref.id) { return event }
        let predicate = store.predicateForEvents(withStart: ref.start.addingTimeInterval(-86_400),
                                                 end: ref.start.addingTimeInterval(86_400), calendars: nil)
        return store.events(matching: predicate).first { OwnEvents.key(in: $0.url) == ref.key }
    }

    // MARK: - Reminders

    func lists() -> [CalendarChoice] {
        guard EventKitAccess.reminders == .granted else { return [] }
        return current().calendars(for: .reminder).map(Self.choice).sorted(by: Self.order)
    }

    func incomplete(listIDs: [String]) async -> [TaskItem]? {
        guard EventKitAccess.reminders == .granted else { return nil }
        let store = current()
        let chosen = Set(listIDs)
        let lists = chosen.isEmpty ? nil : store.calendars(for: .reminder).filter { chosen.contains($0.calendarIdentifier) }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                              calendars: lists?.isEmpty == false ? lists : nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let calendar = Calendar.current
                let items = (reminders ?? []).compactMap { reminder -> TaskItem? in
                    let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    return TaskItem(id: reminder.calendarItemIdentifier, title: title, list: reminder.calendar?.title ?? "",
                                    due: reminder.dueDateComponents.flatMap { calendar.date(from: $0) },
                                    created: reminder.creationDate)
                }
                continuation.resume(returning: items)
            }
        }
    }

    func setCompleted(_ id: String, _ completed: Bool) -> Bool {
        guard EventKitAccess.reminders == .granted else { return false }
        let store = current()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await current().requestFullAccessToReminders()) ?? false
        _ = current()
        return granted
    }

    // MARK: -

    private static func choice(_ calendar: EKCalendar) -> CalendarChoice {
        CalendarChoice(id: calendar.calendarIdentifier, title: calendar.title,
                       account: calendar.source?.title ?? "", canWrite: calendar.allowsContentModifications)
    }

    private static func order(_ a: CalendarChoice, _ b: CalendarChoice) -> Bool {
        a.account != b.account ? a.account < b.account : a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
