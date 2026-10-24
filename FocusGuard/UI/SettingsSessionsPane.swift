import SwiftUI

/// User defaults consumed by the popover's Start button when no explicit
/// duration/label has been picked for a session.
enum SessionDefaultsKey {
    static let durationMinutes = "session.defaultDurationMinutes"
    static let label           = "session.defaultLabel"
}

/// Sessions: how they're named, the defaults, what happens when you drift
/// (the old Escalation pane), breaks, and starting on their own.
struct SettingsSessionsPane: View {
    @Bindable var appState: AppState

    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = ""
    @AppStorage(SettingsKeys.Goal.dailyFocusMinutes) private var goalMinutes = GoalDefaults.dailyFocusMinutes
    @AppStorage(SettingsKeys.Goal.weekendsCount) private var weekendsCount = false
    @AppStorage(SettingsKeys.Breaks.strictMode) private var breakStrictMode = false
    @AppStorage(HabitSettings.autoStartOffer) private var autoStartOffer = true
    @AppStorage(HabitSettings.meetingAwareness) private var meetingAwareness = true

    @State private var preset: DriftResponse? = DriftResponse.current
    @State private var showingTimings = false
    @State private var namesOn = true

    var body: some View {
        SettingsColumns {
            namesSection
            defaultsSection
        } right: {
            driftSection
            SettingsSection("Breaks") {
                SettingsToggle(title: "Strict breaks", detail: "No ending a break early", isOn: $breakStrictMode)
            }
            SettingsSection("Starting and calls") {
                SettingsToggle(title: "Offer a session when you're already focused",
                               detail: "After 5 focused minutes outside a session. It counts from when you began",
                               isOn: $autoStartOffer)
                SettingsDivider()
                SettingsToggle(title: "Calls never count as drift",
                               detail: "Zoom, FaceTime, Meet and Teams count as neutral, and nudges wait during calls",
                               isOn: $meetingAwareness)
            }
        }
        .onAppear { namesOn = defaultLabel.isEmpty }
        .sheet(isPresented: $showingTimings, onDismiss: { preset = DriftResponse.current }) {
            DriftTimingsSheet(appState: appState)
        }
    }

    // MARK: - Names

