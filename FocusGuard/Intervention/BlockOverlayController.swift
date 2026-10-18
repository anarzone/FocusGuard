import AppKit
import SwiftUI

/// Owns one borderless `NSWindow` per `NSScreen`. When `present(...)` is
/// called, all windows are brought up at `.screenSaver` level (above
/// the normal app layer but below the Dock alert level), filling each
/// screen edge-to-edge and joining all Spaces. Each window blurs what's
/// behind it.
///
/// Three ways out, each distinct: back to work (no pass), "it's for work"
/// (an exception for this site for the rest of the session), or — after a
/// short countdown — a 2-minute pass (`onOverride`).

/// Boundary so EscalationEngine can be tested without spawning real NSWindows.
@MainActor
protocol BlockOverlayPresenting: AnyObject {
    var isPresenting: Bool { get }
    /// Called only when the user takes the 2-minute pass.
    var onOverride: (() -> Void)? { get set }
    func present(distractionAppName: String, bundleId: String, urlHost: String?, overrideSeconds: Int)
    func dismiss()
}

@MainActor
class BlockOverlayController: BlockOverlayPresenting {
    private var windows: [NSWindow] = []
    private(set) var isPresenting = false

    var onOverride: (() -> Void)?
    /// Live session details for the screen; set by AppState.
    var contextProvider: (() -> BlockContext?)?
    /// Switch back to the last focused app; set by AppState.
    var onBackToWork: (() -> Void)?
    /// "It's for work": exempt this site/app for the session; set by AppState.
    var onAllowForSession: (() -> Void)?

    func present(distractionAppName: String, bundleId: String, urlHost: String?, overrideSeconds: Int) {
        guard !isPresenting else { return }
        isPresenting = true

        let message = OverlayMessage(
            appName: distractionAppName,
            bundleId: bundleId,
            host: urlHost.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 },
            motivational: MotivationalMessages.random(),
            overrideSeconds: overrideSeconds,
            context: { [weak self] in self?.contextProvider?() },
            onOverride: { [weak self] in
                self?.dismiss()
                self?.onOverride?()
            },
            onBackToWork: { [weak self] in
                self?.dismiss()
                self?.onBackToWork?()
            },
            onAllowForSession: { [weak self] in
                self?.dismiss()
                self?.onAllowForSession?()
            }
        )

        for screen in NSScreen.screens {
            let window = makeWindow(for: screen, content: message)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Takes the screen down. Doesn't grant a pass: only the "Let me
    /// through" button does that, via `onOverride`.
    func dismiss() {
        guard isPresenting else { return }
        let closing = windows
        windows.removeAll()
        isPresenting = false
        // Let the button action that triggered this finish unwinding first.
        DispatchQueue.main.async {
            for window in closing {
                window.orderOut(nil)
                window.close()
            }
        }
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
        window.appearance = NSAppearance(named: .darkAqua)

        // Blur whatever was on screen, then the SwiftUI content on top.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: BlockOverlayView(message: content))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)

        window.contentView = blur
        window.setFrame(screen.frame, display: true)
        return window
    }
}

// MARK: - Message payload

struct OverlayMessage {
    let appName: String
    let bundleId: String
    let host: String?
    let motivational: String
    let overrideSeconds: Int
    let context: () -> BlockContext?
    let onOverride: () -> Void
    let onBackToWork: () -> Void
    let onAllowForSession: () -> Void
}
