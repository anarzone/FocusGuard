import SwiftUI

/// Reports › Week, at the top: this week's note from the weekly coach, in
/// three columns (what last week showed, what to try, how last week's
/// experiment went). Free users see a dashed row that starts the trial.
struct WindowCoachCard: View {
    var coach: WeeklyCoach = .shared
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet

    var body: some View {
        Group {
            if entitlements.isUnlocked(.coach) {
                card
            } else {
                locked
            }
        }
        .task { await coach.refresh() }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                        .accessibilityHidden(true)
                    Text("Weekly coach")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    ProBadge()
                }
                Text(coach.note.map { "Last week · \(CoachWords.range($0.about))" } ?? "A note each week")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Worked out on this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(width: 168, alignment: .leading)

            if let note = coach.note {
                WindowSplitRow(weights: [1, 1, 1], spacing: 16) {
                    column(1, "Last week") {
                        Text(note.headline)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let point = note.points.first { line(point.sentence) }
                    }
                    column(2, "Try this week") {
                        if note.experiment != nil {
                            CoachTryCard(coach: coach, note: note, compact: true)
                        } else {
                            line("Nothing to try this week: no change FocusGuard can make stood out.")
                        }
                    }
                    if let trial = coach.lastResult {
                        column(3, "Last week's experiment") {
                            let result = CoachWords.result(trial, underHeading: true)
                            Text(result.lead)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            line(result.rest.trimmingCharacters(in: .whitespaces))
                            if coach.canKeepLastResult {
                                Button("Keep it on") { coach.keepLastResult() }.buttonStyle(.textLink)
                            }
                        }
                    } else {
                        column(3, "Also last week") {
                            if note.points.count > 1 {
                                line(note.points[1].sentence)
                            } else {
                                line("Focused \(WindowFormat.hm(note.stats.focused)) at a \(Int((note.stats.rate * 100).rounded()))% focus rate.")
                            }
                        }
                    }
                }
            } else {
                Text(coach.isMakingNote ? "Looking at last week…" : CoachWords.waiting)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Theme.windowCard))
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    private func column<Content: View>(_ number: Int, _ title: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.proBadgeText)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.proBadge))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.bodyText)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var locked: some View {
        HStack(spacing: 10) {
            ProBadge()
            Text("Weekly coach: one pattern from your own week, and one experiment FocusGuard sets up for you.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if entitlements.canStartTrial {
                Button("Try Pro free") {
                    entitlements.startTrialIfNeeded(for: .coach)
                    Task { await coach.refresh() }
                }
                .buttonStyle(.textLink)
            } else {
                Button("See Pro") { openSheet(.upgrade(.coach)) }.buttonStyle(.textLink)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.lockedFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.lockedStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }
}
