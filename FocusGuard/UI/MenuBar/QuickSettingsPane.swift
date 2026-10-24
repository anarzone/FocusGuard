import SwiftUI

/// Quick settings beside the menu: what happens when you drift, what
/// blocking does (Free or Pro), daily limits, the daily goal and the menu-bar
/// time. Everything else lives in Settings.
struct QuickSettingsPane: View {
    @Bindable var appState: AppState
    let onOpenMain: (MainTab) -> Void
    let dismiss: () -> Void
    let close: () -> Void
    var entitlements: Entitlements = .shared

    @AppStorage(SettingsKeys.Goal.dailyFocusMinutes) private var goalMinutes = GoalDefaults.dailyFocusMinutes
    @AppStorage(SettingsKeys.menuBarShowTime) private var menuBarShowTime = true

    @State private var drift: DriftResponse? = DriftResponse.current
    /// The Pro feature whose row was tapped on Free: shows the trial line.
    @State private var trialFor: ProFeature?
    @State private var editingLimit: UUID?
    @State private var adding = false
    @State private var newSite = ""
    @State private var newMinutes = 30
    @State private var limitNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneTitle(title: "Quick settings", close: close) {
                if entitlements.isUnlocked(.unlimitedLimits) { ProBadge() } else { FreeBadge() }
            }

            driftSection
            blockingSection
            limitsSection

