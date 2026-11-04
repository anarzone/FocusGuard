import AppKit
import SwiftUI

/// Takes no keys and doesn't make FocusGuard the active app: whatever the
/// user is typing into keeps the keyboard.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// The room for the shadow reaches up under the menu bar: AppKit would push the whole window down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A button works on the first click, though the panel never becomes key.
private final class IslandHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    /// Where the island is on screen, in screen coordinates.
    static func shape(of size: CGSize, at spot: Spot) -> NSRect {
        NSRect(x: spot.centerX - size.width / 2, y: spot.top - size.height, width: size.width, height: size.height)
    }

    /// Whether a point is on the island itself. Its shadow and the corners
    /// outside its curve aren't: clicks there belong to what's underneath.
    static func isOver(_ shape: NSRect, radius: CGFloat, point: NSPoint) -> Bool {
        guard shape.contains(point) else { return false }
        let dx = max(shape.minX + radius - point.x, point.x - (shape.maxX - radius), 0)
        let dy = max(shape.minY + radius - point.y, point.y - (shape.maxY - radius), 0)
        return dx * dx + dy * dy <= radius * radius
    }

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
/// after it has, so the spring runs inside it. It's bigger than the island to
/// hold the shadow, so it only takes the mouse while the pointer is on the
/// island itself: everywhere else a click reaches what's underneath.
@MainActor
final class IslandPanelController: IslandSurface {
    private let model = IslandModel()
    private weak var island: IslandController?
    private var panel: NSPanel?
    private var spot = IslandPlacement.Spot(centerX: 0, top: 0)
    private var settling: Task<Void, Never>?
    private var isHovering = false
    private var pointerMonitors: [Any] = []

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
        // Left out of screen captures, where macOS goes along with that.
        panel.sharingType = IslandSettings.isQuietWhileSharing() ? .none : .readOnly
        panel.orderFrontRegardless()
        isHovering = false
        watchPointer()
        if wasUp {
            move(to: target, on: panel)
        } else {
            place(for: target, on: panel)
            // The first frame is the small shape, so the spring has somewhere to start.
            DispatchQueue.main.async { [weak self] in
                self?.model.phase = target
                self?.settlePointer()
            }
        }
        settlePointer()
    }

    func update(_ moment: IslandMoment, open: Bool, now: Date) {
        if model.moment != moment {
            prepare(moment, now: now)
            model.moment = moment
        }
        model.now = now
        if let panel { move(to: open ? .card : .pill, on: panel) }
        settlePointer()
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
        stopWatchingPointer()
        panel?.ignoresMouseEvents = true
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
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: - The pointer

    /// The panel ignores the mouse most of the time, so it can't watch for
    /// itself: other apps' moves come to the first monitor, its own to the second.
    /// Neither needs a permission, and they only run while the island is up.
    private func watchPointer() {
        guard pointerMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { pointerMonitors.append(local) }
    }

    private func stopWatchingPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
    }

    private var isPointerOverIsland: Bool {
        guard model.phase != .gone else { return false }
        return IslandPlacement.isOver(IslandPlacement.shape(of: model.size(for: model.phase), at: spot),
                                      radius: model.phase == .card ? IslandStyle.cardRadius : IslandStyle.pillRadius,
                                      point: NSEvent.mouseLocation)
    }

    private func pointerMoved() {
        let inside = isPointerOverIsland
        panel?.ignoresMouseEvents = !inside
        guard inside != isHovering else { return }
        isHovering = inside
        island?.hover(inside)
    }

    /// The island moved or changed shape, perhaps under a pointer standing
    /// still. It may take the click now, but only a move opens it.
    private func settlePointer() {
        let inside = isPointerOverIsland
        panel?.ignoresMouseEvents = !inside
        guard isHovering, !inside else { return }
        isHovering = false
        DispatchQueue.main.async { [weak self] in self?.island?.hover(false) }
    }
}
