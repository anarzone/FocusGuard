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
    let shortcutName: String
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
            title: "Start Work focus",
            summary: "Turns on Apple's built-in Work focus mode for the duration of your session.",
            recipe: [
                "Add action: Set Focus",
                "Tap the focus name → choose Work",
                "Tap Until → Off (we'll turn it off when the session ends)",
            ],
            iCloudURL: nil,
            role: .start
        ),
        StarterShortcut(
            id: "work.end",
            shortcutName: "FocusGuard · End Work",
            title: "End Work focus",
            summary: "Turns off any active Focus when the session ends.",
            recipe: [
                "Add action: Set Focus",
                "Tap the focus name → choose Do Not Disturb (or any)",
                "Tap the toggle → Turn Off",
            ],
            iCloudURL: nil,
            role: .end
        ),

        // MARK: Do Not Disturb
        StarterShortcut(
            id: "dnd.start",
            shortcutName: "FocusGuard · Start DND",
            title: "Start Do Not Disturb",
            summary: "Quietest option — silences all notifications until the session ends.",
            recipe: [
                "Add action: Set Focus",
                "Tap the focus name → choose Do Not Disturb",
                "Tap Until → Off",
            ],
            iCloudURL: nil,
            role: .start
        ),
        StarterShortcut(
            id: "dnd.end",
            shortcutName: "FocusGuard · End DND",
            title: "End Do Not Disturb",
            summary: "Clears Do Not Disturb when the session ends.",
            recipe: [
                "Add action: Set Focus",
                "Tap the focus name → Do Not Disturb",
                "Tap the toggle → Turn Off",
            ],
            iCloudURL: nil,
            role: .end
        ),

        // MARK: Reading
        StarterShortcut(
            id: "reading.start",
            shortcutName: "FocusGuard · Start Reading",
            title: "Start Reading focus",
            summary: "Uses Apple's Reading focus — softer than DND, good for shallow reading sessions.",
            recipe: [
                "Add action: Set Focus",
                "Tap the focus name → choose Reading",
                "Tap Until → Off",
            ],
            iCloudURL: nil,
            role: .start
        ),
        StarterShortcut(
            id: "reading.end",
            shortcutName: "FocusGuard · End Reading",
            title: "End Reading focus",
            summary: "Clears the Reading focus when the session ends.",
            recipe: [
                "Add action: Set Focus",
                "Tap the focus name → Reading",
                "Tap the toggle → Turn Off",
            ],
            iCloudURL: nil,
            role: .end
        ),

        // MARK: Deep Work — Work focus + close distracting apps
        StarterShortcut(
            id: "deep.start",
            shortcutName: "FocusGuard · Start Deep Work",
            title: "Start Deep Work",
            summary: "Combines Work focus with quitting Slack, Mail, and Messages so they can't ping you.",
            recipe: [
                "Add action: Set Focus → Work, Until Off",
                "Add action: Quit App → Slack",
                "Add action: Quit App → Mail",
                "Add action: Quit App → Messages",
            ],
            iCloudURL: nil,
            role: .start
        ),
        StarterShortcut(
            id: "deep.end",
            shortcutName: "FocusGuard · End Deep Work",
            title: "End Deep Work",
            summary: "Turns Work focus off and reopens the apps you were using.",
            recipe: [
                "Add action: Set Focus → Work, Turn Off",
                "Add action: Open App → Slack (optional, only if you want it back)",
            ],
            iCloudURL: nil,
            role: .end
        ),
    ]
}
