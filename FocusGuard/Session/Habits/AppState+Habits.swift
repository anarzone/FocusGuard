import AppKit
import Foundation

extension AppState {
    /// Called once from `init`: what the notifications need to know, and
    /// what their buttons do.
    func wireNotifications() {
        notificationPresenter.nudgeContext = { [weak self] in self?.nudgeContext() }
        escalationEngine.holdsNudges = { [weak self] in self?.habits.isInCall() ?? false }
        NotificationRouter.shared.perform = { [weak self] in self?.perform($0) }
        NotificationRouter.shared.attach()
    }

    private func nudgeContext(now: Date = .now) -> NudgeContext? {
        guard let session = sessionManager.currentSession else { return nil }
        let left = session.plannedDurationMinutes.map {
            max(0, TimeInterval($0 * 60) - sessionManager.runningSeconds(for: session, now: now))
        }
        return NudgeContext(sessionName: session.displayName,
                            minutesLeft: left.map { max(1, Int(($0 / 60).rounded(.up))) },
                            backTo: backToAppName(),
                            bundleId: tracker.currentSnapshot?.bundleIdentifier)
    }

    /// "Session complete: Locked-in Deep Dive. 50 min · 92% focused · 41 min in the zone."
    func presentSessionComplete(for session: Session) {
        let end = session.endedAt ?? .now
        let breakdown = ReportBuilder(context: container.mainContext).breakdown(from: session.startedAt, to: end)
        let running = max(0, end.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        let zone = FocusRuns.compute(FocusRuns.spans(from: session.events), now: end).longest
        notificationPresenter.presentSessionComplete(
            name: session.displayName,
            minutes: Int((running / 60).rounded()),
            focusPercent: Int((breakdown.focusRate * 100).rounded()),
            zoneMinutes: Int(zone / 60),
            breakMinutes: Self.suggestedBreakMinutes(forSessionMinutes: session.plannedDurationMinutes ?? Int(running / 60))
        )
    }

    /// The menu's "Start 50 min, counting these 12": the session counts
    /// from when the offered work began. Nil minutes: the usual length.
    func acceptAutoStartOffer(minutes: Int? = nil, now: Date = .now) {
        guard let offer = habits.autoStartOffer else { return }
        perform(.startFromOffer(since: offer.since, minutes: minutes), now: now)
    }

    /// The menu's "Pause till it ends", during a call.
    func pauseUntilCallEnds() {
        habits.pauseUntilCallEnds()
    }

    /// Carries out a notification's button.
    func perform(_ command: NotificationCommand, now: Date = .now) {
        let actions = FocusActions(sessions: sessionManager, breaks: breakManager,
                                   startBreak: { [weak self] in self?.startBreak(durationMinutes: $0) })
        switch command {
        case .backToWork:
            backToWork()
        case .allowForSession(let url, let bundleId):
            // Strict asks for a wait first; that happens on the block screen.
            guard sessionManager.currentSession != nil, escalationEngine.policy.forWorkWaitSeconds == 0 else { return }
            let current = tracker.currentSnapshot
            escalationEngine.allowForSession(ActivitySnapshot(
                bundleIdentifier: bundleId ?? current?.bundleIdentifier ?? "", appName: "", windowTitle: nil,
                url: url ?? (bundleId == nil ? current?.url : nil), classification: .distraction, observedAt: now))
        case .takeBreak(let minutes):
            guard sessionManager.currentSession == nil, !breakManager.isOnBreak else { return }
            startBreak(durationMinutes: min(max(minutes, FocusActions.breakRange.lowerBound), FocusActions.breakRange.upperBound))
        case .startSession(let minutes):
            actions.start(minutes: minutes, now: now)
        case .startFromOffer(let since, let minutes):
            actions.start(minutes: minutes, startedAt: habits.takeAutoStartOffer(since: since), now: now)
        case .snoozeAutoStart:
            habits.dismissAutoStartOffer(now: now)
        case .planSessions(let slots):
            habits.plan(slots, now: now)
        case .openToday:
            (NSApp.delegate as? AppDelegate)?.openMainWindow(tab: .home)
        case .openPlans:
            (NSApp.delegate as? AppDelegate)?.openMainWindow(tab: .settings)
        }
    }
}
