import AppKit
import SwiftUI

// The session goal and the debrief after a session (Pro, behind
// `FeatureFlags.debrief`). The data and the writing are in Session/Debrief.

// MARK: - Goal

/// "What's this session for?" on the ready screen: the goal the debrief
/// checks. Empty, it offers open tasks (Pro), the calendar event on now,
/// the Git branch and the last unfinished goal, each under a heading for
/// where it came from. Return starts the session.
struct SessionGoalField: View {
    @Binding var goal: String
    var suggestions: [GoalSuggestion] = []
    /// A suggestion was picked; a task is kept to tick off after.
    var onPick: (GoalSuggestion) -> Void = { _ in }
    var onSubmit: () -> Void = {}

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
            TextField(suggestions.isEmpty ? "e.g. Ship the session-names PR" : "A task, or type your own", text: $goal)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.segment.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
                .onTapGesture { NSApp.activate(ignoringOtherApps: true) }
                .onSubmit(onSubmit)
                .onChange(of: goal) {
                    if goal.count > SessionGoal.maxLength { goal = String(goal.prefix(SessionGoal.maxLength)) }
                }
            if goal.isEmpty && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        if index == 0 || suggestions[index - 1].group != suggestion.group {
                            Text(suggestion.group.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.top, index == 0 ? 0 : 5)
                                .padding(.bottom, 1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        GoalSuggestionRow(suggestion: suggestion) {
                            goal = suggestion.text
                            onPick(suggestion)
                        }
                    }
                }
            }
        }
        .menuModule(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
    }
}

/// One suggestion: where it's from, the text, and "today" or a time.
private struct GoalSuggestionRow: View {
    let suggestion: GoalSuggestion
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(suggestion.text)
                    .font(isGit ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? Theme.focusTint : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel("\(help): \(suggestion.text)")
    }

    private var isGit: Bool {
        if case .git = suggestion.source { return true }
        return false
    }

    private var icon: String {
        switch suggestion.source {
        case .task:     return "circle"
        case .calendar: return "calendar"
        case .git:      return "arrow.triangle.branch"
        case .lastGoal: return "arrow.uturn.backward"
        }
    }

