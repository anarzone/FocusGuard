import AppKit
import SwiftUI

/// Notifications: nudges in a session and the habit notices of the day.
/// The habit switches are the habits session's keys (`WindowHabitKey`).
struct SettingsNotificationsPane: View {
    @Bindable var appState: AppState

    @AppStorage(SettingsKeys.showNotifications) private var allowed = true
    @AppStorage(SettingsKeys.Escalation.notificationsEnabled) private var nudges = true
    @AppStorage(WindowHabitKey.meetingAwareness) private var quietInCalls = true
    @AppStorage(WindowHabitKey.morningPlan) private var morningPlan = true
    @AppStorage(WindowHabitKey.eveningWrapUp) private var eveningWrapUp = true

    var body: some View {
        SettingsColumns {
            SettingsSection("FocusGuard notifications") {
                SettingsToggle(title: "Allow notifications",
                               detail: "Off silences every one of them; the pause screen still works",
                               isOn: $allowed)
            }
            SettingsSection("During a session") {
                SettingsToggle(title: "Nudge when you drift", detail: nudgeDetail, isOn: $nudges)
                SettingsDivider()
                SettingsToggle(title: "Stay quiet during calls", detail: "Nudges wait until the call ends", isOn: $quietInCalls)
            }
            .disabled(!allowed)
            SettingsSection("Your day") {
                SettingsToggle(title: "Morning plan", detail: "Weekdays · your free time today and a first session", isOn: $morningPlan)
                SettingsDivider()
                SettingsToggle(title: "Evening wrap-up", detail: "How today went, and where to start tomorrow", isOn: $eveningWrapUp)
            }
            .disabled(!allowed)
        } right: {
            SettingsSection("What they look like") {
                VStack(spacing: 8) {
                    sample(time: "09:00", title: "Plan your day",
                           body: "Yesterday: \(WindowFormat.hm(4 * 3600 + 20 * 60)) focused. Start with \(defaultLength) minutes?")
                    sample(time: "18:30", title: "\(WindowFormat.hm(3 * 3600 + 23 * 60)) focused today",
                           body: "37 minutes short of your goal. One short session tonight keeps your streak.")
                    sample(time: "now", title: "Back to your session?",
                           body: "You've been on a distracting site for 30 seconds. The pause screen comes in a minute.")
                }
                .padding(12)
            }
            SettingsNote(text: "These are examples. macOS decides how notifications appear; change banners or alerts in System Settings › Notifications.")
            Button("Open Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.textLink)
            .padding(.leading, 4)
        }
    }

    private var defaultLength: Int {
        UserDefaults.standard.object(forKey: SessionDefaultsKey.durationMinutes) as? Int ?? 50
    }

    private var nudgeDetail: String {
        let engine = appState.escalationEngine
        if engine.strictMode { return "Strict pauses the screen straight away instead" }
        return "After \(DriftTimingsSheet.seconds(Int(engine.notifyThreshold))) on a distracting site · \(engine.preset.title)"
    }

    private func sample(time: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AppGlyph(kind: .focusguard, size: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("FocusGuard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text(time).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(body).font(.system(size: 12)).foregroundStyle(Theme.bodyText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Integrations

/// Integrations: the calendar, macOS Focus, Shortcuts, the browser
/// extension, and the rest of the Mac.
struct SettingsIntegrationsPane: View {
    @Bindable var appState: AppState

    @AppStorage(SettingsKeys.Calendar.enabled) private var calendarEnabled = false
    @AppStorage(SettingsKeys.Calendar.keyword) private var calendarKeyword = "focus"
    @AppStorage(SettingsKeys.SystemFocus.enabled) private var shortcutsEnabled = false
    @AppStorage(SettingsKeys.SystemFocus.startName) private var startShortcut = ""
    @AppStorage(SettingsKeys.SystemFocus.endName) private var endShortcut = ""

    @State private var shortcuts: [String] = []
    @State private var showingStarterPack = false

    var body: some View {
        SettingsColumns {
            calendarSection
            SettingsSection("macOS Focus") {
                SettingsRow(title: "Start a session with a Focus",
                            detail: "Add FocusGuard's filter to a Focus, like Work, in System Settings") {
                    Button("Open Focus…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.capsule(.secondary, height: 26))
                }
            }
            shortcutsSection
        } right: {
            SettingsSection(title: "Browser extension", trailing: { FreeBadge() }) {
                ExtensionStatusRows(appState: appState)
            }
            SettingsNote(text: "Free: sharper tracking, and tabs pause straight away. Pro adds blocking before pages load. Adding it never starts a trial.")
            SettingsSection("Around your Mac") {
                SettingsRow("Control Center and widgets", detail: "Add them with Edit Controls or Edit Widgets")
                SettingsDivider()
                SettingsRow(title: "Focus music", detail: musicDetail) {
                    Text("In the menu").font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                }
            }
        }
        .task {
            if let list = await SystemFocusBridge.availableShortcuts() { shortcuts = list }
        }
        .sheet(isPresented: $showingStarterPack) {
            StarterPackSheet(installed: shortcuts) {
                Task { if let list = await SystemFocusBridge.availableShortcuts() { shortcuts = list } }
            }
        }
    }

    private var musicDetail: String {
        let music = appState.music
        guard let playlist = music.selected else { return "Pick a playlist from the menu; it plays with each session" }
        return "\(playlist.service.name) · \(playlist.title) plays with each session"
    }

    // MARK: - Calendar

    private var calendarSection: some View {
        SettingsSection("Calendar") {
            SettingsToggle(title: "Start sessions from events", detail: "For as long as the event runs",
                           isOn: Binding(get: { calendarEnabled }, set: { on in
                               calendarEnabled = on
                               appState.calendarAutostart.enabled = on
                               if on { Task { _ = await appState.calendarAutostart.requestAccess() } }
                           }))
            if calendarEnabled {
                SettingsDivider()
                SettingsRow(title: "When the title contains") {
                    TextField("focus", text: $calendarKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                SettingsDivider()
                accessOrNext
            }
        }
    }

    @ViewBuilder
    private var accessOrNext: some View {
        let calendar = appState.calendarAutostart
        switch calendar.accessState {
        case .notDetermined:
            SettingsRow(title: "Calendar access not granted yet", detail: "macOS asks once") {
                Button("Grant access") {
                    Task {
                        _ = await calendar.requestAccess()
                        if calendar.accessState == .notDetermined { Self.openCalendarPrivacy() }
                    }
                }
                .buttonStyle(.capsule(.secondary, height: 26))
            }
        case .denied:
            SettingsRow(title: "Calendar access is off",
                        detail: "Turn it on in System Settings › Privacy & Security › Calendars") {
                Button("Open Settings") { Self.openCalendarPrivacy() }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
        case .authorized:
            if let title = calendar.nextMatchTitle, let start = calendar.nextMatchStart {
                SettingsRow("Next: \(title)", detail: start.formatted(.dateTime.weekday(.wide).hour().minute()))
            } else {
                SettingsRow("No matching events in the next 12 hours")
            }
        }
    }

    static func openCalendarPrivacy() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        SettingsSection("Shortcuts and Spotlight") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Actions you can use").font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                FlowChips(items: ["Start a session", "End the session", "Pause or resume", "Take a break", "Get today's focus"])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            SettingsDivider()
            SettingsToggle(title: "Run a shortcut when a session starts or ends", isOn: $shortcutsEnabled)
            if shortcutsEnabled {
                SettingsDivider()
                shortcutRow("When a session starts, run", selection: $startShortcut)
                SettingsDivider()
                shortcutRow("When it ends, run", selection: $endShortcut)
                SettingsDivider()
                SettingsRow(title: "Don't have one yet?", detail: "Ready-made shortcuts for Work, Do Not Disturb and more") {
                    Button("Starter pack…") { showingStarterPack = true }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            }
        }
    }

    private func shortcutRow(_ title: String, selection: Binding<String>) -> some View {
        SettingsRow(title: title, detail: shortcutDetail(selection.wrappedValue)) {
            Picker(title, selection: selection) {
                Text("Nothing").tag("")
                ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                if !selection.wrappedValue.isEmpty && !shortcuts.contains(selection.wrappedValue) {
                    Text(selection.wrappedValue).tag(selection.wrappedValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 170)
        }
    }

    private func shortcutDetail(_ name: String) -> String? {
        guard !name.isEmpty, !shortcuts.isEmpty, !shortcuts.contains(name) else { return nil }
        return "“\(name)” isn't in the Shortcuts app"
    }
}
