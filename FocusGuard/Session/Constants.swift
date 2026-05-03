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
}

enum GoalDefaults {
    static let dailyFocusMinutes = 240          // 4 hours
    static let summaryHourLocal = 21            // earliest hour we'll fire the summary
    static let summaryInactivityMinutes = 30    // wait this long after last event
}
