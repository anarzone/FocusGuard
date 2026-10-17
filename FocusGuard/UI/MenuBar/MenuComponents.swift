import SwiftUI

// MARK: - Module

/// Rounded module on the menu glass. Radius 13 sits concentric inside the
/// panel's 18 with its 6pt inset. A tint turns it into a status module
/// (drift, permissions) — tinted fill plus a matching hairline.
private struct MenuModule: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tint.map { $0.opacity(0.14) } ?? Theme.module))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.45) } ?? Theme.moduleStroke, lineWidth: 0.5))
    }
}

extension View {
    func menuModule(tint: Color? = nil) -> some View {
        modifier(MenuModule(tint: tint))
    }
}

// MARK: - Buttons

/// Full-width capsule. Prominent = the one accent-filled primary action.
struct CapsuleButton: View {
    let title: String
    var prominent: Bool
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Capsule().fill(prominent ? Theme.focus : Theme.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 40pt circular control with a caption, like Control Center's platters.
struct ControlPlatter: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.control))
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Native-looking menu row: accent highlight on hover, shortcut trailing.
struct MenuItemRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

// MARK: - Now row

/// What's frontmost, and how it's classified. Dot + word, never colour alone.
struct NowRow: View {
    let snapshot: ActivitySnapshot?

    var body: some View {
        HStack(spacing: 10) {
            if let snapshot {
                AppGlyph(
                    kind: AppGlyph.kind(forBundleId: snapshot.bundleIdentifier, name: snapshot.appName),
                    bundleId: snapshot.bundleIdentifier,
                    size: 30
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(snapshot.detailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle().fill(color(snapshot.classification)).frame(width: 7, height: 7)
                    Text(label(snapshot.classification))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                AppGlyph(kind: .generic, size: 30)
                Text("Detecting…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, -2)
        .padding(.vertical, -2)
        .menuModule()
        .accessibilityElement(children: .combine)
    }

    private func color(_ c: Classification) -> Color {
        switch c {
        case .focus:       return Theme.focus
        case .neutral:     return Theme.other
        case .distraction: return Theme.distraction
        }
    }

    private func label(_ c: Classification) -> String {
        switch c {
        case .focus:       return "Focus"
        case .neutral:     return "Neutral"
        case .distraction: return "Distracting"
        }
    }
}

// MARK: - Session grid

struct SessionGridView: View {
    let grid: SessionGrid

    private var cellHeight: CGFloat { grid.cells.count > 50 ? 14 : 18 }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: SessionGrid.columns),
            spacing: 4
        ) {
            ForEach(Array(grid.cells.enumerated()), id: \.offset) { _, cell in
                cellView(cell)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func cellView(_ cell: SessionGrid.Cell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        switch cell {
        case .focus:
            shape.fill(Theme.focus).frame(height: cellHeight)
        case .drift:
            shape.fill(Theme.distraction).frame(height: cellHeight)
        case .other:
            shape.fill(Theme.other).frame(height: cellHeight)
        case .now(let c):
            let fill = c == .focus ? Theme.focus : (c == .distraction ? Theme.distraction : Theme.other)
            shape.fill(fill)
                .frame(height: cellHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(fill, lineWidth: 1.5)
                        .padding(-3)
                )
        case .future:
            shape.strokeBorder(Theme.gridFuture, lineWidth: 1).frame(height: cellHeight)
        }
    }

    private var accessibilitySummary: String {
        let m = grid.minutesPerCell
        let future = grid.cells.filter { $0 == .future }.count
        var parts = [
            "\(grid.focusCells * m) minutes focused",
            "\(grid.driftCells * m) drifted",
            "\(grid.otherCells * m) in other apps",
        ]
        if future > 0 { parts.append("\(future * m) remaining") }
        return "Session minutes: " + parts.joined(separator: ", ")
    }
}

/// Legend under the grid. Live sessions show a trailing caption; the recap
/// shows per-kind minute counts instead.
struct GridLegend: View {
    var counts: (focus: Int, drift: Int, other: Int)?
    var minutesPerCell: Int = 1
    var trailing: String?

    init(trailing: String) {
        self.trailing = trailing
    }

    init(counts: (Int, Int, Int), minutesPerCell: Int) {
        self.counts = (counts.0, counts.1, counts.2)
        self.minutesPerCell = minutesPerCell
    }

    var body: some View {
        HStack(spacing: 12) {
            swatch(Theme.focus, "Focused", counts?.focus)
            swatch(Theme.distraction, "Drifted", counts?.drift)
            swatch(Theme.other, "Other", counts?.other)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
    }

    private func swatch(_ color: Color, _ title: String, _ count: Int?) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(count.map { "\(title) \($0 * minutesPerCell)" } ?? title)
        }
    }
}
