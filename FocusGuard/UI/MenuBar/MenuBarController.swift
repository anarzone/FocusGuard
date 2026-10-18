import AppKit
import SwiftUI

/// Owns the NSStatusItem and a borderless NSWindow that hosts the SwiftUI
/// rich menu. We use a plain NSWindow rather than NSPopover so we don't get
/// the popover tail pointing at the status item, and rather than NSPanel so we
/// avoid the activation-policy quirks NSPanel hits in accessory apps.
///
/// The status item is a template glyph whose shape carries the state (see
/// `StatusGlyphState`), plus — during a session or break — the minutes left
/// as a calm "24m" label (see `StatusLabel`), never a ticking mm:ss.
///
/// Dismissal: NSEvent global + local monitors close the window on any click
/// outside our content. Same pattern Ice / Bartender / Stats use.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popoverWindow: PopoverWindow
    private let glyphProvider: () -> StatusGlyphState
    private let labelProvider: () -> StatusLabel?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var tickTimer: Timer?
    private var animationTimer: Timer?
    private var renderedGlyph: StatusGlyphState?
    /// When the menu last closed — so the mouse-up of a click that closed it
    /// doesn't immediately reopen it.
    private var lastClosedAt: Date?
    private var renderedLabel: StatusLabel??   // double optional: nil = not rendered yet

    init<Content: View>(
        glyphProvider: @escaping () -> StatusGlyphState,
        labelProvider: @escaping () -> StatusLabel? = { nil },
        @ViewBuilder content: () -> Content
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popoverWindow = PopoverWindow(content: content())
        self.glyphProvider = glyphProvider
        self.labelProvider = labelProvider
        super.init()
        configureStatusItem()
        startTicking()
    }

    deinit {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor  { NSEvent.removeMonitor(m) }
        tickTimer?.invalidate()
        animationTimer?.invalidate()
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
        let label = labelProvider()
        guard state != renderedGlyph || renderedLabel != .some(label),
              let button = statusItem.button else { return }
        if state != renderedGlyph {
            let frames = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? [] : GlyphAnimation.frames(from: renderedGlyph, to: state)
            play(frames, for: state)
        }
        renderedGlyph = state
        renderedLabel = .some(label)

        if let label {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + label.text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: label.dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ])
            button.setAccessibilityLabel("\(state.accessibilityLabel), \(label.accessibilityText)")
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.setAccessibilityLabel(state.accessibilityLabel)
        }
    }

    /// Plays a one-off glyph animation, ending on the still glyph. A new
    /// state change mid-animation cancels it and starts from there.
    private func play(_ frames: [GlyphStyle], for state: StatusGlyphState) {
        animationTimer?.invalidate()
        animationTimer = nil
        guard let button = statusItem.button else { return }
        guard !frames.isEmpty else {
            button.image = StatusGlyph.templateImage(for: state)
            return
        }
        var index = 0
        let timer = Timer(timeInterval: 1 / GlyphAnimation.framesPerSecond, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, let button = self.statusItem.button else { timer.invalidate(); return }
                if index < frames.count {
                    button.image = StatusGlyph.templateImage(for: state, style: frames[index])
                    index += 1
                } else {
                    button.image = StatusGlyph.templateImage(for: state)
                    timer.invalidate()
                    if self.animationTimer === timer { self.animationTimer = nil }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
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
        } else if let closed = lastClosedAt, Date().timeIntervalSince(closed) < 0.3 {
            // This click already closed the menu on mouse-down (a click
            // monitor got there first); don't reopen it on mouse-up.
            return
        } else {
            show()
        }
    }

    /// Whether a click landed on the status item. Checked by screen position
    /// because `event.window` isn't reliably the status bar's window — e.g.
    /// when FocusGuard isn't the active app — and treating the icon as
    /// "outside" made a second click close the menu and instantly reopen it.
    private func isOnStatusItem(_ event: NSEvent) -> Bool {
        if let window = event.window, window === statusItem.button?.window { return true }
        guard let button = statusItem.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
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
        let screenFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
        popoverWindow.anchor = (preferredX: origin.x, screen: screenFrame)
        if let f = screenFrame {
            origin.x = PopoverWindow.clampedX(origin.x, width: panelSize.width, in: f)
            origin.y = max(f.minY + 8, origin.y)
        }
        popoverWindow.setFrameOrigin(origin)

        // Show without activating our app — the user's previous app keeps focus.
        popoverWindow.orderFrontRegardless()
        statusItem.button?.highlight(true)

        installMonitors()
    }

    func close() {
        if popoverWindow.isVisible { lastClosedAt = Date() }
        popoverWindow.orderOut(nil)
        statusItem.button?.highlight(false)
        teardownMonitors()
    }

    // MARK: - Click monitoring

    private func installMonitors() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                Task { @MainActor in
                    guard let self, !self.isOnStatusItem(event) else { return }
                    self.close()
                }
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
                if self.isOnStatusItem(event) { return event }
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
    /// Where the panel wants its left edge (under the status item) and the
    /// screen it must stay on. Side panes widen it; near the right edge of
    /// the screen it grows leftward instead of running off.
    var anchor: (preferredX: CGFloat, screen: NSRect?)?

    static func clampedX(_ x: CGFloat, width: CGFloat, in screen: NSRect, margin: CGFloat = 8) -> CGFloat {
        max(screen.minX + margin, min(screen.maxX - width - margin, x))
    }
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
    /// open, and side panes change its width; the top edge stays pinned.
    private func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let top = frame.maxY
        var x = frame.minX
        if let anchor, let screen = anchor.screen {
            x = Self.clampedX(anchor.preferredX, width: size.width, in: screen)
        }
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
                 display: isVisible, animate: false)
    }
}
