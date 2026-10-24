import SwiftUI

/// A category as a coloured dot plus a dark label. Orange never carries
/// text: on light surfaces it's under 3.5:1, too faint for small type.
struct CategoryChip: View {
    let classification: Classification

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.dot(classification))
                .frame(width: 6, height: 6)
            Text(categoryName(classification))
                .font(.system(size: 11))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.chip))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// The dot's colour for each category.
    static func dot(_ classification: Classification) -> Color {
        switch classification {
        case .focus:       return Theme.focus
        case .neutral:     return Theme.neutral
        case .distraction: return Theme.distraction
        }
    }
}
