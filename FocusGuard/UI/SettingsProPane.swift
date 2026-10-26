import SwiftUI

/// Pro & licence: the plan (Free, the trial or Pro), the way in, what
/// happens when a trial ends, and Free against Pro.
struct SettingsProPane: View {
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet
    @State private var yearly = true

    var body: some View {
        SettingsColumns {
            planCard
            if case .trial = entitlements.plan { afterTrial }
            #if DEBUG
            SettingsSection("Debug") {
                SettingsRow(title: "Pretend plan") { PlanDebugPicker(entitlements: entitlements).labelsHidden().fixedSize() }
            }
            #endif
        } right: {
            comparison
        }
    }

    // MARK: - Plan

    private var planCard: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                planRing
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(planTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                            .accessibilityAddTraits(.isHeader)
                        if entitlements.plan == .free { FreeBadge() } else { ProBadge() }
                    }
                    Text(planDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if entitlements.plan != .pro {
                HStack(spacing: 8) {
                    priceOption(picked: yearly, title: "Yearly", price: ProPricing.yearly, note: "\(ProPricing.yearlyPerMonth) a month") { yearly = true }
                    priceOption(picked: !yearly, title: "Monthly", price: ProPricing.monthly, note: "cancel any time") { yearly = false }
                }
                VStack(spacing: 8) {
                    if entitlements.canStartTrial {
                        Button("Try Pro free for \(Plan.trialDays) days") { openSheet(.upgrade(nil)) }
                            .buttonStyle(.capsule(.primary, height: 34, fullWidth: true))
                    } else {
                        Button("Buy Pro, \(yearly ? "yearly" : "monthly")") { openSheet(.upgrade(nil)) }
                            .buttonStyle(.capsule(.primary, height: 34, fullWidth: true))
                    }
                    Button("Enter a licence key…") { openSheet(.licence) }.buttonStyle(.textLink)
                }
            } else {
                Button("Remove the licence from this Mac") { entitlements.removeLicence() }
                    .buttonStyle(.textLink)
            }
        }
        .padding(16)
        .background(shape.fill(Theme.windowCard))
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    @ViewBuilder
    private var planRing: some View {
        let days = entitlements.plan.daysLeft(at: .now)
        ZStack {
            Circle().inset(by: 4).stroke(Theme.goalTrack, lineWidth: 8)
            if let days {
                WindowArc(start: 0, end: min(0.9999, Double(days) / Double(Plan.trialDays)))
                    .inset(4)
                    .stroke(Theme.focus, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                VStack(spacing: 0) {
                    Text("\(days)").font(.system(size: 18, weight: .bold).monospacedDigit())
                    Text(days == 1 ? "day" : "days").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                }
                .foregroundStyle(Theme.primaryText)
            } else {
                Image(systemName: entitlements.plan == .pro ? "checkmark" : "shield")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.focus)
            }
        }
        .frame(width: 60, height: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days.map { "Trial: \($0) of \(Plan.trialDays) days left" } ?? planTitle)
    }

    private var planTitle: String {
        switch entitlements.plan {
        case .free: return "Free"
        case .trial: return "Pro trial"
        case .pro: return "FocusGuard Pro"
        }
    }

    private var planDetail: String {
        switch entitlements.plan {
        case .free:
            return entitlements.canStartTrial
                ? "Try Pro for \(Plan.trialDays) days, no card needed. It starts when you turn on a Pro feature."
                : "Your trial has ended. Everything you tracked is still here."
        case .trial(let endsAt):
            return "Ends on \(endsAt.formatted(.dateTime.day().month(.wide))). No card needed, nothing renews on its own."
        case .pro:
            return "Thank you. Everything in Pro is on."
        }
    }

    private func priceOption(picked: Bool, title: String, price: String, note: String,
                             action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Text(price).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(picked ? Theme.focus.opacity(0.07) : Theme.inset))
            .overlay(shape.strokeBorder(picked ? Theme.focus : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    // MARK: - After the trial

    private var afterTrial: some View {
        SettingsSection("If the trial ends without Pro") {
            VStack(alignment: .leading, spacing: 8) {
                line("Everything you tracked stays.")
                line("Blocking goes back to Pause the tab.")
                line("Daily limits you set stay; adding more needs Pro.")
                line("Reports show the last \(Plan.freeHistoryDays) days. Older history waits for Pro.")
            }
            .padding(14)
        }
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.neutral).frame(width: 5, height: 5)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.bodyText).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Free and Pro

    private var comparison: some View {
        SettingsSection("Free and Pro") {
            HStack {
                Text("Feature").frame(maxWidth: .infinity, alignment: .leading)
                FreeBadge().frame(width: 72)
                ProBadge().frame(width: 72)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 14)
            .frame(height: 34)
            ForEach(PlanComparison.rows, id: \.name) { row in
                SettingsDivider()
                HStack {
                    Text(row.name).font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(row.free).frame(width: 72)
                    cell(row.pro).frame(width: 72)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func cell(_ value: PlanComparison.Cell) -> some View {
        switch value {
        case .yes:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.focus)
                .accessibilityLabel("Included")
        case .no:
            Text("–").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText).accessibilityLabel("Not included")
        case .text(let text):
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
        }
    }
}

/// The Free and Pro table. AI rows join once they ship.
enum PlanComparison {
    enum Cell: Equatable {
        case yes, no
        case text(String)
    }

    struct Row {
        let name: String
        let free: Cell
        let pro: Cell
        var ai = false
        /// Its own `FeatureFlags` switch, for AI features that ship one by one.
        var shipped = true
    }

    static let all: [Row] = [
        Row(name: "Tracking, sessions, rings and breaks", free: .yes, pro: .yes),
        Row(name: "Reports and highlights", free: .text("\(Plan.freeHistoryDays) days"), pro: .text("All")),
        Row(name: "Pause the tab", free: .yes, pro: .yes),
        Row(name: "Block in the browser, parts of sites too", free: .no, pro: .yes),
        Row(name: "Block on the whole Mac", free: .no, pro: .text("Later")),
        Row(name: "Smart categories, YouTube per video", free: .no, pro: .yes, ai: true, shipped: FeatureFlags.smartCategories),
        Row(name: "Session goals, debriefs and work log", free: .no, pro: .yes, ai: true, shipped: FeatureFlags.debrief),
        Row(name: "Standup draft and timesheet", free: .no, pro: .yes, ai: true, shipped: FeatureFlags.debrief),
        Row(name: "Weekly coach", free: .no, pro: .yes, ai: true, shipped: FeatureFlags.coach),
        Row(name: "Daily site limits", free: .text("\(Plan.freeDailyLimits)"), pro: .text("Any")),
    ]

    static var rows: [Row] { all.filter(\.shipped) }
}
