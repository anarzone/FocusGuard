import AppKit
import SwiftUI

/// Owns the NSStatusItem and a borderless NSWindow that hosts the SwiftUI
/// menu bar UI. We use a plain NSWindow rather than NSPopover so we don't get
/// the popover tail pointing at the status item, and rather than NSPanel so we
/// avoid the activation-policy quirks NSPanel hits in accessory apps.
///
/// Dismissal: NSEvent global + local monitors close the window on any click
/// outside our content. Same pattern Ice / Bartender / Stats use.
enum MenuBarIconStyle: String, CaseIterable {
    case shield = "Shield"
    case fg     = "FG"
    case dot    = "Dot"
}

/// Polled snapshot describing what (if anything) should appear next to the
/// menu-bar icon. AppState provides this via a closure handed into init —
/// keeps the controller decoupled from session/break internals.
struct MenuBarTimer: Equatable {
    enum Kind { case session, sessionPaused, breakRunning }
    let kind: Kind
    let remainingSeconds: Int
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popoverWindow: PopoverWindow
    private let timerProvider: () -> MenuBarTimer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var sessionActive = false
    private var tickTimer: Timer?
    private var lastRenderedTimer: MenuBarTimer??   // double-optional: nil == not yet rendered

    init<Content: View>(
        timerProvider: @escaping () -> MenuBarTimer? = { nil },
        @ViewBuilder content: () -> Content
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popoverWindow = PopoverWindow(content: content())
        self.timerProvider = timerProvider
        super.init()
        configureStatusItem()
        startTicking()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor  { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
        tickTimer?.invalidate()
    }

    /// 1Hz tick to refresh the countdown label when a session or break is
    /// running. Cheap — only string-formats when the timer state actually
    /// changes (deep equality check).
    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTimerLabel() }
        }
        if let t = tickTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func refreshTimerLabel() {
        let snapshot = timerProvider()
        // Only re-apply if it's actually changed (avoids re-creating NSImage
        // every tick when nothing's running).
        if lastRenderedTimer != .some(snapshot) {
            lastRenderedTimer = .some(snapshot)
            applyIconStyle(currentIconStyle)
        }
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(toggle(_:))
        applyIconStyle(currentIconStyle)
    }

    private var currentIconStyle: MenuBarIconStyle {
        let raw = UserDefaults.standard.string(forKey: "menuBarIconStyle") ?? "Shield"
        return MenuBarIconStyle(rawValue: raw) ?? .shield
    }

    @objc private func userDefaultsChanged() {
        Task { @MainActor in applyIconStyle(currentIconStyle) }
    }

    private func applyIconStyle(_ style: MenuBarIconStyle) {
        guard let button = statusItem.button else { return }

        // When a session OR break is running, the timer label takes priority
        // over the static "● active" badge — it's strictly more informative.
        let timer = timerProvider()
        let label = label(for: timer, fallbackBadge: sessionActive ? " ●" : "")

        switch style {
        case .shield:
            let symbol = timer.map { iconSymbol(for: $0) } ?? "shield.lefthalf.filled"
            let image = NSImage(systemSymbolName: symbol,
                                accessibilityDescription: "FocusGuard")
            image?.isTemplate = true
            button.image = image
            button.title = label

        case .fg:
            button.image = nil
            button.title = "FG\(label)"

        case .dot:
            let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            let symbol = timer.map { iconSymbol(for: $0) } ?? "circle.fill"
            let image = NSImage(systemSymbolName: symbol,
                                accessibilityDescription: "FocusGuard")?
                .withSymbolConfiguration(cfg)
            image?.isTemplate = true
            button.image = image
            button.title = label
        }
    }

    /// Symbol shown when an active timer is running. Different glyph for break
    /// vs session so the user can tell at a glance even if the time is small.
    private func iconSymbol(for timer: MenuBarTimer) -> String {
        switch timer.kind {
        case .session:        return "timer"
        case .sessionPaused:  return "pause.circle"
        case .breakRunning:   return "cup.and.saucer.fill"
        }
    }

    private func label(for timer: MenuBarTimer?, fallbackBadge: String) -> String {
        guard let timer else { return fallbackBadge }
        let m = max(0, timer.remainingSeconds) / 60
        let s = max(0, timer.remainingSeconds) % 60
        return String(format: " %d:%02d", m, s)
    }

    @objc private func toggle(_ sender: Any?) {
        if popoverWindow.isVisible {
            close()
        } else {
            show()
        }
    }

    func updateBadge(active: Bool) {
        sessionActive = active
        applyIconStyle(currentIconStyle)
    }

    // MARK: - Show / close

    private func show() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        popoverWindow.recomputeContentSize()

        // Position centered under the status item button with a 6pt gap.
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenFrame = buttonWindow.convertToScreen(buttonFrameInWindow)
        let panelSize = popoverWindow.frame.size
        var origin = NSPoint(
            x: buttonScreenFrame.midX - panelSize.width / 2,
            y: buttonScreenFrame.minY - panelSize.height - 6
        )
        // Keep on-screen with an 8pt margin.
        if let screen = NSScreen.main ?? buttonWindow.screen {
            let f = screen.visibleFrame
            let margin: CGFloat = 8
            origin.x = max(f.minX + margin, min(f.maxX - panelSize.width - margin, origin.x))
            origin.y = max(f.minY + margin, origin.y)
        }
        popoverWindow.setFrameOrigin(origin)

        // Show without activating our app — the user's previous app keeps focus.
        popoverWindow.orderFrontRegardless()

        installMonitors()
    }

    private func close() {
        popoverWindow.orderOut(nil)
        teardownMonitors()
    }

    // MARK: - Click monitoring

    private func installMonitors() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self else { return event }
                // Don't close on clicks inside our popover or on the status item.
                if event.window === self.popoverWindow { return event }
                if event.window === self.statusItem.button?.window { return event }
                Task { @MainActor in self.close() }
                return event
            }
        }
    }

    private func teardownMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor  { NSEvent.removeMonitor(m); localClickMonitor  = nil }
    }
}

// MARK: - PopoverWindow

/// Borderless floating window that hosts our SwiftUI content with a translucent
/// menu-material backdrop and rounded corners. Auto-sizes to the SwiftUI tree's
/// intrinsic size on each show.
private final class PopoverWindow: NSWindow {
    private let hosting: NSHostingController<AnyView>

    init<Content: View>(content: Content) {
        self.hosting = NSHostingController(rootView: AnyView(content))
        if #available(macOS 13.0, *) {
            self.hosting.sizingOptions = [.preferredContentSize]
        }

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.titlebarAppearsTransparent = true
        self.isMovable = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.animationBehavior = .utilityWindow

        // Backdrop fills the entire window with rounded corners — no popover tail.
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        self.contentView = effect
    }

    /// Borderless windows return false by default — opt in so SwiftUI text
    /// fields inside sheets we present can take focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Re-fit the window to the SwiftUI tree's current intrinsic size.
    func recomputeContentSize() {
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            self.setContentSize(fitting)
        }
    }
}
