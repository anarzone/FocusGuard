import AppKit
import SwiftUI

/// Owns one borderless window per `NSScreen`. When `present(...)` is
/// called, all windows are brought up at `.screenSaver` level (above
/// the normal app layer but below the Dock alert level), filling each
/// screen edge-to-edge and joining all Spaces. Each window blurs what's
/// behind it, in the system's light or dark appearance.
///
/// A drift block has these ways out, each distinct: back to work (no pass),
/// "it's for work" (an exception for this site for the rest of the session),
/// a 2-minute pass if the preset allows one (`onOverride`), and on Strict,
/// ending the session early. Each waits as long as the preset says. A
/// daily-limit block has back to work, starting a session, and while the
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
    /// The screen came up; set by AppState (pauses the tab behind it).
    var onPresent: ((BlockRequest) -> Void)?
    /// The screen let the site through: a pass, "It's for work" or extra
    /// time; set by AppState (puts the paused tab back).
    var onLetThrough: (() -> Void)?
    /// Whether the site's tab behind the screen is paused; set by AppState.
    var tabPausedProvider: (() -> Bool)?
    /// Whether "Start 50 minutes of focus" can start one now (no session
    /// or break running); set by AppState.
    var canStartSessionProvider: (() -> Bool)?
    /// Today's numbers for a daily limit; set by AppState.
    var limitStatusProvider: ((UUID) -> LimitStatus?)?
    /// The usual session length, for "Start 50 minutes of focus"; set by AppState.
    var sessionMinutesProvider: (() -> Int)?
    /// "End the session early…", once confirmed (Strict); set by AppState.
    var onEndSession: (() -> Void)?
    /// "Start 50 minutes of focus" on a daily limit; set by AppState.
    var onStartFocus: ((Int) -> Void)?
    /// "Edit limit" / "Change for tomorrow"; set by AppState.
    var onEditLimits: (() -> Void)?

    func present(_ request: BlockRequest) {
        guard !isPresenting else { return }
        current = request

        let message = OverlayMessage(
            request: request,
            shownAt: .now,
            motivational: MotivationalMessages.random(),
            context: { [weak self] in self?.contextProvider?() },
            backToAppName: { [weak self] in self?.backToAppProvider?() },
            isTabPaused: { [weak self] in self?.tabPausedProvider?() ?? false },
            canStartSession: { [weak self] in self?.canStartSessionProvider?() ?? false },
            limitStatus: { [weak self] in
                guard case .dailyLimit(let limit) = request.reason else { return nil }
                return self?.limitStatusProvider?(limit.limitID)
            },
            sessionMinutes: { [weak self] in self?.sessionMinutesProvider?() ?? 50 },
            onOverride: { [weak self] in
                self?.dismiss()
                self?.onOverride?()
                self?.onLetThrough?()
            },
            onBackToWork: { [weak self] in
                self?.dismiss()
                self?.onBackToWork?()
            },
            onAllowForSession: { [weak self] in
                self?.dismiss()
                self?.onAllowForSession?()
                self?.onLetThrough?()
            },
            onExtraTime: { [weak self] in
                guard case .dailyLimit(let limit) = request.reason else { return }
                self?.dismiss()
                self?.onExtraTime?(limit.limitID)
                self?.onLetThrough?()
            },
            onEndSession: { [weak self] in
                self?.dismiss()
                self?.onEndSession?()
            },
            onStartFocus: { [weak self] minutes in
                self?.dismiss()
                self?.onStartFocus?(minutes)
            },
            onEditLimits: { [weak self] in
                self?.dismiss()
                self?.onEditLimits?()
            }
        )

        for screen in NSScreen.screens {
            let window = makeWindow(for: screen, content: message)
            windows.append(window)
            window.orderFrontRegardless()
        }
        // The main screen's copy takes the keys, so esc and return work there.
        let main = windows.first { $0.screen == NSScreen.main } ?? windows.first
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onPresent?(request)
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
        let window = MomentWindow(
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

        // Blur whatever was on screen, then the SwiftUI content on top.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: BlockScreen(message: content))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)

        window.contentView = blur
        window.setFrame(screen.frame, display: true)
        return window
    }
}

/// The block screen for a drift, or the daily-limit screen.
private struct BlockScreen: View {
    let message: OverlayMessage

    var body: some View {
        switch message.request.reason {
        case .drift(let policy):       BlockOverlayView(message: message, policy: policy)
        case .dailyLimit(let limit):   LimitOverlayView(message: message, limit: limit)
        }
    }
}

// MARK: - Message payload

struct OverlayMessage {
    let request: BlockRequest
    /// When the screen came up; every button's wait counts from it.
    let shownAt: Date
    let motivational: String
    let context: () -> BlockContext?
    let backToAppName: () -> String?
    let isTabPaused: () -> Bool
    let canStartSession: () -> Bool
    let limitStatus: () -> LimitStatus?
    let sessionMinutes: () -> Int
    let onOverride: () -> Void
    let onBackToWork: () -> Void
    let onAllowForSession: () -> Void
    let onExtraTime: () -> Void
    let onEndSession: () -> Void
    let onStartFocus: (Int) -> Void
    let onEditLimits: () -> Void

    var appName: String { request.appName }
    var bundleId: String { request.bundleId }
    var host: String? { request.host }
}
