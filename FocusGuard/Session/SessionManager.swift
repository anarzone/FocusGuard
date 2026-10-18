import Foundation
import SwiftData

@MainActor
@Observable
final class SessionManager {
    private(set) var currentSession: Session?

    private let context: ModelContext
    private let tracker: ActivityTracker
    /// Set when launch picks a session back up: the downtime before it is
    /// already counted as paused, so an idle pause can't backdate past it.
    private var pauseFloor: Date?
    /// Set externally by AppState. We call its hooks on session boundaries.
    var onSessionStarted: (() -> Void)?
    var onSessionEnded: ((Session) -> Void)?

    init(context: ModelContext, tracker: ActivityTracker) {
        self.context = context
        self.tracker = tracker
        reconcileLeftoverSessionsOnLaunch()
    }

    func startSession(label: String? = nil, plannedDurationMinutes: Int? = nil) {
        guard currentSession == nil else { return }
        let session = Session(label: label, plannedDurationMinutes: plannedDurationMinutes)
        context.insert(session)
        Persistence.save(context)
        currentSession = session
        tracker.currentSession = session
        onSessionStarted?()
    }

    func stopSession(status: SessionStatus = .completed) {
        guard let session = currentSession else { return }
        close(session, at: .now, status: status)
        Persistence.save(context)
        currentSession = nil
        tracker.currentSession = nil
        pauseFloor = nil
        onSessionEnded?(session)
    }

    /// Ends `session` at `date`. If it's stopping while paused, the in-flight
    /// pause counts toward its paused total.
    private func close(_ session: Session, at date: Date, status: SessionStatus) {
        if let pausedAt = session.pausedAt {
            session.pausedSeconds += max(0, date.timeIntervalSince(pausedAt))
            session.pausedAt = nil
        }
        session.endedAt = date
        session.status = status
    }

    /// - Parameter date: when the pause began; idle auto-pause backdates it
    ///   to the last input so the idle minutes don't count as session time.
    func pauseSession(at date: Date = .now) {
        guard let session = currentSession, session.pausedAt == nil else { return }
        session.pausedAt = max(session.startedAt, pauseFloor ?? session.startedAt, min(date, .now))
        Persistence.save(context)
        // Detach so events created during the pause don't count toward the session.
        tracker.currentSession = nil
    }

    func resumeSession() {
        guard let session = currentSession, let pausedAt = session.pausedAt else { return }
        session.pausedSeconds += Date().timeIntervalSince(pausedAt)
        session.pausedAt = nil
        Persistence.save(context)
        tracker.currentSession = session
    }

    func rename(_ session: Session, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        session.label = trimmed.isEmpty ? nil : trimmed
        Persistence.save(context)
    }

    /// Removes a finished session from the list. Its tracked activity stays
    /// in reports — only the session grouping goes.
    func delete(_ session: Session) {
        guard session.id != currentSession?.id else { return }
        for event in session.events { event.session = nil }
        context.delete(session)
        Persistence.save(context)
    }

    /// "5 more min": push the planned end out. No-op for open-ended sessions.
    func extendSession(byMinutes minutes: Int) {
        guard let session = currentSession, let planned = session.plannedDurationMinutes else { return }
        session.plannedDurationMinutes = planned + minutes
        Persistence.save(context)
    }

    /// Called every tracker tick. If the active session has a planned duration
    /// and elapsed *running* time has reached it, auto-stop. Time spent paused
    /// doesn't count.
    @discardableResult
    func checkPlannedDuration(now: Date = .now) -> Bool {
        guard let session = currentSession,
              session.pausedAt == nil,
              let planned = session.plannedDurationMinutes else {
            return false
        }
        let elapsed = now.timeIntervalSince(session.startedAt) - session.pausedSeconds
        if elapsed >= TimeInterval(planned * 60) {
            stopSession()
            return true
        }
        return false
    }

    /// Effective running seconds, excluding paused time. Used by the popover
    /// timer + progress bar so the displayed elapsed honors pauses.
    func runningSeconds(for session: Session, now: Date = .now) -> TimeInterval {
        var elapsed = now.timeIntervalSince(session.startedAt) - session.pausedSeconds
        if let pausedAt = session.pausedAt {
            elapsed -= now.timeIntervalSince(pausedAt)
        }
        return max(0, elapsed)
    }

