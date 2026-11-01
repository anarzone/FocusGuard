import AppKit
import SwiftUI

/// Whether FocusGuard's menu and main window can be seen. The clocks and
/// reloads that only they show run only while they can: a closed menu, or
/// a window that's closed, minimised, on another Space or covered by other
/// windows, does no work in the background. Their views stay alive between
/// showings, so without this they'd keep ticking all day.
@MainActor
@Observable
final class OnScreen {
    static let shared = OnScreen()

    /// The menu under the status item is open.
    private(set) var menu = false
    /// Some part of the main window is on screen.
    private(set) var window = false
    /// When each last came into view. Their clocks are never older than
    /// this, so they show fresh numbers before their first tick lands.
    private(set) var menuShownAt: Date = .distantPast
    private(set) var windowShownAt: Date = .distantPast

    var any: Bool { menu || window }

    func setMenu(_ open: Bool, now: Date = .now) {
        if open, !menu { menuShownAt = now }
        if menu != open { menu = open }
    }

    func setWindow(_ visible: Bool, now: Date = .now) {
        if visible, !window { windowShownAt = now }
        if window != visible { window = visible }
    }

    /// Visible means ordered in, not minimised and not wholly covered.
    nonisolated static func isVisible(orderedIn: Bool, miniaturized: Bool,
                                      occlusion: NSWindow.OcclusionState) -> Bool {
        orderedIn && !miniaturized && occlusion.contains(.visible)
    }

    /// Follows the main window: shown, closed, minimised, covered, uncovered.
    func follow(_ window: NSWindow) {
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self, weak window] note in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                // Still ordered in while it closes.
                let closing = note.name == NSWindow.willCloseNotification
                self.setWindow(!closing && Self.isVisible(orderedIn: window.isVisible, miniaturized: window.isMiniaturized,
                                                          occlusion: window.occlusionState))
            }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: window, queue: .main, using: update)
        }
    }
}

private struct OnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the window or menu this view is in can be seen (`OnScreen`).
    /// True outside them, so other hosts keep their clocks running.
    var isOnScreen: Bool {
        get { self[OnScreenKey.self] }
        set { self[OnScreenKey.self] = newValue }
    }
}

private struct RepeatingKey<ID: Equatable>: Equatable {
    let isOn: Bool
    let id: ID
}

/// See `View.repeating`.
private struct Repeating<ID: Equatable>: ViewModifier {
    let interval: Duration?
    let isOn: Bool
    let id: ID
    let action: @MainActor () async -> Void
    /// When `action` last ran, and for which id.
    @State private var lastRun: (id: ID, at: ContinuousClock.Instant)?

    func body(content: Content) -> some View {
        content.task(id: RepeatingKey(isOn: isOn, id: id)) {
            guard isOn else { return }
            if let last = lastRun, last.id == id {
                // Back on screen: what it shows is as fresh as the interval
                // allows already, so wait out the rest of it (or, run once,
                // don't run again).
                guard let interval else { return }
                let due = last.at + interval
                if due > .now {
                    try? await Task.sleep(until: due, tolerance: interval / 10, clock: .continuous)
                }
            }
            while !Task.isCancelled {
                await action()
                lastRun = (id, .now)
                guard let interval else { return }
                // A little slack lets macOS run it alongside other work.
                try? await Task.sleep(for: interval, tolerance: interval / 10)
            }
        }
    }
}

extension View {
    /// Runs `action` now and then every `interval` (once, without one) while
    /// `isOn`. It stops when `isOn` turns false or the view goes; when `isOn`
    /// comes back it runs again once the interval since the last run is up,
    /// and a new `id` runs it straight away.
    func repeating<ID: Equatable>(every interval: Duration?, while isOn: Bool, id: ID,
                                  _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(Repeating(interval: interval, isOn: isOn, id: id, action: action))
    }
}
