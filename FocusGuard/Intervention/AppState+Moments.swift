import Foundation
import SwiftData

extension AppState {
    /// What the block, daily-limit and break screens read and do, beyond the
    /// basics wired in `init`.
    func wireMoments(blockOverlay: BlockOverlayController) {
        blockOverlay.tabPausedProvider = { [weak self] in self?.tabPause.lastPausedID != nil }
        blockOverlay.canStartSessionProvider = { [weak self] in
            guard let self else { return false }
            return sessionManager.currentSession == nil && !breakManager.isOnBreak
        }
        blockOverlay.limitStatusProvider = { [weak self] id in self?.limits.status(for: id) }
        blockOverlay.sessionMinutesProvider = { Self.usualSessionMinutes }
        blockOverlay.onEndSession = { [weak self] in self?.sessionManager.stopSession() }
        blockOverlay.onStartFocus = { [weak self] minutes in self?.startFocusFromLimit(minutes: minutes) }
        blockOverlay.onEditLimits = {
            NotificationCenter.default.post(name: .openMainWindowFromExtension, object: MainTab.settings)
        }
        breakOverlay.finishedSessionProvider = { [weak self] in self?.finishedSessionForBreak() }
        tabPause.summaryProvider = { [weak self] in self?.pausedSummaryForEndedSession() }
    }

    /// The length the menu would start: the last one picked, else the usual length.
    static var usualSessionMinutes: Int {
        let defaults = UserDefaults.standard
        let last = defaults.integer(forKey: "menu.lastSessionMinutes")
        if last > 0 { return last }
        return defaults.object(forKey: SettingsKeys.Session.defaultDurationMinutes) as? Int ?? 50
    }

    /// "Start 50 minutes of focus" from a daily limit: start, then go back to work.
    func startFocusFromLimit(minutes: Int) {
        guard sessionManager.currentSession == nil, !breakManager.isOnBreak else { return }
        sessionManager.startSession(plannedDurationMinutes: minutes)
        backToWork()
    }

    /// The session a break follows: the last one, if it ended in the past
    /// half hour.
    func finishedSessionForBreak(now: Date = .now) -> FinishedSession? {
        guard let ended = lastEndedSession(within: 30 * 60, now: now) else { return nil }
        return FinishedSession(name: ended.session.displayName, minutes: max(1, Int((ended.running / 60).rounded())),
                               focusPercent: ended.timeline.focusPercent)
    }

    /// The session that just ended, for the paused tab's "session over" page.
    func pausedSummaryForEndedSession(now: Date = .now) -> PausedSessionSummary? {
        guard let ended = lastEndedSession(within: 60, now: now), let endedAt = ended.session.endedAt else { return nil }
        let timeline = ended.timeline
        let m = timeline.minutesPerCell
        return PausedSessionSummary(
            name: ended.session.displayName, isAutomaticName: ended.session.label == nil,
            startedAt: ended.session.startedAt, endedAt: endedAt,
            focusMinutes: timeline.focusCells * m, driftMinutes: timeline.driftCells * m,
            otherMinutes: timeline.otherCells * m, focusPercent: timeline.focusPercent
        )
    }

    /// The last session, if it ended less than `window` seconds ago, with
    /// its running time (pauses left out) and its ring.
    private func lastEndedSession(within window: TimeInterval, now: Date) -> (session: Session, running: TimeInterval, timeline: SessionTimeline)? {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let session = Persistence.fetch(container.mainContext, descriptor).first,
              let endedAt = session.endedAt, now.timeIntervalSince(endedAt) < window else { return nil }
        let running = max(0, endedAt.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        let timeline = SessionTimeline.build(
            segments: SessionTimeline.segments(from: session.events),
            elapsed: running,
            planned: session.plannedDurationMinutes.map { TimeInterval($0 * 60) },
            current: nil
        )
        return (session, running, timeline)
    }
}
