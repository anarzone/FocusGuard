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

    /// Invokes the named Shortcut via the `shortcuts` CLI. We use the CLI
    /// instead of the `shortcuts://` URL scheme because the URL scheme pops a
    /// modal alert when the shortcut doesn't exist — a hostile UX for users
    /// who haven't created the shortcut yet. The CLI fails silently to stderr
    /// which we ignore.
    private static func run(named name: String) {
        guard enabled, !name.isEmpty else { return }
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            // Discard output so a missing shortcut doesn't surface anywhere.
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
        }
    }

    /// Returns the list of shortcut names the user has installed, sorted.
    /// Used by the Settings pane to validate the configured names and offer
    /// a picker. nil if the CLI fails.
    static func availableShortcuts() async -> [String]? {
        await Task.detached(priority: .utility) { () -> [String]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                let names = text
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .sorted()
                return names
            } catch {
                return nil
            }
        }.value
    }
}
