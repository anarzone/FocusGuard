import SwiftUI

/// User defaults consumed by the popover's Start button when no explicit
/// duration/label has been picked for a session.
enum SessionDefaultsKey {
    static let durationMinutes = "session.defaultDurationMinutes"
    static let label           = "session.defaultLabel"
}

struct SettingsSessionsPane: View {
    @Bindable var appState: AppState

    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage(SessionDefaultsKey.label)           private var defaultLabel  = "Deep work"

    @AppStorage(SettingsKeys.Goal.dailyFocusMinutes) private var dailyGoalMinutes = GoalDefaults.dailyFocusMinutes
    @AppStorage(SettingsKeys.Goal.weekendsCount)     private var weekendsCount    = false

    @AppStorage(SettingsKeys.Breaks.autoPromptAfterSession) private var breakAutoPrompt = true
    @AppStorage(SettingsKeys.Breaks.strictMode)             private var breakStrictMode = false

    @AppStorage(SettingsKeys.SystemFocus.enabled)    private var systemFocusEnabled = false
    @AppStorage(SettingsKeys.SystemFocus.startName)  private var startShortcutName = ""
    @AppStorage(SettingsKeys.SystemFocus.endName)    private var endShortcutName   = ""

    @State private var availableShortcuts: [String] = []
    @State private var showingStarterPack = false

