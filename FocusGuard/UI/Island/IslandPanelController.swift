import AppKit
import SwiftUI

/// Takes no keys and doesn't make FocusGuard the active app: whatever the
/// user is typing into keeps the keyboard.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A button works on the first click, though the panel never becomes key.
/// The pointer's comings and goings are watched here because the panel is
/// never active: the area covers the island, not its shadow.
private final class IslandHostingView: NSHostingView<IslandView> {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: islandRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    /// Where the island is in this view, once the window has its size.
    var islandRect: NSRect {
        let margin = IslandStyle.margin
        return NSRect(x: margin.leading, y: isFlipped ? margin.top : margin.bottom,
                      width: max(0, bounds.width - margin.leading - margin.trailing),
                      height: max(0, bounds.height - margin.top - margin.bottom))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}

/// The spot under the status item. Worked out away from AppKit so it can be tested.
enum IslandPlacement {
    struct Screen: Equatable {
        let frame: NSRect
        let visible: NSRect
        /// The notch's height; 0 without one.
        let safeTop: CGFloat
    }

    struct Spot: Equatable {
        let centerX: CGFloat
        let top: CGFloat
    }

    static let gap: CGFloat = 6
    static let sideMargin: CGFloat = 8

    /// Centred under the status item and kept on its screen, or at the top
    /// right of the screen in use when the item's place isn't known. Always
    /// below the menu bar and the notch, even with the menu bar hidden.
    static func spot(anchor: NSRect?, screens: [Screen], pointer: NSPoint) -> Spot? {
        let half = IslandStyle.cardWidth / 2
        let under = anchor.flatMap { rect -> (Screen, NSRect)? in
            let middle = NSPoint(x: rect.midX, y: rect.midY)
            return rect.width > 0 ? screens.first { $0.frame.contains(middle) }.map { ($0, rect) } : nil
        }
        guard let screen = under?.0 ?? screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first else { return nil }
        let area = screen.visible
        let left = area.minX + half + sideMargin, right = area.maxX - half - sideMargin
        let centerX = under.map { min(max($0.1.midX, left), right) } ?? right
        return Spot(centerX: centerX, top: min(area.maxY, screen.frame.maxY - screen.safeTop) - gap)
    }
}

/// The one window: grows at once when the island is about to open, and shrinks
/// after it has, so the spring runs inside it.
@MainActor
final class IslandPanelController: IslandSurface {
    private let model = IslandModel()
    private weak var island: IslandController?
    private var panel: NSPanel?
    private var host: IslandHostingView?
    private var spot = IslandPlacement.Spot(centerX: 0, top: 0)
    private var settling: Task<Void, Never>?
    private var leaving: Task<Void, Never>?
    private var isHovering = false

    func attach(_ island: IslandController) {
        self.island = island
        model.onPress = { [weak island] in island?.press($0) }
        model.onClose = { [weak self, weak island] in
            if self?.model.moment?.kind == .pickUp {
                island?.pickUpCoordinator?.close()
            } else {
                island?.closeCurrent()
            }
        }
        model.onOpen = { [weak island] in island?.openByHand() }
    }

    func show(_ moment: IslandMoment, open: Bool, now: Date) {
        settling?.cancel()
        let wasUp = model.phase != .gone
        prepare(moment, now: now)
        model.moment = moment
        model.now = now
        model.motion = .choose(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let target: IslandModel.Phase = open ? .card : .pill
        let panel = self.panel ?? makePanel()
        panel.orderFrontRegardless()
        isHovering = false
        if wasUp {
            move(to: target, on: panel)
        } else {
            place(for: target, on: panel)
            // The first frame is the small shape, so the spring has somewhere to start.
            DispatchQueue.main.async { [weak self] in self?.model.phase = target }
        }
    }

    func update(_ moment: IslandMoment, open: Bool, now: Date) {
        if model.moment != moment {
            prepare(moment, now: now)
            model.moment = moment
        }
        model.now = now
        settlePointer()
        if let panel { move(to: open ? .card : .pill, on: panel) }
    }

    /// Grows the window before the island opens, and shrinks it once the island has.
    private func move(to target: IslandModel.Phase, on panel: NSPanel) {
        if target == model.phase {
            if target == .card { place(for: .card, on: panel) }
            return
        }
        settling?.cancel()
        if target == .card {
            place(for: .card, on: panel)
            model.phase = .card
        } else {
            model.phase = .pill
            settling = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.model.phase == .pill else { return }
                self.place(for: .pill, on: panel)
            }
        }
    }

    func hide() {
        settling?.cancel()
        isHovering = false
        model.phase = .gone
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            self.panel?.orderOut(nil)
            self.model.moment = nil
        }
    }

    func announce(_ text: String, urgent: Bool) {
        guard let panel else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: (urgent ? NSAccessibilityPriorityLevel.high : .medium).rawValue
        ])
    }

    // MARK: - Place and size

    private func prepare(_ moment: IslandMoment, now: Date) {
        model.coordinator = moment.pickUp == nil ? nil : island?.pickUpCoordinator
        model.shortcut = moment.pickUp != nil && PickUpSettings.isOn(PickUpSettings.shortcut) ? PickUpHotKey.label : nil
        model.cardHeight = IslandModel.fittedHeight(of: moment, now: now, coordinator: model.coordinator, shortcut: model.shortcut)
        let screens = NSScreen.screens.map {
            IslandPlacement.Screen(frame: $0.frame, visible: $0.visibleFrame, safeTop: $0.safeAreaInsets.top)
        }
        if let found = IslandPlacement.spot(anchor: island?.statusItemFrame(), screens: screens, pointer: NSEvent.mouseLocation) {
            spot = found
        }
    }

    private func place(for phase: IslandModel.Phase, on panel: NSPanel) {
        let size = model.size(for: phase)
        let margin = IslandStyle.margin
        let width = size.width + margin.leading + margin.trailing
        let height = size.height + margin.top + margin.bottom
        panel.setFrame(NSRect(x: spot.centerX - width / 2, y: spot.top + margin.top - height, width: width, height: height), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Its shadow is drawn with the shape: a window's wouldn't follow the spring.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.onEnter = { [weak self] in self?.pointerEntered() }
        host.onExit = { [weak self] in self?.pointerExited() }
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    // MARK: - The pointer

    private func pointerEntered() {
        leaving?.cancel()
        guard !isHovering else { return }
        isHovering = true
        island?.hover(true)
    }

    /// A moment's patience: the window changing size under the pointer also says it left.
    private func pointerExited() {
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.settlePointer()
        }
    }

    /// Catches a leave that came while the window was changing size.
    private func settlePointer() {
        guard isHovering, let host, let panel else { return }
        let rect = panel.convertToScreen(host.convert(host.islandRect, to: nil))
        guard !rect.contains(NSEvent.mouseLocation) else { return }
        isHovering = false
        DispatchQueue.main.async { [weak self] in self?.island?.hover(false) }
    }
}
