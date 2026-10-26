import SwiftUI

/// The weekly coach beside the menu: last week's one pattern, one
/// experiment to try this week, how last week's went, and the tiles.
/// (`CoachPane` in ProPanes.swift is the old placeholder, no longer shown.)
struct WeeklyCoachPane: View {
    var coach: WeeklyCoach = .shared
    var entitlements: Entitlements = .shared
    let close: () -> Void
    var seeWeek: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                PaneTitle(title: "Weekly coach", close: close) { ProBadge() }
                if entitlements.isUnlocked(.coach), let note = coach.note {
                    Text("Last week · \(CoachWords.range(note.about))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            if !entitlements.isUnlocked(.coach) {
                LockedProRow(feature: .coach, title: "Weekly coach", detail: CoachWords.pitch, systemImage: "sparkles",
                             onTrialStarted: { Task { await coach.refresh() } })
            } else if let note = coach.note {
                Text(note.headline)
                    .font(.system(size: 16, weight: .semibold))
                    .kerning(-0.16)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                points(note)
                if note.experiment != nil { CoachTryCard(coach: coach, note: note) }
                tiles(note.stats)
                if !coach.state.kept.isEmpty { kept }
            } else if coach.isMakingNote {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at last week…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                .paneCard()
            } else {
                empty
            }

            Spacer(minLength: 0)
            HStack {
                Text("Worked out on this Mac").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("See the week ›", action: seeWeek).buttonStyle(.textLink)
            }
            .padding(.horizontal, 2)
        }
        .task { await coach.refresh() }
    }

    // MARK: - Points

    private func points(_ note: CoachNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(note.points, id: \.self) { point in
                CoachPointRow(point: point)
            }
            if let trial = coach.lastResult {
                VStack(alignment: .leading, spacing: 4) {
                    CoachPointRow(point: CoachWords.result(trial))
                    if coach.canKeepLastResult {
                        Button("Keep it on") { coach.keepLastResult() }
                            .buttonStyle(.textLink)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Tiles

    private func tiles(_ stats: CoachWeekStats) -> some View {
        HStack(spacing: 6) {
            CoachTile(label: "Focused", value: formatDuration(stats.focused),
                      detail: stats.focusedBefore.map { CoachWords.timeChange(stats.focused - $0) } ?? "first week")
            CoachTile(label: "Focus rate", value: "\(Int((stats.rate * 100).rounded()))%",
                      detail: stats.rateBefore.map { CoachWords.pointsChange(from: $0, to: stats.rate) } ?? "first week")
            CoachTile(label: "Goal met", value: "\(stats.goalDays) of \(stats.goalOf)",
                      detail: stats.weekendsCount ? "days" : "weekdays")
        }
    }

    // MARK: - Kept

    private var kept: some View {
        VStack(alignment: .leading, spacing: 6) {
            paneHeading("Kept on", note: "from earlier weeks")
            ForEach(coach.state.kept) { trial in
                HStack(spacing: 8) {
                    Text(trial.experiment.title())
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Stop") { coach.stop(trial) }
                        .buttonStyle(.textLink)
                        .accessibilityLabel("Stop \(trial.experiment.shortName())")
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text("No note yet").font(.system(size: 14, weight: .semibold))
            Text(CoachWords.waiting)
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
}

/// "Try this week": the experiment, why, and what the user chose.
struct CoachTryCard: View {
    let coach: WeeklyCoach
    let note: CoachNote
    /// The window puts the buttons in a smaller space.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            if !compact {
                Text("Try this week").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.link)
            }
            if let experiment = note.experiment {
                VStack(alignment: .leading, spacing: 3) {
                    Text(experiment.title())
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    if let why = note.why {
                        Text(why)
                            .font(.system(size: 12))
                            .foregroundStyle(compact ? Theme.bodyText : Theme.secondaryText)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                choice(experiment)
            }
            if let problem = coach.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(TryCardBackground(compact: compact))
    }

    @ViewBuilder private func choice(_ experiment: CoachExperiment) -> some View {
        switch coach.state.choice {
        case .open:
            HStack(spacing: 6) {
                Button("Try it this week") { coach.tryIt() }
                    .buttonStyle(.capsule(.primary, height: compact ? 26 : 28))
                Button("Not now") { coach.notNow() }
                    .buttonStyle(.capsule(.secondary, height: compact ? 26 : 28))
            }
        case .trying:
            VStack(alignment: .leading, spacing: 4) {
                Text("\(experiment.effect()) \(CoachWords.until(note.week))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Undo") { coach.reconsider() }.buttonStyle(.textLink)
                    if coach.state.running?.kept == true {
                        Text("Stays on after this week").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    } else {
                        Button("Keep it after this week") { coach.keepRunning() }.buttonStyle(.textLink)
                    }
                }
            }
        case .dismissed:
            HStack(spacing: 8) {
                Text("Skipped for this week.").font(.system(size: 12)).foregroundStyle(Theme.primaryText.opacity(0.85))
                Button("Undo") { coach.reconsider() }.buttonStyle(.textLink)
            }
        }
    }
}

private struct TryCardBackground: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content
        } else {
            content
                .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.focus.opacity(0.28), lineWidth: 0.5))
        }
    }
}

