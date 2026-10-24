import SwiftUI

/// Work log, a Pro feature built on session goals and debriefs. Until
/// those ship (`FeatureFlags.proAI`), everyone sees what it will be: a
/// faded preview with a card about it.
struct WorkLogPage: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Work log", subtitle: "Part of FocusGuard Pro") { EmptyView() }
            ZStack(alignment: .top) {
                WorkLogSkeleton()
                    .opacity(0.45)
                    .blur(radius: 1.5)
                    .saturation(0.6)
                    .accessibilityHidden(true)
                card.padding(.top, 36)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.bottom, 20)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint))
                ProBadge()
                if !FeatureFlags.proAI { ComingLaterBadge() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Your week, written up for you")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.44)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Give a session a goal when it starts and say how it went when it ends. FocusGuard turns that into a work log, a standup draft and a timesheet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                point("Goals and debriefs", "Done, partly or not, in one click when a session ends.")
                point("Standup draft", "Done, next and blocked, ready to paste into Slack.")
                point("Timesheet", "Focused hours per project and day, exported as CSV.")
            }
            VStack(spacing: 8) {
                if FeatureFlags.proAI && entitlements.canStartTrial {
                    Button("Try Pro free for \(Plan.trialDays) days") {
                        entitlements.startTrialIfNeeded(for: .workLog)
                    }
                    .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
                } else {
                    Text(comingNote)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.bodyText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
                }
                Button("See everything in Pro") { openSheet(.upgrade(.workLog)) }
                    .buttonStyle(.textLink)
                    .frame(height: 32)
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 28, leading: 30, bottom: 24, trailing: 30))
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
        .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.18), radius: 30, y: 24)
    }

    private var comingNote: String {
        entitlements.isUnlocked(.workLog)
            ? "The work log arrives in a coming update. It's included in your Pro."
            : "The work log arrives in a coming update, as part of Pro."
    }

    private func point(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.focusFill))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Coming later", for Pro parts that aren't built yet.
struct ComingLaterBadge: View {
    var body: some View {
        Text("Coming later")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.freeBadgeText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.freeBadge))
            .fixedSize()
    }
}

/// The faded shapes of a work log behind the card.
private struct WorkLogSkeleton: View {
    var body: some View {
        WindowSplitRow(weights: [1.5, 1]) {
            WindowCard(padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Thursday").font(.system(size: 13, weight: .bold))
                    ForEach(0..<3, id: \.self) { i in entry(width: [220, 180, 240][i], strong: i != 1) }
                    Text("Wednesday").font(.system(size: 13, weight: .bold)).padding(.top, 8)
                    entry(width: 200, strong: true)
                }
            }
            VStack(spacing: 12) {
                WindowCard { Color.clear }.frame(height: 120)
                WindowCard { Color.clear }.frame(height: 180)
                WindowCard { Color.clear }
            }
        }
    }

    private func entry(width: CGFloat, strong: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Theme.secondaryText.opacity(0.35)).frame(width: 80, height: 10)
                    Capsule().fill(Theme.track).frame(width: 64, height: 8)
                }
                .frame(width: 112, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(maxWidth: width).frame(height: 11)
                        Capsule().fill(strong ? Theme.focus : Theme.focus.opacity(0.3)).frame(width: 52, height: 18)
                    }
                    Capsule().fill(Theme.track).frame(height: 8)
                }
            }
        }
    }
}
