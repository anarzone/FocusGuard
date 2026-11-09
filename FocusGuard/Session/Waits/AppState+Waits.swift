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
        island?.didAnswer = { [weak self] kind, command in
            guard kind == .wait else { return }
            if case .backTo = command { self?.waits.answered(wentBack: true) } else { self?.waits.answered(wentBack: false) }
        }
        // Connected by an earlier build: bring its hooks up to what this one goes by.
        WaitConnectorFiles().upgradeIfConnected()
        waits.holdSeconds = { FocusAnalyzer.shared.holdSeconds(tool: $0.tool.name, site: $0.to) }
        waits.hold = { [weak self] reach, until in
            guard let self else { return }
            self.tabPause.hold(snapshot: self.tracker.currentSnapshot, tool: reach.tool.name, project: reach.project,
                               startedAt: reach.since, endsAt: until)
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
