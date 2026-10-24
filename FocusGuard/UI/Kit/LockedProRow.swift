import SwiftUI

/// A Pro feature as a free user sees it: a dashed row with a PRO badge.
/// Tapping it opens one line about the feature and a trial link in place.
/// Never a popup, never a lock icon. Show it only while the feature is
/// locked, and not during a session.
struct LockedProRow: View {
    let feature: ProFeature
    let title: String
    /// What the feature does, in one line, shown once the row is tapped.
    let detail: String
    var systemImage: String?
    /// Runs once the trial has started, to turn the feature on.
    var onTrialStarted: () -> Void = {}
    /// Once the trial has been used: open the upgrade sheet. Without it the
    /// open row shows only its line.
    var onUpgrade: (() -> Void)?
    var entitlements: Entitlements = .shared

    @State private var open = false
    @ReduceMotion private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 16)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProBadge()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), Pro")
            .accessibilityHint(open ? "" : "Shows what it does")

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    link
                }
                .padding(.leading, systemImage == nil ? 0 : 26)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Theme.lockedFill))
        .overlay(shape.strokeBorder(Theme.lockedStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    @ViewBuilder private var link: some View {
        if entitlements.canStartTrial {
            Button("Try Pro free for \(Plan.trialDays) days") {
                entitlements.startTrialIfNeeded(for: feature)
                if entitlements.isUnlocked(feature) { onTrialStarted() }
            }
            .buttonStyle(.textLink)
        } else if let onUpgrade {
            Button("Get Pro", action: onUpgrade)
                .buttonStyle(.textLink)
        }
    }
}