    @AppStorage("calendarAutostart.enabled") private var calendarEnabled = false
    @AppStorage("calendarAutostart.keyword") private var calendarKeyword = "focus"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sessions")
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                Text("Defaults applied when you press Start without specifying a duration.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                sectionHeader("Daily goal", topPad: 24)
                groupCard {
                    row(title: "Daily focus goal",
                        help: "Drives the progress bar in the popover and the end-of-day summary notification.") {
                        Stepper(value: $dailyGoalMinutes, in: 30...480, step: 15) {
                            Text(FocusGoal.format(minutes: dailyGoalMinutes))
                                .font(.system(size: 13).monospacedDigit())
                                .frame(width: 70, alignment: .trailing)
                        }
                        .labelsHidden()
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    row(title: "Weekends count toward streak",
                        help: "When off, Saturday and Sunday are skipped during streak calculation so a quiet weekend doesn't break a weekday streak.") {
                        Toggle("", isOn: $weekendsCount)
                            .toggleStyle(.switch).labelsHidden()
                    }
                }

                sectionHeader("Defaults", topPad: 24)
                groupCard {
                    row(title: "Default duration",
                        help: "Used when you press Start without picking a length.") {
                        Picker("", selection: $defaultMinutes) {
                            Text("25 min").tag(25)
                            Text("50 min").tag(50)
                            Text("90 min").tag(90)
                            Text("120 min").tag(120)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    row(title: "Default label",
                        help: "Shown in reports next to each session.") {
                        TextField("Deep work", text: $defaultLabel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }

                sectionHeader("Breaks", topPad: 24)
                groupCard {
                    row(title: "Prompt for a break after each session",
                        help: "When a session's planned timer hits zero, show a sheet to start a break or jump straight into another session. Manual stops never trigger the prompt.") {
                        Toggle("", isOn: $breakAutoPrompt)
                            .toggleStyle(.switch).labelsHidden()
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    row(title: "Strict mode (no skipping)",
                        help: "When on, the break overlay can only be extended — Skip and Hide are disabled. Helps if you tend to skip your way through every break.") {
                        Toggle("", isOn: $breakStrictMode)
                            .toggleStyle(.switch).labelsHidden()
                    }
                }

                sectionHeader("System Focus", topPad: 24)
                groupCard {
                    row(title: "Run a Shortcut on session start/end",
                        help: "Create one or two Shortcuts in the Shortcuts app — for example, one to enable a Focus mode and one to clear it. We'll run them at session boundaries. Leave a name blank to skip that side.") {
                        Toggle("", isOn: $systemFocusEnabled)
                            .toggleStyle(.switch).labelsHidden()
                    }
                    if systemFocusEnabled {
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        row(title: "On session start", help: shortcutHelp(startShortcutName)) {
                            shortcutPicker(selection: $startShortcutName)
                        }
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        row(title: "On session end", help: shortcutHelp(endShortcutName)) {
                            shortcutPicker(selection: $endShortcutName)
                        }
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        row(title: "Don't see your shortcut?",
                            help: "Pick from a starter pack — built-in modes (Work, DND, Reading) plus a Deep Work combo. macOS doesn't allow apps to install Shortcuts silently, so each one takes about 30 seconds to set up the first time.") {
                            Button("Starter pack…") { showingStarterPack = true }
                        }
                    }
                }
                .task {
                    if let list = await SystemFocusBridge.availableShortcuts() {
                        availableShortcuts = list
                    }
                }
                .sheet(isPresented: $showingStarterPack) {
                    StarterPackSheet(installed: availableShortcuts) {
                        // Reload the installed list after the sheet closes —
                        // user may have added shortcuts.
                        Task {
                            if let list = await SystemFocusBridge.availableShortcuts() {
                                availableShortcuts = list
                            }
                        }
                    }
                }

                sectionHeader("Calendar autostart", topPad: 24)
                groupCard {
                    row(title: "Autostart on calendar event",
                        help: "Auto-create a focus session when a calendar event matching the keyword starts. Auto-stops when the event ends.") {
                        Toggle("", isOn: calendarEnabledBinding)
                            .toggleStyle(.switch).labelsHidden()
                    }
                    if calendarEnabled {
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        row(title: "Match keyword",
                            help: "Calendar events whose title contains this keyword (case-insensitive) trigger a session.") {
                            TextField("focus", text: $calendarKeyword)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .onSubmit { /* persisted via AppStorage */ }
                        }
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        nextMatchRow
                    }
                    if !appState.calendarAutostart.hasCalendarAccess && calendarEnabled {
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        calendarPermissionRow
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Calendar binding & next-match row

    private var calendarEnabledBinding: Binding<Bool> {
        Binding(
            get: { calendarEnabled },
            set: { newValue in
                if newValue {
                    if appState.calendarAutostart.hasCalendarAccess {
                        calendarEnabled = true
                        appState.calendarAutostart.enabled = true
                    } else {
                        // Request access; only flip the toggle on if granted.
                        Task {
                            let granted = await appState.calendarAutostart.requestAccess()
                            if granted {
                                calendarEnabled = true
                                appState.calendarAutostart.enabled = true
                            } else {
                                calendarEnabled = false
                            }
                        }
                    }
                } else {
                    calendarEnabled = false
                    appState.calendarAutostart.enabled = false
                }
            }
        )
    }

    /// Permission state of the EventKit grant, with copy + button that match
    /// the actual state. Avoids the "access denied" message after a fresh
    /// install / TCC reset when the user never actually denied anything.
    @ViewBuilder
    private var calendarPermissionRow: some View {
        switch appState.calendarAutostart.accessState {
        case .notDetermined:
            row(title: "Calendar access not granted yet",
                help: "Click Grant to ask for access. macOS will show a permission prompt.") {
                Button("Grant access") {
                    Task {
                        let granted = await appState.calendarAutostart.requestAccess()
                        if granted { appState.calendarAutostart.enabled = true }
                    }
                }
            }
        case .denied:
            row(title: "Calendar access denied",
                help: "macOS won't re-prompt after a denial. Grant access in System Settings → Privacy & Security → Calendars, then return here.") {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .authorized:
            EmptyView()
        }
    }

    @ViewBuilder
    private var nextMatchRow: some View {
        if let title = appState.calendarAutostart.nextMatchTitle,
           let start = appState.calendarAutostart.nextMatchStart {
            row(title: "Next match",
                help: nextMatchHelp(start: start)) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
        } else {
            row(title: "Next match",
                help: "No upcoming events containing the keyword in the next 12 hours.") {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func nextMatchHelp(start: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let timeStr = formatter.string(from: start)
        let now = Date()
        if start <= now { return "Currently active." }
        let interval = Int(start.timeIntervalSince(now))
        let mins = interval / 60
        if mins < 60 { return "Starts at \(timeStr) (in \(mins)m)." }
        let hours = mins / 60
        let remain = mins % 60
        return "Starts at \(timeStr) (in \(hours)h \(remain)m)."
    }

    /// Dropdown of installed Shortcuts plus a "(none)" option. We list real
    /// shortcut names so the user can't typo a name into oblivion.
    @ViewBuilder
    private func shortcutPicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            Text("(none)").tag("")
            ForEach(availableShortcuts, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 220)
    }

    private func shortcutHelp(_ name: String) -> String {
        if name.isEmpty { return "Nothing will run on this side." }
        if availableShortcuts.isEmpty { return "Reading installed Shortcuts…" }
        if !availableShortcuts.contains(name) {
            return "“\(name)” isn't installed. Create it in the Shortcuts app, then reopen Settings."
        }
        return "Will run “\(name)” via the Shortcuts CLI."
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, topPad: CGFloat = 24) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.top, topPad)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func row<Right: View>(
        title: String,
        help: String? = nil,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let help {
                    Text(help)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            right()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
