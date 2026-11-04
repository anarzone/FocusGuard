import AppKit
import Foundation
import SwiftData

extension AppState {
    /// Called once from `init`: what the notifications need to know, and
    /// what their buttons do.
    func wireNotifications() {
        notificationPresenter.nudgeContext = { [weak self] in self?.nudgeContext() }
        // Sharing too: the block screen would be on everyone's screen.
        escalationEngine.holdsNudges = { [weak self] in
            guard let self else { return false }
            return habits.isInCall() || isSharingScreen()
        }
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
                            bundleId: tracker.currentSnapshot?.bundleIdentifier,
                            blockAt: escalationEngine.blockDeadline(at: now),
                            presetName: escalationEngine.presetInForce(at: now).title)
    }

    /// "Session complete: Locked-in Deep Dive. 50 min · 92% focused · 41 min in the zone."
    func presentSessionComplete(for session: Session) {
        // Not one the Mac slept through, or that was ended for being gone too long.
        guard session.status != .abandoned else { return }
        let end = session.endedAt ?? .now
        let running = max(0, end.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        let zone = FocusRuns.compute(FocusRuns.spans(from: session.events), now: end).longest
        notificationPresenter.presentSessionComplete(
            name: session.displayName,
            minutes: Int((running / 60).rounded()),
            focusPercent: Self.completionPercent(of: session),
            zoneMinutes: Int(zone / 60),
            breakMinutes: Self.suggestedBreakMinutes(forSessionMinutes: session.plannedDurationMinutes ?? Int(running / 60)),
            longestThisWeek: SessionFinishedFacts.isLongestThisWeek(zone: zone, others: otherStretchesThisWeek(than: session, now: end))
        )
    }

    /// The longest stretch of every other session this week, the way Reports
    /// measures "Longest in the zone".
    private func otherStretchesThisWeek(than session: Session, now: Date) -> [TimeInterval] {
        let start = ReportPeriod.week.interval(offset: 0, now: now, calendar: .current).start
        let finished = Persistence.fetch(container.mainContext, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= start && $0.endedAt != nil }
        ))
        return finished.filter { $0.id != session.id }.map {
            FocusRuns.compute(FocusRuns.spans(from: $0.events), now: $0.endedAt ?? now).longest
        }
    }

    /// The rate in the session-complete notification: its own events, so
    /// whatever went on during a pause doesn't count. Nil with nothing to
    /// judge it on.
    static func completionPercent(of session: Session) -> Int? {
        var tally = ClassificationTally()
        for event in session.events { tally.add(event.duration, event.classification ?? .neutral) }
        guard tally.focus + tally.distraction > 0 else { return nil }
        return FocusRate.percent(focused: tally.focus, drifted: tally.distraction)
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
            let minutes = notificationPresenter.usualMinutes
            Task { await integrations.planned(slots, minutes: minutes, now: now) }
        case .skipPlannedSession(let slot):
            Task { await integrations.skipPlanned(slot) }
        case .openAnalyzer:
            FocusAnalyzer.shared.wantsResultShown = true
            (NSApp.delegate as? AppDelegate)?.openMainWindow(tab: command.page)
        case .openToday, .openPlans:
            (NSApp.delegate as? AppDelegate)?.openMainWindow(tab: command.page)
        }
    }
}

/// What's true about a session that just finished.
enum SessionFinishedFacts {
    /// "Your longest stretch this week": ahead of every other session this
    /// week. The week's first session has nothing to beat, so it says nothing.
    static func isLongestThisWeek(zone: TimeInterval, others: [TimeInterval]) -> Bool {
        guard zone >= 60, let best = others.max() else { return false }
        return zone > best
    }
}
