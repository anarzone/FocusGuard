import Foundation

/// Puts sessions on the user's calendar as busy time (Settings ›
/// Integrations › Put sessions on your calendar).
///
/// Each session becomes "Focus · <goal or name>" from its start to its
/// planned end, and is moved to its real end when it ends; an open-ended
/// one holds the usual length until then. A slot planned from the morning
/// plan is held as "Focus · planned" straight away; a session started in
/// it takes that event over, and it's removed if none has by its end or
/// the slot is skipped.
///
/// Only events this writer made are ever changed or removed: their
/// identifiers are kept here (with the key in their link, to find them if
/// the calendar renumbers them). The user's own events are never touched.
@MainActor
final class SessionCalendarWriter {
    /// One event this writer made and still looks after.
    struct Entry: Codable, Equatable {
        /// "session-<uuid>" or "slot-<seconds>", also in the event's link.
        var key: String
        var eventID: String
        var start: Date
        var end: Date
        /// The session it shows; nil while it's a planned slot.
        var sessionID: UUID?

        var ref: OwnEventRef { OwnEventRef(id: eventID, key: key, start: start) }
    }

    nonisolated static let plannedTitle = "Focus · planned"
    /// A session this short when it ends is taken off again.
    nonisolated static let shortest: TimeInterval = 60
    /// A session started this long before a planned slot takes it over.
    nonisolated static let claimLead: TimeInterval = 15 * 60
    nonisolated static let ledgerKey = "integrations.calendar.ledger"
    nonisolated static let ownIDsKey = "integrations.calendar.ownEventIDs"
    /// Identifiers of events made, newest last, kept to tell them apart.
    nonisolated static let ownIDsKept = 500

    private(set) var entries: [Entry] = []
    private(set) var ownIDs: [String] = []

    private let store: CalendarStore
    private let defaults: UserDefaults
    /// Sessions whose event is being made, and how the ones among them
    /// that ended meanwhile ended.
    private var starting: Set<UUID> = []
    private var endedWhileStarting: [UUID: (name: String, start: Date, end: Date)] = [:]

    init(store: CalendarStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.ledgerKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        ownIDs = defaults.stringArray(forKey: Self.ownIDsKey) ?? []
    }

    /// The switch in Settings. Off, nothing new is written; events already
    /// written are still kept right.
    var isOn: Bool { IntegrationSettings.isOn(IntegrationSettings.sessionsOnCalendar, defaults) }

    /// "Focus · Write the Q4 report".
    nonisolated static func title(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Focus" : "Focus · \(trimmed)"
    }

    nonisolated static func key(session id: UUID) -> String { "session-\(id.uuidString)" }
    nonisolated static func key(slot: Date) -> String { "slot-\(Int(slot.timeIntervalSinceReferenceDate))" }

    func entry(forSession id: UUID) -> Entry? { entries.first { $0.sessionID == id } }

    // MARK: - Sessions

    /// - Parameters:
    ///   - plannedMinutes: nil for an open-ended session.
    ///   - openEndedMinutes: how long an open-ended one holds until it ends.
    func sessionStarted(id: UUID, name: String, start: Date, plannedMinutes: Int?, openEndedMinutes: Int,
                        now: Date = .now) async {
        guard isOn, entry(forSession: id) == nil, !starting.contains(id) else { return }
        starting.insert(id)
        defer { starting.remove(id) }
        await makeEvent(id: id, name: name, start: start, plannedMinutes: plannedMinutes,
                        openEndedMinutes: openEndedMinutes, now: now)
        if let ended = endedWhileStarting.removeValue(forKey: id) {
            await sessionEnded(id: id, name: ended.name, start: ended.start, end: ended.end)
        }
    }

    private func makeEvent(id: UUID, name: String, start: Date, plannedMinutes: Int?, openEndedMinutes: Int,
                           now: Date) async {
        let end = max(start.addingTimeInterval(TimeInterval((plannedMinutes ?? openEndedMinutes) * 60)),
                      now.addingTimeInterval(Self.shortest))
        let draft = SessionEventDraft(title: Self.title(name), start: start, end: end, key: Self.key(session: id))

        if let slot = entries.first(where: { $0.sessionID == nil && $0.start.addingTimeInterval(-Self.claimLead) <= now && now < $0.end }) {
            drop(slot.key)
            if let eventID = await store.update(slot.ref, to: draft) {
                keep(Entry(key: draft.key, eventID: eventID, start: start, end: end, sessionID: id))
                return
            }
        }
        let calendarID = defaults.string(forKey: IntegrationSettings.sessionsCalendar)
        guard let eventID = await store.create(draft, calendarID: calendarID?.isEmpty == false ? calendarID : nil) else { return }
        keep(Entry(key: draft.key, eventID: eventID, start: start, end: end, sessionID: id))
    }

