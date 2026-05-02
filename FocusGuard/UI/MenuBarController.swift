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

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popoverWindow: PopoverWindow
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var sessionActive = false

    init<Content: View>(@ViewBuilder content: () -> Content) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popoverWindow = PopoverWindow(content: content())
        super.init()
        configureStatusItem()

        // Re-apply the icon whenever the user switches style in Settings.
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
        let badge = sessionActive ? " ●" : ""

        switch style {
        case .shield:
            let image = NSImage(systemSymbolName: "shield.lefthalf.filled",
                                accessibilityDescription: "FocusGuard")
            image?.isTemplate = true
            button.image = image
            button.title = badge

        case .fg:
            button.image = nil
            button.title = "FG\(badge)"

        case .dot:
            let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            let image = NSImage(systemSymbolName: "circle.fill",
                                accessibilityDescription: "FocusGuard")?
                .withSymbolConfiguration(cfg)
            image?.isTemplate = true
            button.image = image
            button.title = badge
        }
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
