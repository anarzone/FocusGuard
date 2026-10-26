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

    /// One line, so Reports fits the window: last week's main pattern and
    /// this week's experiment. The menu's Weekly coach pane has the rest
    /// (the other points, why, last week's experiment).
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 12) {
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
            .fixedSize()
            summary
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(details)
            Spacer(minLength: 8)
            if let note = coach.note, let experiment = note.experiment {
                choice(experiment, week: note.week).fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(shape.fill(Theme.windowCard))
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    /// "Sunday drifted most. Try this week: a 50-minute daily limit on youtube.com."
    private var summary: Text {
        guard let note = coach.note else {
            return Text(coach.isMakingNote ? "Looking at last week…" : CoachWords.waiting).foregroundColor(Theme.bodyText)
        }
        let lead = Text(note.headline).fontWeight(.semibold).foregroundColor(Theme.primaryText)
        guard let experiment = note.experiment else { return lead }
        return lead + Text(" Try this week: \(experiment.title()).").foregroundColor(Theme.bodyText)
    }

    /// The whole note, on hover.
    private var details: String {
        guard let note = coach.note else { return "" }
        return ([note.headline] + note.points.map(\.sentence) + [note.why].compactMap { $0 }).joined(separator: "\n")
    }

    @ViewBuilder private func choice(_ experiment: CoachExperiment, week: DateInterval) -> some View {
        switch coach.state.choice {
        case .open:
            HStack(spacing: 6) {
                Button("Try it this week") { coach.tryIt() }.buttonStyle(.capsule(.primary, height: 26))
                Button("Not now") { coach.notNow() }.buttonStyle(.capsule(.secondary, height: 26))
            }
        case .trying:
            HStack(spacing: 8) {
                Text(CoachWords.until(week)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .help(experiment.effect())
                Button("Undo") { coach.reconsider() }.buttonStyle(.textLink)
            }
        case .dismissed:
            HStack(spacing: 8) {
                Text("Skipped for this week.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                Button("Undo") { coach.reconsider() }.buttonStyle(.textLink)
            }
        }
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
