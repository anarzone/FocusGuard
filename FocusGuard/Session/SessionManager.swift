import Foundation
import SwiftData

@MainActor
@Observable
final class SessionManager {
    private(set) var currentSession: Session?

    private let context: ModelContext
    private let tracker: ActivityTracker
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
        // If we're stopping while paused, account for the in-flight pause.
        if let pausedAt = session.pausedAt {
            session.pausedSeconds += Date().timeIntervalSince(pausedAt)
            session.pausedAt = nil
        }
        session.endedAt = .now
        session.status = status
        Persistence.save(context)
        currentSession = nil
        tracker.currentSession = nil
        onSessionEnded?(session)
    }

    func pauseSession() {
        guard let session = currentSession, session.pausedAt == nil else { return }
        session.pausedAt = .now
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

    /// If the app was killed mid-session, that `Session` row is still active in
    /// the store. We can't tell if it was an intentional shutdown or a crash, so
    /// we mark it abandoned and end it at the latest activity event we recorded
    /// for it. Keeps reports honest without losing data.
    private func reconcileLeftoverSessionsOnLaunch() {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.endedAt == nil }
        )
        descriptor.sortBy = [SortDescriptor(\.startedAt, order: .reverse)]
        guard let leftovers = try? context.fetch(descriptor), !leftovers.isEmpty else { return }

        for session in leftovers {
            // Account for an in-flight pause when computing accumulated paused time.
            if let pausedAt = session.pausedAt {
                session.pausedSeconds += Date().timeIntervalSince(pausedAt)
                session.pausedAt = nil
            }
            session.endedAt = lastEventEnd(for: session) ?? session.startedAt
            session.status = .abandoned
        }
        Persistence.save(context)
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
