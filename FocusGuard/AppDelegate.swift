import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = PermissionsCoordinator()
    private(set) var appState: AppState!
    private var menuBarController: MenuBarController!
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        menuBarController = MenuBarController { [weak self, permissions, appState = appState!] in
            MenuBarView(
                permissions: permissions,
                appState: appState,
                onOpenMain: { tab in self?.openMainWindow(tab: tab) }
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.tracker.flush()
    }

    /// Opens (or brings to front) the standalone Reports/Settings window.
    /// Created lazily and kept alive after close so reopening is instant.
    func openMainWindow(tab: MainTab = .reports) {
        if mainWindow == nil {
            let view = MainWindowView(appState: appState, initialTab: tab)
            let hosting = NSHostingController(rootView: view)
            hosting.preferredContentSize = NSSize(width: 920, height: 620)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hosting
            window.title = "FocusGuard"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 880, height: 580)
            window.center()

            mainWindow = window
            mainWindowTab = tab
        } else if let existingTab = mainWindowTab, existingTab != tab {
            // Window already exists; rebuild rootView with the requested tab.
            let view = MainWindowView(appState: appState, initialTab: tab)
            let hosting = NSHostingController(rootView: view)
            mainWindow?.contentViewController = hosting
            mainWindowTab = tab
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var mainWindowTab: MainTab?
}
