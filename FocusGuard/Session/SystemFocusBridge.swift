import Foundation
import AppKit

/// Bridges focus-session boundaries into macOS via user-defined Shortcuts.
///
/// Apple's `INSetFocusStatusIntent` / `App Intents` route to system Focus
/// requires the `com.apple.developer.focus-status` entitlement which Apple
/// only grants selectively. The Shortcuts app is universally available and
/// lets the user wire whatever they want (Focus mode, DND, Slack status,
/// HomeKit lights) without needing a privileged entitlement.
///
/// Setup: user creates two Shortcuts in the Shortcuts app — by default named
/// "Start FocusGuard" and "End FocusGuard" — and we invoke them via the
/// `shortcuts://run-shortcut` URL scheme.
@MainActor
enum SystemFocusBridge {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.SystemFocus.enabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.SystemFocus.enabled) }
    }

    static var startShortcutName: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.SystemFocus.startName) ?? "Start FocusGuard" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.SystemFocus.startName) }
    }

    static var endShortcutName: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.SystemFocus.endName) ?? "End FocusGuard" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.SystemFocus.endName) }
    }

    static func onSessionStarted() { run(named: startShortcutName) }
    static func onSessionEnded()   { run(named: endShortcutName) }

    private static func run(named name: String) {
        guard enabled, !name.isEmpty else { return }
        let allowed = CharacterSet.urlQueryAllowed
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
