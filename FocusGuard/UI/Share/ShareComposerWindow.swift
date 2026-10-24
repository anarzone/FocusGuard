import AppKit
import SwiftUI

extension Notification.Name {
    /// Opens the share composer. `object`: a `Date` in the week to share
    /// (Reports passes the start of the week it shows); nil means this week.
    static let openShareComposer = Notification.Name("FocusGuard.openShareComposer")
}

/// The share composer's window, opened by `.openShareComposer`.
@MainActor
final class ShareComposerWindow {
    static let shared = ShareComposerWindow()

    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private weak var appState: AppState?

    /// Starts listening for `.openShareComposer`. Called once at launch.
    func observe(_ appState: AppState) {
        self.appState = appState
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .openShareComposer, object: nil, queue: .main) { note in
            let week = note.object as? Date
            Task { @MainActor in ShareComposerWindow.shared.show(weekOf: week ?? .now) }
        }
    }

    func show(weekOf date: Date) {
        guard let appState else { return }
        let week = FocusWeek.build(weekOf: date, context: appState.container.mainContext)
        let hosting = NSHostingController(rootView: ShareComposerView(week: week))
        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hosting
            window.title = "Share your focus week"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1000, height: 660))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
