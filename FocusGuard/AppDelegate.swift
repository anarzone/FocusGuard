import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appState: AppState!
    private var menuBarController: MenuBarController!
    private var mainWindow: NSWindow?
    private var mainWindowTab: MainTab?
    /// Tracks whether the user has interacted with the app since launch.
    /// Used to decide whether the main window should auto-open on first launch
    /// (Finder click) vs stay hidden (login startup).
    private var didShowMainWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        menuBarController = MenuBarController(
            timerProvider: { [appState = appState!] in
                Self.menuBarTimer(from: appState)
            }
        ) { [weak self, appState = appState!] in
            MenuBarView(
                permissions: appState.permissions,
                appState: appState,
                onOpenMain: { tab in self?.openMainWindow(tab: tab) }
            )
        }

        // If the user explicitly launched us (Finder double-click, Spotlight,
        // brew install + open), surface the Home window. If we were started
        // by login items we stay quiet so the menu bar item is the only sign.
        if !launchedAtLogin() {
            openMainWindow(tab: .home)
        }
    }

    /// Snapshot of what the menu-bar countdown should display. Break wins
    /// over session because a break overlay/sticky timer is the user's
    /// active intent at that moment.
    @MainActor
    private static func menuBarTimer(from appState: AppState) -> MenuBarTimer? {
        if let state = appState.breakManager.current {
            return MenuBarTimer(kind: .breakRunning,
                                remainingSeconds: Int(state.remaining()))
        }
        if let session = appState.sessionManager.currentSession,
           let planned = session.plannedDurationMinutes {
            let elapsed = appState.sessionManager.runningSeconds(for: session)
            let remaining = Int(TimeInterval(planned * 60) - elapsed)
            let kind: MenuBarTimer.Kind = session.pausedAt == nil ? .session : .sessionPaused
            return MenuBarTimer(kind: kind, remainingSeconds: max(0, remaining))
        }
        return nil
    }

    /// Best-effort check: are we being started as a login item, or did the
    /// user just click us? `NSApplication.LaunchOptionsKey.startedByLogin`
    /// is iOS-only. On macOS we approximate by checking the launching process.
    private func launchedAtLogin() -> Bool {
        // ProcessInfo's `userName` is always set; the smarter signal is whether
        // our parent process is `launchd` (login) vs `Finder`/`Dock`/`open`.
        let parentPID = getppid()
        let parentName = NSRunningApplication(processIdentifier: parentPID)?.localizedName ?? ""
        // launchd has pid 1 and no associated NSRunningApplication.
        return parentPID == 1 || parentName.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.tracker.flush()
    }

    /// Fired when the user clicks the app in Finder or Dock while it's already
    /// running. With LSUIElement the app has no Dock icon, so this most often
    /// means the user double-clicked /Applications/FocusGuard.app — they want
    /// the UI to come up. Default behavior is "do nothing"; we override to
    /// open the main window on the Home tab.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMainWindow(tab: .home)
        return false   // we handled the reopen ourselves
    }

    /// Opens (or brings to front) the standalone window with the requested tab.
    /// Created lazily; kept alive after close so reopening is instant.
    /// Switches the app to `.regular` activation policy so it shows in the
    /// Dock and Cmd+Tab. Closing the window switches back to `.accessory`,
    /// which hides the Dock icon — the app stays running in the menu bar.
    func openMainWindow(tab: MainTab = .home) {
        // Show in Dock + Cmd+Tab while a window is up.
        NSApp.setActivationPolicy(.regular)

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

            // When the user clicks the red traffic light, drop the Dock icon
            // and go back to accessory mode. The app stays alive through the
            // menu bar item.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(mainWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )

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
        didShowMainWindow = true
    }

    @objc private func mainWindowWillClose(_ note: Notification) {
        // Drop back to accessory: removes Dock icon, app keeps running via
        // the menu bar item. setActivationPolicy is async-safe to call here.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
