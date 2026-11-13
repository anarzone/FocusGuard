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
        waits.fine = { FocusAnalyzer.shared.lessons.fineWaits }
        // "It's for work", wherever it's answered. Said on a second day, it
        // counts as work from then on: the user said so twice. The Analyzer
        // lists it with a way back. A strict session locks the list: then the
        // Analyzer offers it instead.
        escalationEngine.onAllowedForSession = { [weak self] snapshot in
            guard let self, self.sessionManager.currentSession != nil else { return }
            let host = BlockRequest.displayHost(snapshot.url)
            let key = host ?? snapshot.bundleIdentifier
            FocusAnalyzer.shared.learn {
                $0.saidForWork(key: key, name: host ?? snapshot.appName, isSite: host != nil, at: .now)
            }
            self.countDueAsWork([key])
        }
        // Said on two days before this build knew to act on it.
        countDueAsWork(FocusAnalyzer.shared.lessons.work.map(\.key))
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

extension AppState {
    private func sorting(of answer: AnalyzerLessons.WorkAnswer) -> Classification? {
        let rule = answer.isSite
            ? classifier.matchingRule(bundleId: "", windowTitle: nil, url: "https://\(answer.key)/")
            : classifier.matchingRule(bundleId: answer.key, windowTitle: nil, url: nil)
        return rule?.classification
    }

    /// Still sorted as a distraction: counting it as work would change something.
    func isStillCaught(_ answer: AnalyzerLessons.WorkAnswer) -> Bool { sorting(of: answer) == .distraction }

    /// Sorted as work, and not changed back since in Apps & Sites.
    func isCountedAsWork(_ answer: AnalyzerLessons.WorkAnswer) -> Bool { sorting(of: answer) == .focus }

    /// Counts as work what the user called work on enough days, unless a
    /// strict session locks the list (the Analyzer offers it then).
    func countDueAsWork(_ keys: [String]) {
        for key in keys {
            guard let due = FocusAnalyzer.shared.lessons.dueAsWork(key), isStillCaught(due), countAsWork(due) else { continue }
            FocusAnalyzer.shared.learn { $0.settleWork(key, countedAsWork: true) }
            DecisionLog.shared.record(.analyzer, "countedAsWork", detail: due.isSite ? "site" : "app")
        }
    }

    /// "Put it back": caught as a distraction again.
    @discardableResult
    func uncountAsWork(_ answer: AnalyzerLessons.WorkAnswer) -> Bool {
        answer.isSite
            ? classifier.setOverride(host: answer.key, classification: .distraction)
            : classifier.setOverride(bundleId: answer.key, classification: .distraction)
    }

    /// Sorts what the user kept calling work as work. False when it can't
    /// change now (a strict session locks the list).
    func countAsWork(_ answer: AnalyzerLessons.WorkAnswer) -> Bool {
        answer.isSite
            ? classifier.setOverride(host: answer.key, classification: .focus)
            : classifier.setOverride(bundleId: answer.key, classification: .focus)
    }
}