    /// The session got longer ("5 more min"): its event follows.
    func sessionChanged(id: UUID, name: String, start: Date, end: Date) async {
        guard var entry = entry(forSession: id), entry.end != end else { return }
        let draft = SessionEventDraft(title: Self.title(name), start: start, end: end, key: entry.key)
        guard let eventID = await store.update(entry.ref, to: draft) else { return drop(entry.key) }
        entry.eventID = eventID
        entry.start = start
        entry.end = end
        keep(entry)
    }

    /// Moves the event to the session's real end and its final name, then
    /// lets it go. A session under a minute is taken off instead.
    func sessionEnded(id: UUID, name: String, start: Date, end: Date) async {
        guard let entry = entry(forSession: id) else {
            if starting.contains(id) { endedWhileStarting[id] = (name, start, end) }
            return
        }
        drop(entry.key)
        if end.timeIntervalSince(start) < Self.shortest {
            _ = await store.remove(entry.ref)
            return
        }
        let draft = SessionEventDraft(title: Self.title(name), start: start, end: end, key: entry.key)
        _ = await store.update(entry.ref, to: draft)
    }

    /// At launch: sessions that ended while FocusGuard wasn't running get
    /// their real end; ones deleted since are let go.
    /// - Parameter lookup: a session's name, start and end (nil while running), or nil when it's gone.
    func reconcile(lookup: (UUID) -> (name: String, start: Date, end: Date?)?) async {
        for entry in entries {
            guard let id = entry.sessionID else { continue }
            guard let session = lookup(id) else {
                drop(entry.key)
                continue
            }
            if let end = session.end {
                await sessionEnded(id: id, name: session.name, start: session.start, end: end)
            }
        }
    }

    // MARK: - Planned slots

    /// "Plan them" in the morning plan: each slot is held as busy time.
    func planned(_ slots: [Date], minutes: Int, now: Date = .now) async {
        guard isOn, minutes > 0 else { return }
        let calendarID = defaults.string(forKey: IntegrationSettings.sessionsCalendar)
        for slot in slots where slot > now {
            let key = Self.key(slot: slot)
            guard !entries.contains(where: { $0.key == key }) else { continue }
            let end = slot.addingTimeInterval(TimeInterval(minutes * 60))
            let draft = SessionEventDraft(title: Self.plannedTitle, start: slot, end: end, key: key)
            guard let eventID = await store.create(draft, calendarID: calendarID?.isEmpty == false ? calendarID : nil) else { continue }
            keep(Entry(key: key, eventID: eventID, start: slot, end: end, sessionID: nil))
        }
    }

    /// "Skip this one": the slot comes off the calendar.
    func skipPlanned(_ slot: Date) async {
        guard let entry = entries.first(where: { $0.key == Self.key(slot: slot) && $0.sessionID == nil }) else { return }
        drop(entry.key)
        _ = await store.remove(entry.ref)
    }

    /// Planned slots whose time ran out with no session come off.
    func tick(now: Date = .now) async {
        for entry in entries where entry.sessionID == nil && entry.end <= now {
            drop(entry.key)
            _ = await store.remove(entry.ref)
        }
    }

    // MARK: - Ledger

    private func keep(_ entry: Entry) {
        entries.removeAll { $0.key == entry.key }
        entries.append(entry)
        if !ownIDs.contains(entry.eventID) {
            ownIDs.append(entry.eventID)
            if ownIDs.count > Self.ownIDsKept { ownIDs.removeFirst(ownIDs.count - Self.ownIDsKept) }
            defaults.set(ownIDs, forKey: Self.ownIDsKey)
        }
        save()
    }

    private func drop(_ key: String) {
        entries.removeAll { $0.key == key }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.ledgerKey) }
    }
}
