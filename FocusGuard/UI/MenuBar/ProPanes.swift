import SwiftUI

// Pro AI in the menu: the session goal, the debrief after a session, the
// weekly coach and smart category suggestions. Everything here shows only
// while `FeatureFlags.proAI` is on, and nothing fills the data yet, so the
// views fall back to an empty state until the AI behind them exists.

// MARK: - Data

/// What the debrief says about a finished session.
struct SessionDebrief: Equatable {
    enum Verdict: Equatable { case done, partly, notYet }

    struct Item: Equatable, Identifiable {
        var id: String { app }
        let app: String
        /// "SessionNamer.swift and its 13 tests"
        let what: String
        let seconds: TimeInterval
    }

    let sessionLabel: String
    let start: Date
    let end: Date
    let goal: String?
    var verdict: Verdict
    /// "PR #49 was merged on github.com at 19:41."
    let evidence: String?
    let workedOn: [Item]
    /// "x.com · 3 min" and when it happened.
    let drift: String?
    let driftDetail: String?
    /// One thing to try next time, and why.
    let tip: String?
    let tipDetail: String?
    let standup: String?
}

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

/// The goal typed in before a session, for the debrief to check.
enum SessionGoal {
    static let key = "pro.sessionGoal"
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

/// "What's this session for?" on the ready screen: the goal the debrief checks.
struct SessionGoalField: View {
    @Binding var goal: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("What's this session for?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                Spacer()
                Text("Optional")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                ProBadge()
            }
            TextField("e.g. Ship the session-names PR", text: $goal)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.segment.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
                .onTapGesture { NSApp.activate(ignoringOtherApps: true) }
        }
        .menuModule(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
    }
}

/// The goal above the ring while the session runs.
struct GoalLine: View {
    let goal: String

    var body: some View {
        HStack(spacing: 8) {
            ZoneGlyph(color: Theme.focus)
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
            Text(goal)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProBadge()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Goal: \(goal)")
    }
}

// MARK: - Debrief

struct DebriefPane: View {
    let debrief: SessionDebrief?
    let close: () -> Void

    @State private var verdict: SessionDebrief.Verdict?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneTitle(title: "Debrief", close: close) { ProBadge() }
            if let debrief {
                Text("\(debrief.sessionLabel) · \(menuClock(debrief.start))–\(menuClock(debrief.end))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                if let goal = debrief.goal { goalCard(goal, debrief) }
                if !debrief.workedOn.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        paneHeading("What you worked on")
                        ForEach(debrief.workedOn) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                (Text(item.app).fontWeight(.semibold) + Text(" · \(item.what)"))
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(formatDuration(item.seconds))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    .paneCard()
                }
                HStack(alignment: .top, spacing: 6) {
                    if let drift = debrief.drift { note("Where you drifted", drift, debrief.driftDetail) }
                    if let tip = debrief.tip { note("Next time", tip, debrief.tipDetail) }
                }
                if copied, let standup = debrief.standup {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Copied for standup", systemImage: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.link)
                        Text(standup).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .paneCard()
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let standup = debrief.standup {
                        Button("Copy for standup") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(standup, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.capsule(.secondary, fullWidth: true))
                    }
                }
            } else {
                emptyState("No debrief yet", "After your next session, this shows what you worked on, where you drifted and one thing to try.")
                Spacer(minLength: 0)
            }
            Text("Worked out on this Mac")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func goalCard(_ goal: String, _ debrief: SessionDebrief) -> some View {
        let current = verdict ?? debrief.verdict
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Goal").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(verdictText(current))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current == .done ? Theme.link : Theme.primaryText)
            }
            Text(goal).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let evidence = debrief.evidence {
                Text(evidence).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Not quite?").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                PillButton(title: "Partly", height: 22) { verdict = .partly }
                PillButton(title: "Not yet", height: 22) { verdict = .notYet }
            }
        }
        .paneCard()
    }

    private func verdictText(_ verdict: SessionDebrief.Verdict) -> String {
        switch verdict {
        case .done:   return "Looks done"
        case .partly: return "Partly done"
        case .notYet: return "Not yet"
        }
    }

    private func note(_ title: String, _ text: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            Text(text).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .paneCard()
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
