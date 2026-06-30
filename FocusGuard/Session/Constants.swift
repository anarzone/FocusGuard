import Foundation

/// Tunable knobs centralised here so they're easy to find and rationalise.
enum Constants {
    enum Tracking {
        /// Frequency of `ActivityTracker.tick()` polls.
        static let pollInterval: TimeInterval = 1.0
        /// Save batched events at most this often (vs per-tick saves).
        static let saveCoalesceInterval: TimeInterval = 5.0
    }

    enum Cache {
        /// Classifier rule cache TTL.
        static let classifierTTL: TimeInterval = 30
        /// AppState weekTrackedSeconds + breakdown cache TTL.
        static let weekStatsTTL: TimeInterval = 30
        static let breakdownTTL: TimeInterval = 5
        /// BrowserTabReader URL TTL.
        static let browserURLTTL: TimeInterval = 2
    }

    enum Escalation {
        static let defaultSilenceSeconds  = 10
        static let defaultNotifySeconds   = 30
        static let defaultBlockSeconds    = 90
        static let defaultCooldownSeconds = 60
        /// Seconds the user gets after pressing "Let me through" before we
        /// can re-block on the same activity.
        static let overrideGraceSeconds: TimeInterval = 120
        /// Seconds the block-overlay countdown delays the override button.
        static let blockOverrideCountdown = 5
    }

    enum Calendar {
        /// How often we re-evaluate matching events.
        static let pollInterval: TimeInterval = 30
        /// How far ahead we look for upcoming matches.
        static let lookAheadHours: Double = 12
    }

    enum Layout {
        static let popoverWidth: CGFloat = 360
        static let mainWindowWidth: CGFloat = 920
        static let mainWindowHeight: CGFloat = 620
        static let mainWindowMinWidth: CGFloat = 880
        static let mainWindowMinHeight: CGFloat = 580
    }

    enum SessionDurations {
        static let presets = [25, 50, 90]
        static let customMin = 5
        static let customMax = 480
    }
}

/// Centralised UserDefaults keys. Avoids stringly-typed scatter across the codebase.
enum SettingsKeys {
    static let menuBarIconStyle      = "menuBarIconStyle"
    static let reduceMotion          = "reduceMotion"
    static let showNotifications     = "showNotifications"
    static let retentionDays         = "retentionDays"
    static let browserAutomationDenied = "browserAutomationDenied"
    /// When true, keep .regular activation policy permanently so a Dock icon
    /// is always visible. Default false (menu-bar-only).
    static let showInDock            = "ui.showInDock"

    enum Session {
        static let defaultDurationMinutes = "session.defaultDurationMinutes"
        static let defaultLabel           = "session.defaultLabel"
    }

    enum Calendar {
        static let enabled = "calendarAutostart.enabled"
        static let keyword = "calendarAutostart.keyword"
    }

    enum Escalation {
        static let silenceThreshold = "escalation.silenceThreshold"
        static let notifyThreshold  = "escalation.notifyThreshold"
        static let blockThreshold   = "escalation.blockThreshold"
        static let cooldown         = "escalation.notifyCooldown"
        static let notificationsEnabled = "escalation.notificationsEnabled"
        static let strictMode       = "escalation.strictMode"
    }

    enum Goal {
        static let dailyFocusMinutes  = "goal.dailyFocusMinutes"
        static let lastSummaryDayKey  = "goal.lastSummaryDay" // ISO yyyy-MM-dd of last summary
        static let weekendsCount      = "goal.weekendsCountTowardStreak"
    }

    enum SystemFocus {
        static let enabled    = "systemFocus.enabled"
        static let startName  = "systemFocus.startShortcutName"
        static let endName    = "systemFocus.endShortcutName"
    }

    enum Breaks {
        /// When true (default), session-end shows the break-or-skip prompt.
        /// When false, sessions just stop quietly with the existing notification.
        static let autoPromptAfterSession = "breaks.autoPromptAfterSession"
        /// When true, the break overlay can't be skipped or hidden — only
        /// extended. (Future use; not yet wired into the overlay.)
        static let strictMode = "breaks.strictMode"
    }

    /// AI focus-insights settings. Non-secret config lives here; the API key /
    /// subscription token is stored in the Keychain (see KeychainStore), never
    /// in UserDefaults.
    enum AI {
        static let enabled        = "ai.enabled"
        static let provider       = "ai.provider"        // ProviderKind.rawValue
        static let model          = "ai.model"
        static let baseURL        = "ai.baseURL"         // OpenAI-compatible only
        // Cache the last successful connection test so reopening the pane shows
        // "Connected" without re-hitting the API (subscription tokens are
        // rate-limited hard — repeated auto-tests cause 429s).
        static let lastOKAccount  = "ai.lastVerifiedAccount"
        static let lastOKAt       = "ai.lastVerifiedAt"  // timeIntervalSince1970
    }
}

enum GoalDefaults {
    static let dailyFocusMinutes = 240          // 4 hours
    static let summaryHourLocal = 21            // earliest hour we'll fire the summary
    static let summaryInactivityMinutes = 30    // wait this long after last event
}
