import SwiftUI

/// "PRO", shown in place next to whatever Pro adds. Never a lock icon.
struct ProBadge: View {
    var body: some View {
        PlanBadge(text: "PRO", fill: Theme.proBadge, ink: Theme.proBadgeText)
            .accessibilityLabel("Pro")
    }
}

/// "FREE", in grey, for what the free plan includes.
struct FreeBadge: View {
    var body: some View {
        PlanBadge(text: "FREE", fill: Theme.freeBadge, ink: Theme.freeBadgeText)
            .accessibilityLabel("Free")
    }
}

private struct PlanBadge: View {
    let text: String
    let fill: Color
    let ink: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill))
            .fixedSize()
    }
}
