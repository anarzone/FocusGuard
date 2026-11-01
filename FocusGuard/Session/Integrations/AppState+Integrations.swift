import Foundation
import SwiftData

extension AppState {
    /// Called once from `init`: what the integrations need to know.
    func wireIntegrations() {
        integrations.frontWindow = { [weak self] in
            guard let snapshot = self?.tracker.currentSnapshot else { return nil }
            return (snapshot.bundleIdentifier, snapshot.windowTitle)
        }
        sessionManager.onSessionExtended = { [weak self] session in
            Task { await self?.integrations.sessionExtended(session) }
        }
        debriefs.onVerdict = { [weak self] session, byUser in
            Task { await self?.integrations.verdictChanged(session, byUser: byUser) }
        }
        let context = container.mainContext
        Task { [weak self] in
            await self?.integrations.reconcile { id in
                var descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                return Persistence.fetch(context, descriptor).first
            }
        }
    }

    /// After the goal moved onto the session: a picked reminder goes with
    /// it, and the session goes on the calendar unless the user's own event
    /// started it.
    func integrationsSessionStarted(_ session: Session?) {
        guard let session else { return }
        Task {
            // Calendar auto-start notes its session once starting returns,
            // which is before this runs.
            let byEvent = calendarAutostart.startedSessionID == session.id
            await integrations.sessionStarted(session, startedByEvent: byEvent)
        }
    }
}
