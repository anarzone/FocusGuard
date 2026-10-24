import AppKit
import SwiftUI

/// Surfaces the calm full-screen break screen when a break starts. Unlike
/// `BlockOverlayController` (the distraction block), this window can be
/// hidden: closing it just hides the screen; the break timer keeps running
/// and shows in the menu bar, which stays visible above it.
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
    /// The session the break follows, if one just ended; set by AppState.
    var finishedSessionProvider: (() -> FinishedSession?)?

    func present(breakManager: BreakManager) {
        guard !isPresenting else { return }
        isPresenting = true

        guard let screen = NSScreen.main else { return }

        let view = BreakOverlayView(
            breakManager: breakManager,
            finished: finishedSessionProvider?(),
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

        // Everything but the menu bar, so the break's timer stays in sight.
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: screen.visibleFrame.maxY - screen.frame.minY)
        let host = NSHostingController(rootView: view)
        let window = MomentWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        // Critical: stop AppKit from auto-deallocating this window when it
        // closes. Otherwise close() (called from a button inside the SwiftUI
        // view) tears down the host controller that's still mid-action.
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    /// Hides the overlay window without ending the break. Defers the actual
    /// orderOut to the next runloop turn so the SwiftUI button closure that
    /// triggered this can finish unwinding before its hosting view is torn
    /// down — calling close() synchronously from inside a button action was
    /// destabilising.
    func dismiss() {
        let win = window
        window = nil
        isPresenting = false
        DispatchQueue.main.async {
            win?.orderOut(nil)
        }
    }
}
