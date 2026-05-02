import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement = YES means no Dock icon, no main window from a Scene.
        // Both surfaces (menu bar popover + standalone main window) are
        // owned by AppDelegate via AppKit primitives — see AppDelegate.swift.
        // SwiftUI requires at least one Scene; an empty Settings is harmless
        // for accessory apps.
        Settings { EmptyView() }
    }
}
