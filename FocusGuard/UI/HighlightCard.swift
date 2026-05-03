import SwiftUI

/// Single tile in the Reports → Highlights row. Three of these stack
/// horizontally above the hero band.
struct HighlightCard: View {
    enum Direction {
        case up, down, neutral
        var color: Color {
            switch self {
            case .up:      return Theme.focus
            case .down:    return Theme.distraction
            case .neutral: return Color.secondary
            }
        }
        var systemImage: String {
            switch self {
            case .up:      return "arrow.up.right"
            case .down:    return "arrow.down.right"
            case .neutral: return "minus"
            }
        }
    }

    let icon: String
    let title: String
    let value: String
    let caption: String
    let direction: Direction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: direction.systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(direction.color)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(direction.color)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
    }
}
