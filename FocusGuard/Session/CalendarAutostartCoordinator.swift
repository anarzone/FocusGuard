import Foundation
import EventKit

/// Watches the user's calendars for events whose title contains a configured
/// keyword. When a matching event begins, auto-starts a focus session whose
/// label is the event title and whose planned duration is the event's
/// remaining time. When the event ends (or is cancelled), the session
/// auto-stops.
///
/// We use a 30s polling timer plus the `.EKEventStoreChanged` notification so
/// edits in Calendar.app propagate quickly without us hammering EventKit.
@MainActor
@Observable
final class CalendarAutostartCoordinator {
    // MARK: - Persisted prefs

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "calendarAutostart.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "calendarAutostart.enabled")
            if newValue { startWatching() } else { stopWatching() }
        }
    }

    var keyword: String {
        get { UserDefaults.standard.string(forKey: "calendarAutostart.keyword") ?? "focus" }
        set { UserDefaults.standard.set(newValue, forKey: "calendarAutostart.keyword") }
    }

    // MARK: - Live state observable by SwiftUI

    private(set) var hasCalendarAccess: Bool = false
    private(set) var nextMatchTitle: String?
    private(set) var nextMatchStart: Date?

    // MARK: - Internals

    private let eventStore = EKEventStore()
    private weak var sessionManager: SessionManager?
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    /// EKEvent identifier for the calendar event that triggered the currently
    /// active session, if any. Lets us know which session is "ours" to stop.
    private var activeAutostartEventId: String?

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        self.hasCalendarAccess = isAccessAuthorized
        if enabled && hasCalendarAccess {
            startWatching()
        }
    }

    /// Call from a main-actor context before releasing the coordinator.
    /// Required because the timer + observer need main-actor access to clean up
    /// and Swift's nonisolated deinit can't touch main-actor state.
    /// Currently the coordinator lives for the app's full lifetime so we don't
    /// call this anywhere yet — it's here so a future lifecycle change is safe.
    func tearDown() {
        stopWatching()
    }

    // MARK: - Permission

    var isAccessAuthorized: Bool {
        if #available(macOS 14, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: .event) == .authorized
        }
    }

    /// Asks macOS for Calendar access. Triggers the system prompt the first
    /// time. Returns true if granted at the end of the flow.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(macOS 14, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            hasCalendarAccess = granted
            if granted, enabled { startWatching() }
            return granted
        } catch {
            hasCalendarAccess = false
            return false
        }
    }

    // MARK: - Watch loop

    private func startWatching() {
        guard timer == nil, hasCalendarAccess else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        nextMatchTitle = nil
        nextMatchStart = nil
        // Don't auto-stop a session if the user disabled the feature mid-session;
        // they can stop it manually if they want.
        activeAutostartEventId = nil
    }

    /// Single evaluation pass — called on tick and on calendar change.
    private func evaluate() {
        guard enabled, hasCalendarAccess, let sessionManager else { return }

        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let windowEnd = now.addingTimeInterval(60 * 60 * 12)  // look ahead 12h

        let predicate = eventStore.predicateForEvents(
            withStart: windowStart, end: windowEnd, calendars: nil
        )
        let kw = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !kw.isEmpty else { return }

        let matches = eventStore.events(matching: predicate)
            .filter { ($0.title ?? "").lowercased().contains(kw) }
            .sorted { $0.startDate < $1.startDate }

        let active = matches.first { $0.startDate <= now && now < $0.endDate }
        let upcoming = matches.first { $0.startDate > now }

        // Surface the next match for the Settings UI.
        if let active {
            nextMatchTitle = active.title
            nextMatchStart = active.startDate
        } else if let upcoming {
            nextMatchTitle = upcoming.title
            nextMatchStart = upcoming.startDate
        } else {
            nextMatchTitle = nil
            nextMatchStart = nil
        }

        // Drive the session.
        if let active {
            startSessionIfNeeded(for: active, now: now, sessionManager: sessionManager)
        } else {
            stopSessionIfOurs(sessionManager: sessionManager)
        }
    }

    private func startSessionIfNeeded(for event: EKEvent, now: Date, sessionManager: SessionManager) {
        guard sessionManager.currentSession == nil else { return }
        guard activeAutostartEventId != event.eventIdentifier else { return }

        let remainingSeconds = event.endDate.timeIntervalSince(now)
        let minutes = max(1, Int(remainingSeconds / 60))
        sessionManager.startSession(
            label: event.title ?? "Focus session",
            plannedDurationMinutes: minutes
        )
        activeAutostartEventId = event.eventIdentifier
    }

    private func stopSessionIfOurs(sessionManager: SessionManager) {
        if activeAutostartEventId != nil, sessionManager.currentSession != nil {
            sessionManager.stopSession()
        }
        activeAutostartEventId = nil
    }
}