    /// What to do with a session still open at launch.
    enum LeftoverOutcome: Equatable {
        /// Pick it back up. The time the app was down counts as paused.
        case resume(addPausedSeconds: TimeInterval)
        /// Its planned length ran out while the app was down.
        case complete(at: Date)
        /// Gone too long to tell what happened; end it at its last activity.
        case abandon
    }

    /// Decides what happens to a session the app quit in the middle of (an
    /// update relaunch, a manual quit, a restart). `lastSeenAt` is the last
    /// moment the app was known to be running with it open.
    ///
    /// The session is given `window` past `lastSeenAt`: if its planned end
    /// falls inside that, it completes there; if the app is back within it,
    /// it resumes (a paused session stays paused); otherwise it's abandoned.
    nonisolated static func leftoverOutcome(
        startedAt: Date,
        pausedAt: Date?,
        pausedSeconds: TimeInterval,
        plannedMinutes: Int?,
        lastSeenAt: Date,
        now: Date,
        window: TimeInterval = Constants.SessionDurations.resumeAfterQuitWindow
    ) -> LeftoverOutcome {
        let down = now.timeIntervalSince(lastSeenAt)
        if pausedAt == nil, let planned = plannedMinutes {
            let plannedEnd = startedAt.addingTimeInterval(pausedSeconds + TimeInterval(planned * 60))
            if plannedEnd <= min(now, lastSeenAt.addingTimeInterval(window)) {
                return .complete(at: plannedEnd)
            }
        }
        guard down <= window else { return .abandon }
        return .resume(addPausedSeconds: pausedAt == nil ? max(0, down) : 0)
    }

    /// Sessions still open in the store were cut off by the app quitting. The
    /// newest one resumes if the app is back soon enough (or completes, if its
    /// planned length ran out meanwhile); anything else is marked abandoned
    /// and ended at its latest activity event. Keeps reports honest without
    /// losing data.
    private func reconcileLeftoverSessionsOnLaunch(now: Date = .now) {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.endedAt == nil }
        )
        descriptor.sortBy = [SortDescriptor(\.startedAt, order: .reverse)]
        guard let leftovers = try? context.fetch(descriptor), !leftovers.isEmpty else { return }

        for (index, session) in leftovers.enumerated() {
            let outcome: LeftoverOutcome = index == 0
                ? Self.leftoverOutcome(
                    startedAt: session.startedAt,
                    pausedAt: session.pausedAt,
                    pausedSeconds: session.pausedSeconds,
                    plannedMinutes: session.plannedDurationMinutes,
                    lastSeenAt: lastSeen(with: session),
                    now: now
                )
                : .abandon
            switch outcome {
            case .resume(let downtime):
                session.pausedSeconds += downtime
                currentSession = session
                // Same as startSession, or pauseSession if it was paused.
                tracker.currentSession = session.pausedAt == nil ? session : nil
                pauseFloor = now
            case .complete(let plannedEnd):
                close(session, at: plannedEnd, status: .completed)
            case .abandon:
                close(session, at: lastEventEnd(for: session) ?? session.startedAt, status: .abandoned)
            }
        }
        Persistence.save(context)
    }

    /// Last moment the app was known to be running with `session` open: the
    /// newest activity recorded (a paused session owns none, so any event
    /// counts), never earlier than its start or pause.
    private func lastSeen(with session: Session) -> Date {
        var descriptor = FetchDescriptor<ActivityEvent>(
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let lastEvent = Persistence.fetch(context, descriptor).first?.endedAt ?? .distantPast
        return max(lastEvent, session.pausedAt ?? session.startedAt, session.startedAt)
    }

    private func lastEventEnd(for session: Session) -> Date? {
        let sessionId = session.id
        var descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.session?.id == sessionId }
        )
        descriptor.sortBy = [SortDescriptor(\.endedAt, order: .reverse)]
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.endedAt
    }
}
