import AppKit
import SwiftUI

/// Owns one borderless `NSWindow` per `NSScreen`. When `present(...)` is
/// called, all windows are brought up at `.screenSaver` level (above
/// the normal app layer but below the Dock alert level), filling each
/// screen edge-to-edge and joining all Spaces. Each window blurs what's
/// behind it.
///
/// A drift block has three ways out, each distinct: back to work (no pass),
/// "it's for work" (an exception for this site for the rest of the session),
/// or — if the preset allows it, after its wait — a 2-minute pass
/// (`onOverride`). A daily-limit block has back to work and, while the
/// preset allows it, a few more minutes (`onExtraTime`).

/// Why the block screen is up, and what it offers.
enum BlockReason: Equatable {
    /// A drift in a session outlasted the preset's threshold.
    case drift(OverridePolicy)
    /// A daily limit ran out.
    case dailyLimit(LimitBlock)
}

/// A daily limit that ran out, as the block screen shows it.
struct LimitBlock: Equatable {
    let limitID: UUID
    /// "youtube.com", or the app's name.
    let name: String
    /// Today's allowance in minutes, extra time included.
    let minutesToday: Int
    /// How extra time works on this preset.
    let extraTime: OverridePolicy.ExtraTime
    /// Extra-time grants left today.
    let extraLeft: Int
}

/// What the block screen shows.
struct BlockRequest: Equatable {
    let appName: String
    let bundleId: String
    /// Without "www.".
    let host: String?
    let reason: BlockReason

    init(appName: String, bundleId: String, host: String?, reason: BlockReason) {
        self.appName = appName
        self.bundleId = bundleId
        self.host = host
        self.reason = reason
    }

    init(snapshot: ActivitySnapshot, reason: BlockReason) {
        self.init(appName: snapshot.appName, bundleId: snapshot.bundleIdentifier,
                  host: Self.displayHost(snapshot.url), reason: reason)
    }

    /// "x.com" for "https://www.x.com/home".
    static func displayHost(_ url: String?) -> String? {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Boundary so the engines can be tested without spawning real NSWindows.
/// The escalation engine and the daily limits share one block screen.
@MainActor
protocol BlockOverlayPresenting: AnyObject {
    var isPresenting: Bool { get }
    /// What's on screen; nil when nothing is.
    var current: BlockRequest? { get }
    /// Called only when the user takes the 2-minute pass.
    var onOverride: (() -> Void)? { get set }
    /// Called when the user takes extra time on a daily limit, with its id.
    var onExtraTime: ((UUID) -> Void)? { get set }
    func present(_ request: BlockRequest)
    func dismiss()
}

@MainActor
class BlockOverlayController: BlockOverlayPresenting {
    private var windows: [NSWindow] = []
    private(set) var current: BlockRequest?
    var isPresenting: Bool { current != nil }

    var onOverride: (() -> Void)?
    var onExtraTime: ((UUID) -> Void)?
    /// Live session details for the screen; set by AppState.
    var contextProvider: (() -> BlockContext?)?
    /// Name of the app "Back to …" returns to, if known; set by AppState.
    var backToAppProvider: (() -> String?)?
    /// Switch back to the last focused app; set by AppState.
    var onBackToWork: (() -> Void)?
    /// "It's for work": exempt this site/app for the session; set by AppState.
    var onAllowForSession: (() -> Void)?

    func present(_ request: BlockRequest) {
        guard !isPresenting else { return }
        current = request

        let message = OverlayMessage(
            request: request,
            motivational: MotivationalMessages.random(),
            context: { [weak self] in self?.contextProvider?() },
            backToAppName: { [weak self] in self?.backToAppProvider?() },
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
            },
            onExtraTime: { [weak self] in
                guard case .dailyLimit(let limit) = request.reason else { return }
                self?.dismiss()
                self?.onExtraTime?(limit.limitID)
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
        current = nil
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
    let request: BlockRequest
    let motivational: String
    let context: () -> BlockContext?
    let backToAppName: () -> String?
    let onOverride: () -> Void
    let onBackToWork: () -> Void
    let onAllowForSession: () -> Void
    let onExtraTime: () -> Void

    var appName: String { request.appName }
    var bundleId: String { request.bundleId }
    var host: String? { request.host }
}
