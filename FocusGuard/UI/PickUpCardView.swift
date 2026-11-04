import AppKit
import SwiftUI

/// Pick up's card on the island: what happened, what you were doing, the
/// places, and the way back. It's the one card that can list places.
struct PickUpCardView: View {
    let card: PickUpCard
    @Bindable var coordinator: PickUpCoordinator
    /// The ⌃⌥R chip on the main button; nil with the shortcut off.
    var shortcut: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 16, weight: .bold))
                    .kerning(-0.16)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(card.sub)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(IslandStyle.bodyOpacity))
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
                    .foregroundStyle(.white.opacity(IslandStyle.bodyOpacity))
                    .tint(Theme.focusFill)
            }
            buttons
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pick up where you left off"))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(card.kind == .failed ? IslandTone.attention.color : IslandTone.calm.color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
                .accessibilityHidden(true)
            Text(card.top)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(IslandStyle.secondaryOpacity))
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            IslandCloseButton { coordinator.close() }
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
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(IslandStyle.secondaryOpacity))
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
                        .fill(picked ? Color.white.opacity(0.12) : .clear))
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
        let title = coordinator.menuPrimaryTitle() ?? card.primary
        let press: () -> Void = { Task { await coordinator.pressPrimary() } }
        let close: () -> Void = { coordinator.close() }
        return IslandButtonRow(primary: title.map { ($0, press) }, secondary: (card.secondary, close)) {
            if let shortcut, card.kind != .failed {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.1)))
                    .accessibilityHidden(true)
            }
        }
    }
}
