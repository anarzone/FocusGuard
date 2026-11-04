import AppKit
import Foundation

extension AppState {
    /// Called once from `init`, outside the UI tests' copy: what the card
    /// reads and acts on.
    func wirePickUp(opener: SystemPickUpOpener) {
        opener.lastPage = { [weak self] in self?.extensionBridge.lastPage(forBrowser: $0) }
        pickUp.readEvents = { [weak self] from, before, focusOnly in
            guard let self else { return [] }
            // What's in memory goes first: the read sees only what's saved.
            self.tracker.flush()
            return await self.stats.pickUpEvents(from: from, before: before, focusOnly: focusOnly)
        }
        tracker.onSuspended = { [weak self] in
            guard let self else { return }
            self.pickUp.observe(self.pickUpMoment())
        }
        pickUp.optedOut = { [weak self] in self?.optOutCache.bundleIdentifiers ?? [] }
        pickUp.session = { [weak self] in self?.pickUpSessionInfo() }
        pickUp.resumeSession = { [weak self] in
            guard let self, self.sessionManager.currentSession?.pausedAt != nil else { return }
            if !self.sessionManager.endIfPausedTooLong() { self.sessionManager.resumeSession() }
        }
        pickUp.currentMoment = { [weak self] in self?.pickUpMoment() ?? PickUpMoment(now: .now) }
        pickUpHotKey.onPress = { [weak self] in self?.pickUp.shortcutPressed() }
        pickUpHotKey.setEnabled(PickUpSettings.isOn(PickUpSettings.shortcut))
    }

    /// What the island reads each second, and what settings still allow.
    func wireIsland() {
        island?.conditions = { [weak self] in self?.islandConditions() ?? IslandConditions(now: .now) }
        island?.isAllowed = { [weak self] in self?.notificationPresenter.islandAllows($0) ?? false }
        Entitlements.shared.reminder = notificationPresenter
    }

    private func islandConditions(now: Date = .now) -> IslandConditions {
        IslandConditions(now: now,
                         frontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                         idleSeconds: IdleMonitor.secondsSinceInput(),
                         inCall: habits.isInCall(now: now),
                         screenUp: blockOverlay.isPresenting || breakOverlay.isPresenting || breakManager.isOnBreak,
                         isAsleepOrLocked: tracker.isSuspended,
                         isAway: tracker.isAway,
                         isDrifting: escalationEngine.currentStreakStartedAt != nil)
    }

    /// What's going on right now. Read at each of the tracker's looks.
    func pickUpMoment(now: Date = .now) -> PickUpMoment {
        let front = tracker.currentSnapshot
        return PickUpMoment(
            now: now,
            front: front,
            frontIsSelf: tracker.isFrontmostSelf,
            isAway: tracker.isAway || tracker.isSuspended,
            lastActiveAt: tracker.lastActiveAt,
            callSince: habits.currentCall?.since,
            screenUp: blockOverlay.isPresenting || breakOverlay.isPresenting || breakManager.isOnBreak,
            frontAllowed: front.map { escalationEngine.allowedThisSession.contains(EscalationEngine.allowKey(for: $0)) } ?? false
        )
    }

    private func pickUpSessionInfo(now: Date = .now) -> PickUpSessionInfo? {
        guard let session = sessionManager.currentSession else { return nil }
        let left = session.plannedDurationMinutes.map {
            Self.minutesRoundedUp(Double($0 * 60) - sessionManager.runningSeconds(for: session, now: now))
        }
        return PickUpSessionInfo(goal: session.goal, isPaused: session.pausedAt != nil, minutesLeft: left)
    }
}
