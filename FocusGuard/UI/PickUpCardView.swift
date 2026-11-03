import AppKit
import SwiftUI

/// The floating card: what happened, what you were doing, the places, and
/// the way back.
struct PickUpCardView: View {
    let card: PickUpCard
    @Bindable var coordinator: PickUpCoordinator
    /// The ⌃⌥R chip on the main button; nil with the shortcut off.
    var shortcut: String?

    static let width: CGFloat = 372

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(card.sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.rows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.rows) { row($0) }
                }
            }
            if let offer = card.resumeOffer {
                Toggle(offer, isOn: $coordinator.resumeTicked)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .tint(Theme.focusFill)
            }
            buttons
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.windowCard))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pick up where you left off"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.focusFill.opacity(0.14))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                )
                .accessibilityHidden(true)
            Text(card.top)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { coordinator.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MomentPalette.tertiaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
    }

    /// App and what; on the menu's card, a row to pick.
    @ViewBuilder
    private func row(_ row: PickUpCard.Row) -> some View {
        let content = HStack(spacing: 10) {
            // The app's own icon only: a site's icon would have to be fetched.
            AppGlyph(kind: .generic, bundleId: row.place.bundleId, size: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.place.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)

        if card.kind == .menu {
            let picked = coordinator.pickedPlaceID == row.id
            Button { coordinator.pickedPlaceID = row.id } label: {
                content
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(picked ? Theme.focusFill.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -6)
            .accessibilityAddTraits(picked ? .isSelected : [])
        } else {
            content
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let title = coordinator.menuPrimaryTitle() ?? card.primary {
                Button { Task { await coordinator.pressPrimary() } } label: {
                    HStack(spacing: 8) {
                        Text(title).lineLimit(1).minimumScaleFactor(0.8)
                        if let shortcut, card.kind != .failed {
                            Text(shortcut)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.22)))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MomentButtonStyle(kind: .primary))
                .frame(maxWidth: .infinity)
            }
            Button(card.secondary) { coordinator.close() }
                .buttonStyle(MomentButtonStyle(kind: .quiet))
                .frame(maxWidth: card.primary == nil ? .infinity : nil)
        }
    }
}

// MARK: - The panel

/// Takes no keys and doesn't make FocusGuard the active app: whatever the
/// user is typing into keeps the keyboard.
private final class PickUpPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A button works on the first click, though the panel never becomes key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Puts the card at the top right of the screen in use, under the menu bar.
@MainActor
final class PickUpPanelController: PickUpPresenting {
    private var panel: NSPanel?
    private let inset = NSSize(width: 24, height: 16)

    func show(_ card: PickUpCard, coordinator: PickUpCoordinator) {
        let shortcut = PickUpSettings.isOn(PickUpSettings.shortcut) ? PickUpHotKey.label : nil
        let host = FirstClickHostingView(rootView: PickUpCardView(card: card, coordinator: coordinator, shortcut: shortcut))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        let size = host.fittingSize
        guard let screen = Self.activeScreen else { return }
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.maxX - size.width - inset.width, y: area.maxY - size.height - inset.height,
                              width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = PickUpPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        return panel
    }

    /// The screen the pointer is on: FocusGuard isn't the active app, so
    /// `NSScreen.main` can't say which one the user is looking at.
    private static var activeScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }
}
