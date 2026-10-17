import AppKit
import SwiftUI

/// Owns the NSStatusItem and a borderless NSWindow that hosts the SwiftUI
/// rich menu. We use a plain NSWindow rather than NSPopover so we don't get
/// the popover tail pointing at the status item, and rather than NSPanel so we
/// avoid the activation-policy quirks NSPanel hits in accessory apps.
///
/// The status item is a template glyph only — state is carried by shape
/// (see `StatusGlyphState`), never by a countdown in the menu bar.
///
/// Dismissal: NSEvent global + local monitors close the window on any click
/// outside our content. Same pattern Ice / Bartender / Stats use.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popoverWindow: PopoverWindow
    private let glyphProvider: () -> StatusGlyphState
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var tickTimer: Timer?
    private var renderedGlyph: StatusGlyphState?

    init<Content: View>(
        glyphProvider: @escaping () -> StatusGlyphState,
        @ViewBuilder content: () -> Content
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popoverWindow = PopoverWindow(content: content())
        self.glyphProvider = glyphProvider
        super.init()
        configureStatusItem()
        startTicking()
    }

    deinit {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor  { NSEvent.removeMonitor(m) }
        tickTimer?.invalidate()
    }

    /// 1 Hz poll of the glyph state. Only redraws when the state changes —
    /// focusing progress is quantised, so that's a handful of times a session.
    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGlyph() }
        }
        if let t = tickTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func refreshGlyph() {
        let state = glyphProvider()
        guard state != renderedGlyph, let button = statusItem.button else { return }
        renderedGlyph = state
        button.image = StatusGlyph.templateImage(for: state)
        button.setAccessibilityLabel(state.accessibilityLabel)
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggle(_:))
        refreshGlyph()
    }

    @objc private func toggle(_ sender: Any?) {
        if popoverWindow.isVisible {
            close()
        } else {
            show()
        }
    }

    // MARK: - Show / close

    private func show() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        popoverWindow.recomputeContentSize()

        // Menus hang from the item's leading edge, just under the menu bar.
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenFrame = buttonWindow.convertToScreen(buttonFrameInWindow)
        let panelSize = popoverWindow.frame.size
        var origin = NSPoint(
            x: buttonScreenFrame.minX - 6,
            y: buttonScreenFrame.minY - panelSize.height - 5
        )
        // Keep on-screen with an 8pt margin.
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let f = screen.visibleFrame
            let margin: CGFloat = 8
            origin.x = max(f.minX + margin, min(f.maxX - panelSize.width - margin, origin.x))
            origin.y = max(f.minY + margin, origin.y)
        }
        popoverWindow.setFrameOrigin(origin)

        // Show without activating our app — the user's previous app keeps focus.
        popoverWindow.orderFrontRegardless()
        statusItem.button?.highlight(true)

        installMonitors()
    }

    func close() {
        popoverWindow.orderOut(nil)
        statusItem.button?.highlight(false)
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
                // Don't close on clicks inside our popover, its sheets, or on the status item.
                if event.window === self.popoverWindow || event.window?.sheetParent === self.popoverWindow {
                    return event
                }
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

/// Borderless floating window hosting the SwiftUI menu on Liquid Glass
/// (regular variant, as menus and popovers use) with an 18pt radius, falling
/// back to the menu material before macOS 26. Follows the SwiftUI tree's size
/// while open, keeping its top edge pinned under the menu bar.
private final class PopoverWindow: NSWindow {
    static let cornerRadius: CGFloat = 18
    private let hosting: NSHostingController<AnyView>

    init<Content: View>(content: Content) {
        self.hosting = NSHostingController(rootView: AnyView(EmptyView()))
        self.hosting.sizingOptions = [.preferredContentSize]

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        hosting.rootView = AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.fit(to: size)
                }
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

        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = hosting.view
            self.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            ])
            self.contentView = effect
        }
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

    /// Phase changes (start, drift, end) change the menu's height while it's
    /// open; grow or shrink downward from the pinned top edge.
    private func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height),
                 display: isVisible)
    }
}
