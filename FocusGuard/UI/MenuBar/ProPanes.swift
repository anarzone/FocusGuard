import SwiftUI

// Pro AI in the menu: the session goal, the debrief after a session, the
// weekly coach and smart category suggestions. Everything here shows only
// while `FeatureFlags.proAI` is on, and nothing fills the data yet, so the
// views fall back to an empty state until the AI behind them exists.

// MARK: - Data

/// The weekly coach's note on the week before.
struct WeeklyCoachNote: Equatable {
    let weekLabel: String
    let headline: String
    let points: [String]
    let tryThis: String?
}

/// A category the smart suggestions would give an app or site.
struct SmartSuggestion: Equatable, Identifiable {
    var id: String { host ?? bundleId }
    let name: String
    let bundleId: String
    let host: String?
    let suggested: Classification
    /// Why, in a line: "Open in 9 of your sessions, next to Xcode."
    let reason: String
}

// MARK: - Rows

/// A Pro surface in the menu column: an indigo-tinted row that opens a pane.
struct ProRow: View {
    let title: String
    let detail: String
    var systemImage = "sparkles"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.focusTint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProBadge()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.focusTint.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.focus.opacity(0.28), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Weekly coach

struct CoachPane: View {
    let note: WeeklyCoachNote?
    let close: () -> Void
    var seeWeek: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneTitle(title: "Weekly coach", close: close) { ProBadge() }
            if let note {
                Text(note.weekLabel).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                Takeaway(text: note.headline)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(note.points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.focus).frame(width: 6, height: 6)
                            Text(point).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .paneCard()
                if let tryThis = note.tryThis {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try this week").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        Text(tryThis).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                    .paneCard()
                }
            } else {
                emptyState("No note yet", "After your first full week, the coach sums up what worked and suggests one thing to try.")
            }
            Spacer(minLength: 0)
            HStack {
                Text("Worked out on this Mac").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("See the week ›", action: seeWeek).buttonStyle(.textLink)
            }
        }
    }
}

// MARK: - Smart suggestions

/// The Apps & sites pane's second tab: categories worked out from how each
/// app is used. Nothing changes until it's accepted.
struct SmartSuggestionsView: View {
    var suggestions: [SmartSuggestion] = []
    var entitlements: Entitlements = .shared
    var onAccept: (SmartSuggestion) -> Void = { _ in }

    var body: some View {
        if !entitlements.isUnlocked(.smartCategories) {
            LockedProRow(feature: .smartCategories, title: "Smart suggestions",
                         detail: "Categories worked out on this Mac from how you use each app. Nothing changes until you accept.",
                         systemImage: "sparkles")
        } else if suggestions.isEmpty {
            emptyState("No suggestions yet", "New suggestions arrive after each week of use.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Worked out on this Mac from how you use each one. Nothing changes until you accept.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                ForEach(suggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            AppGlyph(kind: suggestion.host == nil ? AppGlyph.kind(forBundleId: suggestion.bundleId, name: suggestion.name) : .generic,
                                     bundleId: suggestion.host == nil ? suggestion.bundleId : nil, host: suggestion.host, size: 22)
                            Text(suggestion.name).font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CategoryChip(classification: suggestion.suggested)
                        }
                        Text(suggestion.reason).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        Button("Make it \(categoryName(suggestion.suggested))") { onAccept(suggestion) }
                            .buttonStyle(.capsule(.secondary, height: 24))
                    }
                    .paneCard()
                }
            }
        }
    }
}

private func emptyState(_ title: String, _ detail: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: "sparkles")
            .font(.system(size: 18))
            .foregroundStyle(Theme.focus)
            .accessibilityHidden(true)
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
    .padding(.horizontal, 14)
    .paneCard(padding: EdgeInsets())
}
