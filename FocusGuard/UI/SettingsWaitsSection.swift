import SwiftUI

/// Settings › Sessions: the card when the user reaches for a distraction
/// while a tool works.
struct SettingsWaitsSection: View {
    @AppStorage(WaitSettings.enabled) private var isOn = true

    var body: some View {
        SettingsSection(String(localized: "While a tool works", comment: "Settings section: waits on an AI agent, a chat or a build")) {
            SettingsToggle(title: String(localized: "Offer the next step during a wait"),
                           detail: String(localized: "When you leave Claude Code, Codex, an AI chat, a running command or a build for a distracting site. Worked out from what’s in front, never from what you type."),
                           isOn: $isOn)
        }
    }
}