    private var help: String {
        switch suggestion.source {
        case .task(let from, _, _): return String(localized: "From \(from.name), ticked off when you get it done")
        case .calendar:             return String(localized: "From your calendar")
        case .git:                  return String(localized: "The branch you're on")
        case .lastGoal:             return String(localized: "Your last goal, not done yet")
        }
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

// MARK: - Debrief row

/// The Complete screen's way into the debrief: written, being written, or
/// the plain summary on Macs without Apple Intelligence.
struct DebriefRow: View {
    let session: Session
    let status: DebriefCoordinator.Status
    let action: () -> Void

    var body: some View {
        ProRow(title: title, detail: detail, systemImage: "sparkles", action: action)
    }

    private var title: String {
        switch status {
        case .written: return String(localized: "Debrief is ready")
        case .writing: return String(localized: "Writing the debrief…")
        case .plain:   return String(localized: "Session summary")
        }
    }

    private var detail: String {
        switch status {
        case .writing:
            return String(localized: "On this Mac, in a few seconds")
        case .written:
            guard session.goal != nil else { return String(localized: "What you did, where you drifted, a tip") }
            guard let verdict = session.goalVerdict else { return String(localized: "Say how the goal went") }
            let line: String
            switch verdict {
            case .done:   line = String(localized: "Goal done")
            case .partly: line = String(localized: "Goal partly done")
            case .notYet: line = String(localized: "Goal not yet")
            }
            return session.storedDebrief?.evidenceShort.map { "\(line) · \($0)" } ?? line
        case .plain:
            return session.goal == nil ? String(localized: "Time, focus rate and top apps") : String(localized: "Say how the goal went")
        }
    }
}

// MARK: - Debrief pane

/// The debrief of the session that just ended, or the latest one.
struct DebriefPaneHost: View {
    @Bindable var appState: AppState
    let onOpenMain: (MainTab) -> Void
    let dismiss: () -> Void
    let close: () -> Void

    /// The session shown: the recap's, else the newest finished one. Kept
    /// here so the menu's every-second redraw doesn't look it up again.
    @State private var session: Session?
    @State private var debrief: SessionDebrief?

    var body: some View {
        DebriefPane(
            debrief: debrief,
            status: session.map { appState.debriefs.status(for: $0) } ?? .plain(.tooShort),
            close: close,
            onCorrect: { verdict in
                guard let session else { return }
                appState.debriefs.correct(session, to: verdict)
                reload(session)
            },
            onOpenLog: {
                dismiss()
                onOpenMain(.workLog)
            }
        )
        .onAppear(perform: pick)
        .onChange(of: appState.recap?.session.id) { pick() }
        .onChange(of: session?.debriefData) { reload(session) }
    }

    private func pick() {
        session = appState.recap?.session ?? appState.debriefs.latestFinished()
        reload(session)
    }

    private func reload(_ session: Session?) {
        debrief = session.map { appState.debriefs.debrief(for: $0) }
    }
}

struct DebriefPane: View {
    let debrief: SessionDebrief?
    var status: DebriefCoordinator.Status = .written
    let close: () -> Void
    var onCorrect: (GoalVerdict) -> Void = { _ in }
    var onOpenLog: () -> Void = {}

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                PaneTitle(title: String(localized: "Debrief"), close: close) { ProBadge() }
                if let debrief {
                    Text("\(debrief.sessionLabel) · \(menuClock(debrief.start))–\(menuClock(debrief.end))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            if let debrief {
                statusNote
                if let goal = debrief.goal { goalCard(goal, debrief) }
                if !debrief.isWritten { numbers(debrief) }
                if !debrief.workedOn.isEmpty { workedOn(debrief) }
                if debrief.drift != nil || debrief.tip != nil {
                    HStack(alignment: .top, spacing: 6) {
                        if let drift = debrief.drift {
                            note(String(localized: "Where you drifted"), drift, debrief.driftDetail, dot: Theme.distraction)
                        }
                        if let tip = debrief.tip { note(String(localized: "Next time"), tip, debrief.tipDetail) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if copied, let standup = standup(debrief) { copiedCard(standup) }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("Open your week", action: onOpenLog)
                        .buttonStyle(.capsule(.primary, height: 32, fullWidth: true))
                    if let standup = standup(debrief) {
                        Button("Copy for standup") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(standup, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.capsule(.secondary, height: 32, fullWidth: true))
                    }
                }
            } else {
                emptyCard
                Spacer(minLength: 0)
            }
            Text(debrief?.isWritten == false ? "Worked out on this Mac from your activity" : "Worked out on this Mac")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: Parts

    @ViewBuilder private var statusNote: some View {
        switch status {
        case .writing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing the debrief on this Mac…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .paneCard()
        case .plain(.needsAppleIntelligence):
            VStack(alignment: .leading, spacing: 3) {
                Text(OnDeviceAI.unavailableNote)
                    .font(.system(size: 12, weight: .semibold))
                Text("Written debriefs run on this Mac with Apple Intelligence. Until then, here are the numbers.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .paneCard()
        case .plain(.failed):
            Text("Couldn't write this one. Here are the numbers.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .paneCard()
        case .plain(.tooShort), .written:
            EmptyView()
        }
    }

    private func goalCard(_ goal: String, _ debrief: SessionDebrief) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Goal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Spacer()
                if let verdict = debrief.verdict { verdictPill(verdict) }
            }
            Text(goal)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let evidence = debrief.evidence {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                    Text(evidence)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Text(debrief.verdict == nil ? "How did it go?" : "Changed your mind?")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(GoalVerdict.allCases.filter { $0 != debrief.verdict }, id: \.self) { verdict in
                    PillButton(title: verdict.chipText, height: 22) { onCorrect(verdict) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Say how the goal went")
        }
        .paneCard()
    }

    private func verdictPill(_ verdict: GoalVerdict) -> some View {
        HStack(spacing: 4) {
            if verdict == .done {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            }
            Text(verdict.chipText)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(verdict == .done ? Color.white : Theme.primaryText)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(verdict == .done ? Theme.focusFill : Theme.control))
    }

    /// The plain summary's numbers: time and focus rate.
    private func numbers(_ debrief: SessionDebrief) -> some View {
        HStack(spacing: 0) {
            stat(String(localized: "Focused"), formatDuration(debrief.focused))
            Rectangle().fill(Theme.moduleStroke).frame(width: 0.5)
            stat(String(localized: "Focus rate"), debrief.focused > 0 ? String(localized: "\(debrief.focusPercent)%", comment: "Percentage") : "–")
        }
        .fixedSize(horizontal: false, vertical: true)
        .paneCard(padding: EdgeInsets())
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func workedOn(_ debrief: SessionDebrief) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(debrief.isWritten ? "What you worked on" : "Top apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            ForEach(debrief.workedOn) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.focus).frame(width: 6, height: 6).accessibilityHidden(true)
                    (Text(item.app).fontWeight(.semibold) + Text(item.what.isEmpty ? "" : " · \(item.what)"))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(formatDuration(item.seconds))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .paneCard()
    }

    private func note(_ title: String, _ text: String, _ detail: String?, dot: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true) }
                Text(text).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.primaryText.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .paneCard(padding: EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11))
    }

    private func copiedCard(_ standup: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Copied for standup", systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.link)
            Text(standup).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.focusTint.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.focus.opacity(0.25), lineWidth: 0.5))
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text("No debrief yet").font(.system(size: 14, weight: .semibold))
            Text("After your next session, this shows what you worked on, where you drifted and one thing to try.")
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

    /// The goal and how the person said it went. The model doesn't write this:
    /// a standup is passed on to others, and it made up what got done.
    private func standup(_ debrief: SessionDebrief) -> String? {
        guard let goal = debrief.goal else { return nil }
        switch debrief.verdict {
        case .done:   return String(localized: "Done: \(goal).")
        case .partly: return String(localized: "Partly done: \(goal).")
        default:      return String(localized: "Worked on: \(goal).")
        }
    }
}