/// A dot and a line with a bold lead.
struct CoachPointRow: View {
    let point: CoachPoint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            (Text(point.lead).fontWeight(.semibold) + Text(point.rest))
                .font(.system(size: 12))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch point.tone {
        case .focus: return Theme.focus
        case .drift: return Theme.distraction
        case .other: return Theme.other
        }
    }
}

private struct CoachTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            Text(value).font(.system(size: 16, weight: .semibold).monospacedDigit()).kerning(-0.3).lineLimit(1)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// The coach's words that the menu and the window share.
enum CoachWords {
    static let pitch = "Each week, one pattern from your own week and one experiment FocusGuard can set up for you."
    static let waiting = "After your first full week, the coach finds one pattern in it and suggests one thing to try."

    /// "19–25 Oct".
    static func range(_ week: DateInterval) -> String {
        (week.start..<week.end.addingTimeInterval(-1)).formatted(.interval.day().month(.abbreviated))
    }

    /// "On until Sunday."
    static func until(_ week: DateInterval) -> String {
        "On until \(week.end.addingTimeInterval(-1).formatted(.dateTime.weekday(.wide)))."
    }

    /// "Last week's experiment, shorter evening sessions: +9 pts." Under a
    /// heading that already says so, just "Shorter evening sessions: +9 pts."
    static func result(_ trial: CoachTrial, underHeading: Bool = false) -> CoachPoint {
        let name = underHeading ? CoachDraft.capitalized(trial.experiment.shortName())
            : "Last week's experiment, \(trial.experiment.shortName())"
        let rest = trial.kept ? " It stays on." : " It's off again."
        guard let change = trial.change else {
            return CoachPoint(lead: "\(name):", rest: " too little data to tell." + rest, tone: .other)
        }
        return CoachPoint(lead: "\(name): \(change).", rest: rest, tone: trial.improved ? .focus : .other)
    }

    /// What the Insights row says about the coach.
    @MainActor static func rowDetail(_ coach: WeeklyCoach) -> String {
        guard let note = coach.note else { return "One pattern, and one thing to try" }
        if coach.state.choice == .trying, let experiment = note.experiment {
            return "Trying \(experiment.shortName()) this week"
        }
        return note.experiment != nil && coach.state.choice == .open
            ? "\(range(note.about)) · one thing to try" : note.headline
    }

    /// "+1h 44m", "−20m".
    static func timeChange(_ seconds: TimeInterval) -> String {
        (seconds >= 0 ? "+" : "−") + formatDuration(abs(seconds))
    }

    /// "+4 pts".
    static func pointsChange(from before: Double, to after: Double) -> String {
        CoachMetric.points(from: before, to: after)
    }
}
