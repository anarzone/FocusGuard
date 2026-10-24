import AppIntents

/// Phrases for Siri, and the actions Spotlight and the Shortcuts app show
/// for FocusGuard without any setup.
struct FocusGuardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFocusSessionIntent(),
            phrases: [
                "Start a focus session in \(.applicationName)",
                "Start focusing with \(.applicationName)",
                "Focus with \(.applicationName)",
            ],
            shortTitle: "Start Focus Session",
            systemImageName: "shield"
        )
        AppShortcut(
            intent: FocusSummaryIntent(),
            phrases: [
                "How focused was I \(\.$period) in \(.applicationName)",
                "How focused am I in \(.applicationName)",
                "Get my focused time from \(.applicationName)",
            ],
            shortTitle: "How Focused Was I?",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: TakeBreakIntent(),
            phrases: [
                "Take a break in \(.applicationName)",
                "Start a break in \(.applicationName)",
            ],
            shortTitle: "Take a Break",
            systemImageName: "cup.and.saucer"
        )
        AppShortcut(
            intent: PauseFocusSessionIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Resume \(.applicationName)",
                "Pause my session in \(.applicationName)",
            ],
            shortTitle: "Pause or Resume",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: EndFocusSessionIntent(),
            phrases: [
                "End my focus session in \(.applicationName)",
                "Stop focusing in \(.applicationName)",
            ],
            shortTitle: "End Focus Session",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: CurrentFocusSessionIntent(),
            phrases: [
                "How long is left in \(.applicationName)",
                "What's my \(.applicationName) session",
            ],
            shortTitle: "Current Session",
            systemImageName: "timer"
        )
    }
}