    private var namesSection: some View {
        SettingsSection("Names") {
            SettingsToggle(title: "Name sessions automatically",
                           detail: "From how the focus went and how long it ran",
                           isOn: Binding(get: { namesOn }, set: { on in
                               namesOn = on
                               if on { defaultLabel = "" }
                           }))
            SettingsDivider()
            if namesOn {
                VStack(alignment: .leading, spacing: 10) {
                    FlowChips(items: [SessionNamer.Pattern.lockedIn, .steady, .slowStart, .comeback, .fading, .bumpy, .wandering]
                        .map(\.rawValue))
                    Text("Sprint, under 20 min · Run, under 45 · Deep Dive, up to 90 · Marathon")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    Text("So a 50-minute session that drifted early and finished strong is a Comeback Deep Dive. While it runs it's Morning, Afternoon, Evening or Late-night focus. Rename any session from Today.")
                        .font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                SettingsRow(title: "Name every session", detail: "Used for every session instead") {
                    TextField("Deep work", text: $defaultLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        SettingsSection("Defaults") {
            SettingsRow(title: "Usual length") {
                Picker("Usual length", selection: $defaultMinutes) {
                    ForEach([25, 45, 50, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(title: "Daily focus goal") {
                HStack(spacing: 0) {
                    Button { goalMinutes = max(FocusGoal.range.lowerBound, goalMinutes - 15) } label: {
                        Text("−").frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Lower goal")
                    Text(FocusGoal.format(minutes: goalMinutes))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 50)
                    Button { goalMinutes = min(FocusGoal.range.upperBound, goalMinutes + 15) } label: {
                        Text("+").frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Raise goal")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.primaryText)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.inset))
            }
            SettingsDivider()
            SettingsToggle(title: "Weekends count toward the streak", isOn: $weekendsCount)
        }
    }

    // MARK: - When you drift

    private var driftSection: some View {
        SettingsSection("When you drift") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(DriftResponse.allCases) { response in
                    presetCard(response)
                }
                if preset == nil {
                    Text("You've tuned the timings by hand. Pick a preset to go back to one.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                if appState.isStrictLocked {
                    Text("Strict stays on until this session ends.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Button("Fine-tune the timings…") { showingTimings = true }
                    .buttonStyle(.textLink)
                    .disabled(appState.isStrictLocked)
            }
            .padding(12)
        }
    }

    private func presetCard(_ response: DriftResponse) -> some View {
        let picked = preset == response
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            if appState.setDriftResponse(response) { preset = response }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(picked ? Theme.focus : Theme.lockedStroke, lineWidth: picked ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(response.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    Text(Self.summary(response))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(shape.fill(picked ? Theme.focus.opacity(0.07) : Theme.inset))
            .overlay(shape.strokeBorder(picked ? Theme.focus : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(appState.isStrictLocked && !picked)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// What each preset does, passes included (coordinator rulings).
    static func summary(_ response: DriftResponse) -> String {
        switch response {
        case .gentle:   return "Nudge after 1 min, pause screen after 3 min. Let me through right away, for 2 minutes."
        case .standard: return "Nudge after 30 s, pause screen after 90 s. Let me through after a 5-second wait, for 2 minutes."
        case .strict:   return "Pause screen as soon as you drift. No passes; “It's for work” unlocks after a 10-second wait."
        }
    }
}

/// Small grey chips that wrap onto more lines.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bodyText)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.chip))
            }
        }
    }
}

/// Lays children out left to right, wrapping when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 400, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Fine-tune

/// The escalation timings, by hand. Changing them leaves the preset as
/// "tuned by hand" until one is picked again.
struct DriftTimingsSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.Escalation.silenceThreshold) private var silence = Constants.Escalation.defaultSilenceSeconds
    @AppStorage(SettingsKeys.Escalation.notifyThreshold) private var notify = Constants.Escalation.defaultNotifySeconds
    @AppStorage(SettingsKeys.Escalation.blockThreshold) private var block = Constants.Escalation.defaultBlockSeconds
    @AppStorage(SettingsKeys.Escalation.cooldown) private var cooldown = Constants.Escalation.defaultCooldownSeconds
    @AppStorage(SettingsKeys.Escalation.notificationsEnabled) private var nudges = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fine-tune the timings")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            SettingsSection("Stages") {
                stepper("Ignore drift shorter than", value: $silence, range: 0...300, step: 5,
                        detail: "Still logged, just no nudge")
                SettingsDivider()
                SettingsToggle(title: "Nudge with a notification", isOn: $nudges)
                SettingsDivider()
                stepper("Nudge after", value: $notify, range: 5...600, step: 5, detail: nil).disabled(!nudges)
                SettingsDivider()
                stepper("Nudge again after", value: $cooldown, range: 15...600, step: 15, detail: "For the same drift").disabled(!nudges)
                SettingsDivider()
                stepper("Pause screen after", value: $block, range: 10...900, step: 10, detail: nil)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.capsule(.primary, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.windowBackground)
        .onChange(of: [silence, notify, block, cooldown]) { apply() }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int,
                         detail: String?) -> some View {
        SettingsRow(title: title, detail: detail) {
            Stepper(value: value, in: range, step: step) {
                Text(Self.seconds(value.wrappedValue))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private func apply() {
        let engine = appState.escalationEngine
        engine.silenceThreshold = TimeInterval(silence)
        engine.notifyThreshold = TimeInterval(notify)
        engine.notifyCooldown = TimeInterval(cooldown)
        engine.blockThreshold = TimeInterval(block)
    }

    /// "30 s", "1 min 30 s", "3 min".
    static func seconds(_ value: Int) -> String {
        if value < 60 { return "\(value) s" }
        let m = value / 60, s = value % 60
        return s == 0 ? "\(m) min" : "\(m) min \(s) s"
    }
}
