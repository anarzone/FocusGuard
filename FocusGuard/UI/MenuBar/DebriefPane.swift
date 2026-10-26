import AppKit
import SwiftUI

// The session goal and the debrief after a session (Pro, behind
// `FeatureFlags.debrief`). The data and the writing are in Session/Debrief.

// MARK: - Goal

/// "What's this session for?" on the ready screen: the goal the debrief
/// checks. Empty, it offers the last unfinished goal and the calendar
/// event on now. Return starts the session.
struct SessionGoalField: View {
    @Binding var goal: String
    var suggestions: [GoalSuggestion] = []
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
            TextField("e.g. Ship the session-names PR", text: $goal)
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(suggestions) { suggestion in
                        Button { goal = suggestion.text } label: {
                            HStack(spacing: 6) {
                                Image(systemName: suggestion.source == .calendar ? "calendar" : "arrow.uturn.forward")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.focus)
                                    .frame(width: 14)
                                    .accessibilityHidden(true)
                                Text(suggestion.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(Theme.control))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(suggestion.source == .calendar ? "From your calendar" : "Your last goal, not done yet")
                        .accessibilityLabel(suggestion.source == .calendar
                                            ? "Use the calendar event: \(suggestion.text)"
                                            : "Pick up the last goal: \(suggestion.text)")
                    }
                }
            }
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
        case .written: return "Debrief is ready"
        case .writing: return "Writing the debrief…"
        case .plain:   return "Session summary"
        }
    }

    private var detail: String {
        switch status {
        case .writing:
            return "On this Mac, in a few seconds"
        case .written:
            guard session.goal != nil, let verdict = session.goalVerdict else {
                return "What you did, where you drifted, a tip"
            }
            let short = session.storedDebrief?.evidenceShort.map { " · \($0)" } ?? ""
            return "Goal \(verdict.debriefText.lowercased())\(short)"
        case .plain:
            return session.goal == nil ? "Time, focus rate and top apps" : "Say how the goal went"
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
                PaneTitle(title: "Debrief", close: close) { ProBadge() }
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
                            note("Where you drifted", drift, debrief.driftDetail, dot: Theme.distraction)
                        }
                        if let tip = debrief.tip { note("Next time", tip, debrief.tipDetail) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if copied, let standup = standup(debrief) { copiedCard(standup) }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("Open work log", action: onOpenLog)
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
                    Image(systemName: "checkmark.seal")
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
                Text(debrief.verdict == nil ? "How did it go?" : "Not quite?")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(GoalVerdict.allCases.filter { $0 != debrief.verdict }, id: \.self) { verdict in
                    PillButton(title: verdict.chipText, height: 22) { onCorrect(verdict) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Correct the goal check")
        }
        .paneCard()
    }

    private func verdictPill(_ verdict: GoalVerdict) -> some View {
        HStack(spacing: 4) {
            if verdict == .done {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            }
            Text(verdict.debriefText)
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
            stat("Focused", formatDuration(debrief.focused))
            Rectangle().fill(Theme.moduleStroke).frame(width: 0.5)
            stat("Focus rate", debrief.focused > 0 ? "\(debrief.focusPercent)%" : "–")
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

    /// The model's standup line, or the goal and how it went.
    private func standup(_ debrief: SessionDebrief) -> String? {
        if let standup = debrief.standup { return standup }
        guard let goal = debrief.goal else { return nil }
        switch debrief.verdict {
        case .done:   return "Done: \(goal)."
        case .partly: return "Partly done: \(goal)."
        default:      return "Worked on: \(goal)."
        }
    }
}
