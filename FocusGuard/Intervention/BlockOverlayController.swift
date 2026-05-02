import AppKit
import SwiftUI

/// Owns one borderless `NSWindow` per `NSScreen`. When `present(...)` is
/// called, all windows are brought up at `.screenSaver` level (above
/// the normal app layer but below the Dock alert level), filling each
/// screen edge-to-edge and joining all Spaces.
///
/// Dismissal: only happens via the override button in the SwiftUI content,
/// which calls back to `dismiss()`.
/// Boundary so EscalationEngine can be tested without spawning real NSWindows.
@MainActor
protocol BlockOverlayPresenting: AnyObject {
    var isPresenting: Bool { get }
    var onOverride: (() -> Void)? { get set }
    func present(distractionAppName: String, urlHost: String?, overrideSeconds: Int)
    func dismiss()
}

@MainActor
class BlockOverlayController: BlockOverlayPresenting {
    private var windows: [NSWindow] = []
    private(set) var isPresenting = false

    var onOverride: (() -> Void)?

    func present(distractionAppName: String, urlHost: String?, overrideSeconds: Int) {
        guard !isPresenting else { return }
        isPresenting = true

        let messageBundle = OverlayMessage(
            appName: distractionAppName,
            host: urlHost,
            motivational: MotivationalMessages.random(),
            overrideSeconds: overrideSeconds,
            onOverride: { [weak self] in self?.dismiss() },
            onPostpone: { [weak self] in self?.dismiss() }
        )

        for screen in NSScreen.screens {
            let window = makeWindow(for: screen, content: messageBundle)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        isPresenting = false
        onOverride?()
    }

    // MARK: - Window factory

    private func makeWindow(for screen: NSScreen, content: OverlayMessage) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = false

        let view = BlockOverlayView(message: content)
        let host = NSHostingController(rootView: view)
        host.view.frame = screen.frame
        window.contentViewController = host

        window.setFrame(screen.frame, display: true)
        return window
    }
}

// MARK: - Message payload

struct OverlayMessage {
    let appName: String
    let host: String?
    let motivational: String
    let overrideSeconds: Int
    let onOverride: () -> Void
    let onPostpone: () -> Void
}
