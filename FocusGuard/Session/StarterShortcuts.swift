import Foundation

/// Catalog of recommended Shortcuts users can install to drive the System
/// Focus integration. macOS ships built-in Focus modes (Work, Do Not Disturb,
/// Reading, Mindfulness, etc.) so most starters just call "Set Focus" with
/// the right mode.
///
/// Each entry has an optional `iCloudURL` — when populated, the "Install"
/// button opens it in Shortcuts.app for one-click import. Until then, the
/// install button shows a recipe alert and opens a blank shortcut for the
/// user to assemble.
struct StarterShortcut: Identifiable, Hashable {
    let id: String
    /// What the shortcut should be named in the user's library. We pick names
    /// matching what FocusGuard will look for in the start/end pickers.
    /// In the user's language, except with an `iCloudURL`: a shared shortcut
    /// imports under the name it was shared with.
    let shortcutName: String
    /// The name in English: what shortcuts set up in English are called.
    let englishName: String
    /// One-line label for the catalog row.
    let title: String
    /// Slightly longer copy to set expectations.
    let summary: String
    /// Step-by-step actions to add inside Shortcuts.app. Each item is one
    /// action block as the user would see it.
    let recipe: [String]
    /// Optional iCloud share link. When set, "Install" opens this directly
    /// and the user just hits "Add Shortcut" in the preview.
    let iCloudURL: URL?
    /// Whether this shortcut is intended for session start vs end.
    let role: Role

    enum Role: String { case start, end }

    /// Whether it's among the shortcuts in the user's library, under either name.
    func isInstalled(in installed: [String]) -> Bool {
        installed.contains(shortcutName) || installed.contains(englishName)
    }
}

enum StarterShortcuts {
    /// The catalog. Pairs of start/end starters covering the most common modes.
    /// To wire one-click install for a starter, create it once in Shortcuts.app,
    /// share via iCloud, paste the URL into `iCloudURL` here.
    static let all: [StarterShortcut] = [
        // MARK: Work focus
        StarterShortcut(
            id: "work.start",
            shortcutName: "FocusGuard · Start Work",
            englishName: "FocusGuard · Start Work",
            title: String(localized: "Start Work focus"),
            summary: String(localized: "Turns on Apple's built-in Work focus mode for the duration of your session."),
            recipe: [
                String(localized: "Add action: Set Focus", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the focus name → choose Work", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap Until → Off (we'll turn it off when the session ends)", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: URL(string: "https://www.icloud.com/shortcuts/c91a832d529342beb5046e4596c0cc5c"),
            role: .start
        ),
        StarterShortcut(
            id: "work.end",
            shortcutName: String(localized: "FocusGuard · End Work", comment: "A shortcut's name in the Shortcuts app"),
            englishName: "FocusGuard · End Work",
            title: String(localized: "End Work focus"),
            summary: String(localized: "Turns off any active Focus when the session ends."),
            recipe: [
                String(localized: "Add action: Set Focus", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the focus name → choose Do Not Disturb (or any)", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the toggle → Turn Off", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: nil,
            role: .end
        ),

        // MARK: Do Not Disturb
        StarterShortcut(
            id: "dnd.start",
            shortcutName: String(localized: "FocusGuard · Start DND", comment: "A shortcut's name in the Shortcuts app"),
            englishName: "FocusGuard · Start DND",
            title: String(localized: "Start Do Not Disturb"),
            summary: String(localized: "Quietest option — silences all notifications until the session ends."),
            recipe: [
                String(localized: "Add action: Set Focus", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the focus name → choose Do Not Disturb", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap Until → Off", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: nil,
            role: .start
        ),
        StarterShortcut(
            id: "dnd.end",
            shortcutName: String(localized: "FocusGuard · End DND", comment: "A shortcut's name in the Shortcuts app"),
            englishName: "FocusGuard · End DND",
            title: String(localized: "End Do Not Disturb"),
            summary: String(localized: "Clears Do Not Disturb when the session ends."),
            recipe: [
                String(localized: "Add action: Set Focus", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the focus name → Do Not Disturb", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the toggle → Turn Off", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: nil,
            role: .end
        ),

        // MARK: Reading
        StarterShortcut(
            id: "reading.start",
            shortcutName: String(localized: "FocusGuard · Start Reading", comment: "A shortcut's name in the Shortcuts app"),
            englishName: "FocusGuard · Start Reading",
            title: String(localized: "Start Reading focus"),
            summary: String(localized: "Uses Apple's Reading focus — softer than DND, good for shallow reading sessions."),
            recipe: [
                String(localized: "Add action: Set Focus", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the focus name → choose Reading", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap Until → Off", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: nil,
            role: .start
        ),
        StarterShortcut(
            id: "reading.end",
            shortcutName: String(localized: "FocusGuard · End Reading", comment: "A shortcut's name in the Shortcuts app"),
            englishName: "FocusGuard · End Reading",
            title: String(localized: "End Reading focus"),
            summary: String(localized: "Clears the Reading focus when the session ends."),
            recipe: [
                String(localized: "Add action: Set Focus", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the focus name → Reading", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Tap the toggle → Turn Off", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: nil,
            role: .end
        ),

        // MARK: Deep Work — Work focus + close distracting apps
        StarterShortcut(
            id: "deep.start",
            shortcutName: String(localized: "FocusGuard · Start Deep Work", comment: "A shortcut's name in the Shortcuts app"),
            englishName: "FocusGuard · Start Deep Work",
            title: String(localized: "Start Deep Work"),
            summary: String(localized: "Combines Work focus with quitting Slack, Mail, and Messages so they can't ping you."),
            recipe: [
                String(localized: "Add action: Set Focus → Work, Until Off", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Add action: Quit App → Slack", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Add action: Quit App → Mail", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Add action: Quit App → Messages", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: nil,
            role: .start
        ),
        StarterShortcut(
            id: "deep.end",
            shortcutName: String(localized: "FocusGuard · End Deep Work", comment: "A shortcut's name in the Shortcuts app"),
            englishName: "FocusGuard · End Deep Work",
            title: String(localized: "End Deep Work"),
            summary: String(localized: "Turns Work focus off and reopens the apps you were using."),
            recipe: [
                String(localized: "Add action: Set Focus → Work, Turn Off", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
                String(localized: "Add action: Open App → Slack (optional, only if you want it back)", comment: "A step in Apple's Shortcuts app: use the names macOS shows in this language"),
            ],
            iCloudURL: nil,
            role: .end
        ),
    ]
}
