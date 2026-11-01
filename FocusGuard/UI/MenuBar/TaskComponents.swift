import SwiftUI

// The integrations in the menu: the next meeting on the ready screen, and
// ticking off a task when the session's done (Pro). The data is in
// Session/Integrations.

// MARK: - Next meeting

/// "Standup in 25 min · 10:30", from 30 minutes before.
struct NextMeetingRow: View {
    let meeting: NextMeeting
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText.opacity(0.75))
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(meeting.countdown(at: now))
                    .font(.system(size: 12).monospacedDigit())
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Text(menuClock(meeting.start))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .menuModule(padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}

// MARK: - Tick it off

/// The Complete screen's goal when it came from a task: how it went, and
/// the task ticked off in its app on Done, with Undo.
struct TaskGoalCard: View {
    let goal: String
    let verdict: GoalVerdict?
    let link: TaskLink
    let onVerdict: (GoalVerdict) -> Void
    let onUndo: () -> Void
    let onTick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your goal")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text(goal)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            VerdictPicker(selection: verdict, onPick: onVerdict)
            status
        }
        .menuModule(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }

    @ViewBuilder private var status: some View {
        let app = link.task.source.name
        HStack(spacing: 8) {
            if link.ticked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.focus)
                    .accessibilityHidden(true)
                Text("Ticked off in \(app)").frame(maxWidth: .infinity, alignment: .leading)
                Button("Undo", action: onUndo).buttonStyle(.textLink)
            } else if verdict == .done {
                Image(systemName: "circle")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text("Still open in \(app)").frame(maxWidth: .infinity, alignment: .leading)
                Button("Tick off", action: onTick).buttonStyle(.textLink)
            } else {
                Image(systemName: "checklist")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text(link.task.list.isEmpty ? "From \(app)" : "From \(app) · \(link.task.list)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.primaryText.opacity(0.85))
    }
}

/// Done, Partly, Not yet: the user's own call on the goal.
private struct VerdictPicker: View {
    let selection: GoalVerdict?
    let onPick: (GoalVerdict) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(GoalVerdict.allCases, id: \.self) { verdict in
                let picked = verdict == selection
                Button { onPick(verdict) } label: {
                    Text(verdict.chipText)
                        .font(.system(size: 12, weight: picked ? .semibold : .regular))
                        .foregroundStyle(picked ? Color.white : Theme.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(picked ? Theme.focusFill : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Did you get it done?")
    }
}

/// After a tick: the next open task, ready to start on.
struct NextTaskRow: View {
    let item: TaskItem
    let minutes: Int
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Next on your list")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            PillButton(title: "Start \(minutes) min", height: 28, fill: Theme.focusTint, action: onStart)
        }
        .menuModule(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
    }
}