            VStack(spacing: 2) {
                row("Daily goal") {
                    HStack(spacing: 8) {
                        RoundIconButton(systemImage: "minus", label: "Lower the daily goal") {
                            goalMinutes = max(FocusGoal.range.lowerBound, goalMinutes - 15)
                        }
                        .disabled(goalMinutes <= FocusGoal.range.lowerBound)
                        Text(FocusGoal.format(minutes: goalMinutes))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 52)
                        RoundIconButton(systemImage: "plus", label: "Raise the daily goal") {
                            goalMinutes = min(FocusGoal.range.upperBound, goalMinutes + 15)
                        }
                        .disabled(goalMinutes >= FocusGoal.range.upperBound)
                    }
                }
                row("Show time in menu bar") {
                    Toggle("Show time in menu bar", isOn: $menuBarShowTime)
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                        .tint(Theme.focusFill)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Text("Changes save instantly.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("All settings ›") {
                    dismiss()
                    onOpenMain(.settings)
                }
                .buttonStyle(.textLink)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - When you drift

    private var driftSection: some View {
        let locked = appState.isStrictLocked
        return VStack(alignment: .leading, spacing: 7) {
            paneHeading("When you drift")
            HStack(spacing: 0) {
                ForEach(DriftResponse.allCases) { preset in
                    let on = drift == preset
                    Button {
                        if appState.setDriftResponse(preset) { drift = preset }
                    } label: {
                        Text(preset.title)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.primaryText : Theme.primaryText.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? Theme.segment : .clear)
                                .shadow(color: .black.opacity(on ? 0.15 : 0), radius: 1, y: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.control))
            .disabled(locked)
            .opacity(locked ? 0.6 : 1)

            Text(locked ? "Strict stays on until this session ends." : presetLine)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText.opacity(0.85))
                .padding(.horizontal, 2)
            if let drift {
                Text(Self.rules(drift.overridePolicy))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    /// How fast each preset steps in, in the blocking level's own words.
    private var presetLine: String {
        let action = entitlements.isUnlocked(.blockInBrowser) ? "block" : "pause the tab"
        switch drift {
        case .gentle:   return "Nudge after 1 min · \(action) after 3 min"
        case .standard: return "Nudge after 30 s · \(action) after 90 s"
        case .strict:   return "\(action.prefix(1).uppercased() + action.dropFirst()) as soon as you drift"
        case nil:       return "Custom timings, set in Settings"
        }
    }

    /// What the preset lets you do once blocked, from `OverridePolicy`.
    static func rules(_ policy: OverridePolicy) -> String {
        let pass = policy.allowsPass
            ? "Let me through \(policy.passWaitSeconds == 0 ? "right away" : "after \(policy.passWaitSeconds) s"), for \(Int(policy.passSeconds / 60)) min"
            : "No Let me through"
        let forWork = policy.forWorkWaitSeconds > 0 ? "It’s for work after a \(policy.forWorkWaitSeconds) s wait" : nil
        let extra = policy.extraTime
        let limits: String
        if extra.isOffered {
            let often = extra.timesPerDay == 1 ? " once a day" : ", up to \(extra.timesPerDay) times a day"
            let wait = extra.waitSeconds > 0 ? ", after \(extra.waitSeconds) s" : ""
            limits = "daily limits: \(extra.minutes) more min\(often)\(wait)"
        } else {
            limits = "no extra time on daily limits"
        }
        return [pass, forWork, limits].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Blocking level

    private var blockingSection: some View {
        let pro = entitlements.isUnlocked(.blockInBrowser)
        return VStack(alignment: .leading, spacing: 7) {
            paneHeading("What blocking does")
            VStack(spacing: 0) {
                levelRow(title: "Pause the tab",
                         detail: pro ? "Used in browsers without the extension." : "The tab switches to a calm FocusGuard page.",
                         selected: !pro, badge: AnyView(FreeBadge())) {}
                divider(leading: 37)
                levelRow(title: "Block in the browser",
                         detail: browserDetail(pro: pro),
                         selected: pro, badge: AnyView(ProBadge())) {
                    if !pro { trialFor = trialFor == .blockInBrowser ? nil : .blockInBrowser }
                }
                if trialFor == .blockInBrowser { trialLine(for: .blockInBrowser) }
                divider(leading: 37)
                levelRow(title: "Block on the whole Mac", detail: "Every browser and app. Coming later.",
                         selected: false, badge: AnyView(ProBadge()), enabled: false) {}
            }
            .paneCard(padding: EdgeInsets())
        }
    }

    private func browserDetail(pro: Bool) -> String {
        let base = "Pages never load. Works on parts of sites, like youtube.com/shorts."
        guard pro, appState.extensionBridge.connectedBrowsers.isEmpty else { return base }
        return base + " Needs the browser extension."
    }

    private func levelRow(title: String, detail: String, selected: Bool, badge: AnyView, enabled: Bool = true,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    if selected {
                        Circle().fill(Theme.focusFill)
                        Circle().fill(.white).frame(width: 6, height: 6)
                    } else {
                        Circle().strokeBorder(Theme.lockedStroke, lineWidth: 1.5)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                badge
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One line and one link, in place, for a Pro row tapped on Free.
    private func trialLine(for feature: ProFeature) -> some View {
        HStack(spacing: 8) {
            Text("Part of Pro. Try every Pro feature free for \(Plan.trialDays) days.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entitlements.canStartTrial {
                Button("Start trial") {
                    entitlements.startTrialIfNeeded(for: feature)
                    trialFor = nil
                }
                .buttonStyle(.capsule(.primary, height: 24))
            } else {
                Button("Get Pro") {
                    dismiss()
                    onOpenMain(.settings)
                }
                .buttonStyle(.capsule(.primary, height: 24))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.focusTint.opacity(0.6)))
        .padding(.leading, 37)
        .padding(.trailing, 11)
        .padding(.bottom, 11)
    }

    // MARK: - Daily limits

    private var limitsSection: some View {
        let statuses = appState.limits.statuses
        let atCap = entitlements.dailyLimitCap.map { statuses.count >= $0 } ?? false
        return VStack(alignment: .leading, spacing: 7) {
            paneHeading("Daily limits", note: "reset at \(menuClock(Calendar.current.startOfDay(for: .now)))")
            VStack(spacing: 0) {
                ForEach(statuses) { status in
                    limitRow(status)
                    divider(leading: 43)
                }
                if adding {
                    addLimitRow
                } else {
                    Button {
                        if atCap {
                            limitNote = "Free includes one limit. Pro has no cap."
                            trialFor = trialFor == .unlimitedLimits ? nil : .unlimitedLimits
                        } else {
                            adding = true
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.lockedStroke,
                                                                                      style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                            Text(atCap ? (limitNote ?? "Add another limit") : (statuses.isEmpty ? "Add a limit" : "Add another limit"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.primaryText.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if atCap { ProBadge() }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if trialFor == .unlimitedLimits { trialLine(for: .unlimitedLimits) }
            }
            .paneCard(padding: EdgeInsets())
        }
    }

    private func limitRow(_ status: LimitStatus) -> some View {
        let editing = editingLimit == status.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppGlyph(kind: status.isSite ? .generic : AppGlyph.kind(forBundleId: status.target, name: status.name),
                         bundleId: status.isSite ? nil : status.target, host: status.isSite ? status.target : nil, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(min(status.minutes + status.extraMinutes, Int(status.used / 60))) of \(status.minutes + status.extraMinutes) min")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.primaryText.opacity(0.85))
                    }
                    LimitBar(fraction: status.allowance > 0 ? status.used / status.allowance : 1, height: 4)
                }
                PillButton(title: editing ? "Done" : "Edit", height: 22) {
                    editingLimit = editing ? nil : status.id
                }
                .accessibilityLabel(editing ? "Done editing the \(status.name) limit" : "Edit the \(status.name) limit")
            }
            if let pending = status.pending {
                Text(pending == .removal ? "Removed from tomorrow." : pendingText(pending))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 32)
            }
            if editing {
                HStack(spacing: 8) {
                    RoundIconButton(systemImage: "minus", label: "Five minutes less") { change(status, by: -5) }
                        .disabled(status.minutes <= 5)
                    Text("\(pendingMinutes(status) ?? status.minutes) min a day")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    RoundIconButton(systemImage: "plus", label: "Five minutes more") { change(status, by: 5) }
                    Spacer(minLength: 4)
                    Button("Remove") {
                        if appState.limits.removeLimit(status.id) == .fromTomorrow {
                            limitNote = nil
                        }
                        editingLimit = nil
                    }
                    .buttonStyle(.capsule(.destructive, height: 22))
                }
                .padding(.leading, 32)
                if appState.escalationEngine.policy.limitChangesWaitForTomorrow {
                    Text("Strict: changes start tomorrow.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 32)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private func pendingMinutes(_ status: LimitStatus) -> Int? {
        if case .minutes(let m) = status.pending { return m }
        return nil
    }

    private func pendingText(_ pending: DailyLimit.PendingChange) -> String {
        if case .minutes(let m) = pending { return "\(m) min a day from tomorrow." }
        return ""
    }

    private func change(_ status: LimitStatus, by delta: Int) {
        let current = pendingMinutes(status) ?? status.minutes
        appState.limits.setMinutes(max(5, current + delta), for: status.id)
    }

    private var addLimitRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("A site, like youtube.com", text: $newSite)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.segment.opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
                .onSubmit(addLimit)
            HStack(spacing: 8) {
                RoundIconButton(systemImage: "minus", label: "Five minutes less") { newMinutes = max(5, newMinutes - 5) }
                Text("\(newMinutes) min a day")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                RoundIconButton(systemImage: "plus", label: "Five minutes more") { newMinutes = min(600, newMinutes + 5) }
                Spacer(minLength: 4)
                Button("Cancel") {
                    adding = false
                    limitNote = nil
                }
                .buttonStyle(.capsule(.secondary, height: 22))
                Button("Add", action: addLimit)
                    .buttonStyle(.capsule(.primary, height: 22))
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let limitNote {
                Text(limitNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.destructive)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private func addLimit() {
        guard appState.limits.addLimit(target: newSite, isSite: true, minutes: newMinutes) != nil else {
            limitNote = "That doesn't look like a site. Try something like youtube.com."
            return
        }
        newSite = ""
        newMinutes = 30
        limitNote = nil
        adding = false
    }

    // MARK: - Bits

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            control()
        }
        .frame(height: 30)
        .padding(.horizontal, 2)
    }

    private func divider(leading: CGFloat) -> some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, leading)
    }
}
