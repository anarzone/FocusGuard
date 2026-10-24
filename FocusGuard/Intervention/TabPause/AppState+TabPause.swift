import AppKit
import Foundation

extension AppState {
    /// The block screen came up: point the site's tab at the paused page.
    func pauseTab(behind request: BlockRequest) {
        let reason: PausedTab.Reason
        switch request.reason {
        case .drift:                  reason = .session
        case .dailyLimit(let limit):  reason = .limit(minutes: limit.minutesToday)
        }
        tabPause.blockShown(reason, snapshot: tracker.currentSnapshot,
                            endsAt: blockContext()?.endsAt, backTo: backToAppName())
    }

    /// A `focusguard://` link, from the paused-tab page.
    func open(_ route: FocusGuardURL) {
        switch route {
        case .back:
            backToWork()
        case .reopenLater(let id):
            setReopensAfterSession(true, pauseID: id)
        case .keepPaused(let id):
            setReopensAfterSession(false, pauseID: id)
        case .startBreak(let minutes):
            guard sessionManager.currentSession == nil, !breakManager.isOnBreak else { return }
            startBreak(durationMinutes: minutes)
        }
    }

    private func setReopensAfterSession(_ reopens: Bool, pauseID: String) {
        tabPause.setReopensAfterSession(reopens, pauseID: pauseID)
        // Opening the link brought FocusGuard forward; hand the browser back.
        if let browser = tabPause.browser(for: pauseID) {
            NSRunningApplication.runningApplications(withBundleIdentifier: browser).first?.activate()
        }
    }
}
