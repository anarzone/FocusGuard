import AppKit
import Foundation

extension AppState {
    /// Called from `wireIntegrations`, once the session hooks are set:
    /// Slack and Discord follow each session too. Each hook runs what was
    /// there first, then updates them.
    func wireStatusSync() {
        let sync = StatusSync.shared
        sync.currentSession = { [weak self] in self?.sessionManager.currentSession }

        let started = sessionManager.onSessionStarted
        sessionManager.onSessionStarted = {
            started?()
            sync.update()
        }
        let extended = sessionManager.onSessionExtended
        sessionManager.onSessionExtended = { session in
            extended?(session)
            sync.update()
        }
        // Resuming moves the end out by the time paused.
        let pauseChanged = sessionManager.onSessionPauseChanged
        sessionManager.onSessionPauseChanged = { paused in
            pauseChanged?(paused)
            sync.update()
        }
        let ended = sessionManager.onSessionEnded
        sessionManager.onSessionEnded = { session in
            ended?(session)
            sync.update()
        }

        // A session picked back up at launch shows again; what was set for
        // one that ended while FocusGuard was closed comes off.
        sync.keepAlive()
        sync.update()
    }

    /// `focusguard://slack-auth`: Slack's answer to "Connect".
    func finishSlackSignIn(code: String?, state: String?, error: String?) {
        StatusSync.shared.finishSlackSignIn(code: code, state: state, error: error)
        // The browser opened the link; bring the settings back.
        NSApp.activate(ignoringOtherApps: true)
    }
}
