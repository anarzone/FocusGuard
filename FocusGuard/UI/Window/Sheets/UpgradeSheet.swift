import SwiftUI

/// Pro's prices. Placeholders: no payment provider is chosen yet, so
/// nothing can be bought and the buy button says so.
enum ProPricing {
    static let yearly = "$39"
    static let yearlyPerMonth = "$3.25"
    static let monthly = "$4.99"
    static let yearlySaving = "Save 35%"
    /// Flip once a payment provider is wired up.
    static let canBuy = false
}

/// What Pro adds, and the way in: the 14-day trial while it's unused,
/// buying once it is (coming soon), or a licence key.
struct UpgradeSheet: View {
    /// What brought the user here; turning the trial on counts as turning
    /// this on.
    let feature: ProFeature?
    /// Switches to another sheet (the licence key).
    let switchTo: (WindowSheet) -> Void
    var entitlements: Entitlements = .shared

    @Environment(\.dismiss) private var dismiss
    @State private var yearly = true
    @State private var showComingSoon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            features
            if entitlements.plan == .pro {
                Text("You have FocusGuard Pro. Thank you.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.focusTint))
            } else {
                plans
                action
            }
            footer
        }
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 22, trailing: 28))
        .frame(width: 620)
        .background(Theme.windowBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AppGlyph(kind: .focusguard, size: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("FocusGuard").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    ProBadge()
                }
                Text(FeatureFlags.proAI
                     ? "Block for real, and let FocusGuard write up your week."
                     : "Block for real, keep every week, and set as many limits as you like.")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.44)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.bodyText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.control))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    private var features: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 22, alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: 14) {
            ForEach(UpgradeFeature.shown, id: \.title) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.focus)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.focusTint))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                            if item.comingLater { ComingLaterBadge() }
                        }
                        Text(item.body)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var plans: some View {
        HStack(spacing: 10) {
            planOption(picked: yearly, title: "Yearly · \(ProPricing.yearly)",
                       detail: "\(ProPricing.yearlyPerMonth) a month, billed yearly",
                       tag: ProPricing.yearlySaving) { yearly = true }
            planOption(picked: !yearly, title: "Monthly · \(ProPricing.monthly)", detail: "Cancel any time", tag: nil) {
                yearly = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan")
    }

    private func planOption(picked: Bool, title: String, detail: String, tag: String?,
                            action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(picked ? Theme.focus : Theme.lockedStroke, lineWidth: picked ? 5.5 : 1.5)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 4)
                if let tag {
                    Text(tag)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.focusFill))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(shape.fill(picked ? Theme.focus.opacity(0.07) : Theme.windowCard))
            .overlay(shape.strokeBorder(picked ? Theme.focus : Theme.hairline, lineWidth: picked ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder
    private var action: some View {
        VStack(spacing: 8) {
            if entitlements.canStartTrial {
                Button("Start the \(Plan.trialDays)-day free trial") {
                    entitlements.startTrialIfNeeded(for: feature ?? .blockInBrowser)
                    dismiss()
                }
                .buttonStyle(.capsule(.primary, height: 40, fullWidth: true))
                Text("No card for the trial. FocusGuard reminds you two days before it ends.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Button("Buy Pro · \(yearly ? "\(ProPricing.yearly) a year" : "\(ProPricing.monthly) a month")") {
                    showComingSoon = true
                }
                .buttonStyle(.capsule(.primary, height: 40, fullWidth: true))
                if let days = entitlements.plan.daysLeft(at: .now) {
                    Text("Your trial has \(WindowFormat.count(days, "day")) left.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if showComingSoon {
                Text("Buying Pro opens soon. Until then, FocusGuard keeps everything you have.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bodyText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
                    .transition(.opacity)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.bottom, 12)
            HStack(spacing: 18) {
                if entitlements.plan != .pro {
                    Button("I have a licence key") { switchTo(.licence) }.buttonStyle(.textLink)
                } else {
                    Button("Close") { dismiss() }.buttonStyle(.textLink)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// One line in the upgrade sheet's list.
struct UpgradeFeature {
    let title: String
    let body: String
    let symbol: String
    var comingLater = false
    var ai = false
    /// An AI feature's own flag: it's listed once that ships.
    var shipped = true

    static let all: [UpgradeFeature] = [
        UpgradeFeature(title: "Block in the browser", body: "Pages never load. Block parts of sites, like Shorts.",
                       symbol: "macwindow"),
        UpgradeFeature(title: "Block on the whole Mac", body: "Every browser and app, private windows too.",
                       symbol: "shield", comingLater: true),
        UpgradeFeature(title: "Smart categories", body: "Sorted on this Mac, YouTube one video at a time.",
                       symbol: "sparkle", ai: true, shipped: FeatureFlags.smartCategories),
        UpgradeFeature(title: "Goals and debriefs", body: "A goal when you start, one click when you finish.",
                       symbol: "scope", ai: true, shipped: FeatureFlags.debrief),
        UpgradeFeature(title: "Work log", body: "A standup draft and a timesheet, ready to paste.",
                       symbol: "doc.text", ai: true, shipped: FeatureFlags.debrief),
        UpgradeFeature(title: "Weekly coach", body: "One pattern from your week and one thing to try, every week.",
                       symbol: "chart.bar", ai: true, shipped: FeatureFlags.coach),
        UpgradeFeature(title: "Daily limits for any site", body: "Free keeps one.", symbol: "hourglass"),
        UpgradeFeature(title: "All your history", body: "Reports for every week you have tracked.",
                       symbol: "clock.arrow.circlepath"),
    ]

    /// AI features only once they ship.
    static var shown: [UpgradeFeature] { all.filter { !$0.ai || $0.shipped } }
}
