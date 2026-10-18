import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appState: AppState!
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    private var mainWindowTab: MainTab?
    /// Tracks whether the user has interacted with the app since launch.
    /// Used to decide whether the main window should auto-open on first launch
    /// (Finder click) vs stay hidden (login startup).
    private var didShowMainWindow = false

    /// Read in `applicationWillFinishLaunching`, while the launch Apple
    /// event is still the current one.
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = Self.isLoginItemLaunch(
            NSAppleEventManager.shared().currentAppleEvent,
            loginItemEnabled: LoginItemController.isEnabled,
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test bundle is injected into this same app as its test host,
        // so this runs during `xcodebuild test`. A headless CI runner can't host
        // the menu bar, a main window, or `.regular` Dock activation — bringing
        // them up makes the host "never finish bootstrapping" and abort. Tests
        // construct the pieces they need directly, so do nothing here under test.
        if NSClassFromString("XCTestCase") != nil { return }

        appState = AppState()
        menuBarController = MenuBarController(
            glyphProvider: { [appState = appState!] in appState.statusGlyphState }
        ) { [weak self, appState = appState!] in
            MenuBarView(
                permissions: appState.permissions,
                appState: appState,
                onOpenMain: { tab in self?.openMainWindow(tab: tab) },
                dismiss: { self?.menuBarController?.close() }
            )
        }

        // Apply the persisted "Show in Dock" preference. When enabled the
        // app stays in .regular policy so the Dock icon is always visible —
        // user can launch FocusGuard from the Dock without needing the menu
        // bar at all.
        if (UserDefaults.standard.object(forKey: SettingsKeys.showInDock) as? Bool ?? true) {
            NSApp.setActivationPolicy(.regular)
        }

        // Listen for changes to the toggle so it takes effect immediately
        // without a relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyDockPreference),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // If the user explicitly launched us (Finder double-click, Spotlight,
        // brew install + open), surface the Home window. If we were started
        // by login items we stay quiet so the menu bar item is the only sign.
        if !launchedAsLoginItem {
            openMainWindow(tab: .home)
        }
    }

    @objc private func applyDockPreference() {
        let pref = (UserDefaults.standard.object(forKey: SettingsKeys.showInDock) as? Bool ?? true)
        let current = NSApp.activationPolicy()
        if pref && current != .regular {
            NSApp.setActivationPolicy(.regular)
        } else if !pref && current == .regular && mainWindow == nil {
            // Only drop the Dock icon when the user has explicitly opted out
            // AND the main window isn't open (otherwise we'd hide the Dock
            // icon mid-session, which is weird).
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Whether macOS started us as a login item. Login items get an
    /// open-application Apple event flagged `keyAELaunchedAsLogInItem`;
    /// Finder, Dock, Spotlight and `open` don't set it. (Checking for a
    /// launchd parent doesn't work: every app launched from Finder has one.)
    /// Fallback: launch-at-login is on and the Mac booted moments ago.
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?,
                                  loginItemEnabled: Bool,
                                  systemUptime: TimeInterval) -> Bool {
        if let event,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        return loginItemEnabled && systemUptime < 180
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
            hosting.preferredContentSize = NSSize(width: 1160, height: 760)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
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
            window.minSize = NSSize(width: 980, height: 640)
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
        // If the user has opted into a persistent Dock icon, keep the
        // .regular activation policy on window close. Otherwise drop back to
        // .accessory: hides the Dock icon, app keeps running via the menu
        // bar item only.
        if (UserDefaults.standard.object(forKey: SettingsKeys.showInDock) as? Bool ?? true) { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// We're a menu-bar-resident app — closing any window (main, break overlay,
    /// session-end sheet) must never terminate the process. The menu bar item
    /// is the canonical "running" indicator. Without this returning false a
    /// stray break-overlay close was quitting the app on Tahoe.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
