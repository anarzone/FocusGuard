import Foundation

extension AppState {
    /// Called once from `init`, outside the UI tests' copy.
    func wireWaits() {
        waits.currentMoment = { [weak self] in self?.waitMoment() ?? WaitMoment(now: .now) }
        waits.nextTask = { [weak self] project in
            guard let self, let project else { return nil }
            let words = TaskGoals.words(in: project)
            guard !words.isEmpty else { return nil }
            return self.integrations.taskGoals.first { !TaskGoals.words(in: "\($0.title) \($0.list)").isDisjoint(with: words) }
        }
    }

    /// What's going on right now. Read at each of the tracker's looks.
    func waitMoment(now: Date = .now) -> WaitMoment {
        WaitMoment(
            now: now,
            front: tracker.currentSnapshot,
            frontIsSelf: tracker.isFrontmostSelf,
            isAway: tracker.isAway || tracker.isSuspended,
            inCall: habits.currentCall != nil,
            screenUp: blockOverlay.isPresenting || breakOverlay.isPresenting || breakManager.isOnBreak
        )
    }
}
