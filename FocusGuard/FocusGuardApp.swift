import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement = YES means no Dock icon, no main window from a Scene.
        // Both surfaces (menu bar popover + standalone main window) are
        // owned by AppDelegate via AppKit primitives — see AppDelegate.swift.
        // SwiftUI requires at least one Scene. Its Settings… item (⌘,) would
        // open this empty window, so it goes to the main window's Settings
        // tab instead.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        guard appDelegate.appState != nil else { return }
                        appDelegate.openMainWindow(tab: .settings)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
