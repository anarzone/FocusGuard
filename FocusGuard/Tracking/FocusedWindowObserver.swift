import AppKit
import ApplicationServices

/// Announces when the frontmost app's focused window, or that window's
/// title, changes — through Accessibility notifications, and only where
/// FocusGuard is already allowed to use Accessibility (it never asks). The
/// tracker then looks again at once instead of polling titles. The title
/// itself is still read the usual way (`WindowInspector`), so what's
/// recorded doesn't change, only when it's read.
@MainActor
final class FocusedWindowObserver {
    /// Called on the main thread when the focused window or its title changes.
    var onChange: (() -> Void)?

    private var pid: pid_t?
    private var observer: AXObserver?
    private var app: AXUIElement?
    private var window: AXUIElement?
    /// The focused window's title changes are announced (or there's no
    /// window, so nothing to miss until one is focused).
    private var titleWatched = false

    /// How long an Accessibility call may wait on a busy app.
    private static let messagingTimeout: Float = 0.25

    /// Whether title changes in `pid`'s focused window are announced.
    func isObserving(_ pid: pid_t) -> Bool {
        observer != nil && self.pid == pid && titleWatched
    }

    /// Follows `pid`'s focused window from now on, and stops following the
    /// app before it. Does nothing without Accessibility access.
    func follow(_ pid: pid_t) {
        guard pid != self.pid else { return }
        stop()
        self.pid = pid
        guard AXIsProcessTrusted() else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, focusedWindowCallback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString, refcon) == .success else { return }
        AXObserverAddNotification(created, app, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        self.app = app
        watchFocusedWindow()
    }

    func stop() {
        if let observer {
            if let app {
                AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
                AXObserverRemoveNotification(observer, app, kAXMainWindowChangedNotification as CFString)
            }
            if let window { AXObserverRemoveNotification(observer, window, kAXTitleChangedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        app = nil
        window = nil
        pid = nil
        titleWatched = false
    }

    /// Moves the title watch to the window that has focus now.
    private func watchFocusedWindow() {
        guard let observer, let app else { return }
        if let window { AXObserverRemoveNotification(observer, window, kAXTitleChangedNotification as CFString) }
        window = nil
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            // No window yet: focusing one is announced.
            titleWatched = true
            return
        }
        let focused = value as! AXUIElement   // checked by type id above
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        titleWatched = AXObserverAddNotification(observer, focused, kAXTitleChangedNotification as CFString, refcon) == .success
        if titleWatched { window = focused }
    }

    fileprivate func changed(_ notification: String) {
        if notification != kAXTitleChangedNotification { watchFocusedWindow() }
        onChange?()
    }
}

/// The observer's C callback; `refcon` is the `FocusedWindowObserver`,
/// which lives as long as the tracker.
private func focusedWindowCallback(_ observer: AXObserver, _ element: AXUIElement,
                                   _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let name = notification as String
    // The run loop source is on the main run loop.
    MainActor.assumeIsolated {
        Unmanaged<FocusedWindowObserver>.fromOpaque(refcon).takeUnretainedValue().changed(name)
    }
}
