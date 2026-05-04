import AppKit
import SwiftUI

/// Surfaces the calm full-screen "Time to rest" overlay when a break starts.
/// Unlike `BlockOverlayController` (the punitive distraction block), this
/// window is freely dismissable — closing it just hides the overlay; the
/// break timer keeps running and shows up in the menu bar.
@MainActor
final class BreakOverlayController {
    private var window: NSWindow?
    private(set) var isPresenting = false

    /// Hooks set by AppState so the buttons drive the BreakManager.
    var onSkip: (() -> Void)?
    var onExtend: ((Int) -> Void)?
    /// Called when the user closes the overlay (without skipping). The break
    /// timer keeps running.
    var onClose: (() -> Void)?

    func present(breakManager: BreakManager) {
        guard !isPresenting else { return }
        isPresenting = true

        guard let screen = NSScreen.main else { return }

        let view = BreakOverlayView(
            breakManager: breakManager,
            onSkip: { [weak self] in
                self?.onSkip?()
                self?.dismiss()
            },
            onExtend: { [weak self] minutes in
                self?.onExtend?(minutes)
            },
            onClose: { [weak self] in
                self?.onClose?()
                self?.dismiss()
            }
        )

        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentViewController = host
        window.setFrame(screen.visibleFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    /// Hides the overlay window without ending the break. Called by the close
    /// button and by skip / completion paths.
    func dismiss() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        isPresenting = false
    }
}
