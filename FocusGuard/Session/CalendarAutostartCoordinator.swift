import AppKit
import Foundation
import EventKit
import os

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

    /// Stored snapshot of access. Refreshed via `refreshAccess()` after a
    /// request, on app activation, and on EKEventStoreChanged. SwiftUI's
    /// @Observable only tracks stored properties — a computed property
    /// reading EventKit live wouldn't trigger re-render.
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
        // Refresh access state when the app comes back to the foreground —
        // catches the case where the user grants/revokes via System Settings
        // and then returns to FocusGuard.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAccess() }
        }
    }

    /// Re-reads EventKit's authorization state into our stored property so
    /// SwiftUI views re-render. Cheap; safe to call frequently.
    func refreshAccess() {
        let now = isAccessAuthorized
        if now != hasCalendarAccess {
            hasCalendarAccess = now
            if now && enabled { startWatching() }
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

    enum AccessState {
        /// User has never been asked. We can request and the system will prompt.
        case notDetermined
        /// User has explicitly denied. Re-request silently no-ops; only System
        /// Settings can flip it back.
        case denied
        /// Granted (full access on macOS 14+, write access on older).
        case authorized
    }

    var accessState: AccessState {
        let raw = EKEventStore.authorizationStatus(for: .event)
        switch raw {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .writeOnly:
            // writeOnly counts as denied for our purposes — we need read.
            return .denied
        case .authorized: return .authorized
        case .fullAccess: return .authorized
        @unknown default: return .denied
        }
    }

    var isAccessAuthorized: Bool { accessState == .authorized }

    /// Asks macOS for Calendar access. Triggers the system prompt the first
    /// time. Returns true if granted at the end of the flow.
    @discardableResult
    func requestAccess() async -> Bool {
        let logger = Logger(subsystem: "com.anar.focusguard", category: "calendar")
        let startState = EKEventStore.authorizationStatus(for: .event).rawValue
        logger.notice("requestAccess: starting; status=\(startState, privacy: .public)")
        FileHandle.standardError.write(Data("[FocusGuard.calendar] requestAccess: starting; status=\(startState)\n".utf8))

        // Bring the app to the foreground so the TCC prompt has a window
        // to anchor against. LSUIElement apps sometimes have prompts open
        // behind their main window otherwise.
        NSApp.activate(ignoringOtherApps: true)

        do {
            let granted: Bool
            if #available(macOS 14, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            let endState = EKEventStore.authorizationStatus(for: .event).rawValue
            logger.notice("requestAccess: granted=\(granted, privacy: .public) endStatus=\(endState, privacy: .public)")
            FileHandle.standardError.write(Data("[FocusGuard.calendar] requestAccess: granted=\(granted) endStatus=\(endState)\n".utf8))
            refreshAccess()  // mirror EventKit state into the stored prop so the UI re-renders
            if granted, enabled { startWatching() }
            return granted
        } catch {
            logger.error("requestAccess: threw \(error.localizedDescription, privacy: .public)")
            FileHandle.standardError.write(Data("[FocusGuard.calendar] requestAccess threw: \(error.localizedDescription)\n".utf8))
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
