import AppKit
import SwiftUI

/// Integrations: the calendar, tasks as session goals, code, macOS and
/// the browser. Calendar, Reminders and Things ask macOS once; Todoist and
/// Linear take a personal token (`TaskSourceRows`).
struct SettingsIntegrationsPane: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet

    @AppStorage(SettingsKeys.Calendar.enabled) private var calendarEnabled = false
    @AppStorage(SettingsKeys.Calendar.keyword) private var calendarKeyword = "focus"
    @AppStorage(IntegrationSettings.sessionsOnCalendar) private var sessionsOnCalendar = false
    @AppStorage(IntegrationSettings.sessionsCalendar) private var sessionsCalendar = ""
    @AppStorage(IntegrationSettings.nextMeeting) private var nextMeeting = true
    @AppStorage(IntegrationSettings.reminders) private var remindersOn = false
    @AppStorage(IntegrationSettings.gitBranch) private var gitBranch = true
    @AppStorage(IntegrationSettings.gitFolder) private var gitFolder = ""
    @AppStorage(SettingsKeys.SystemFocus.enabled) private var shortcutsEnabled = false
    @AppStorage(SettingsKeys.SystemFocus.startName) private var startShortcut = ""
    @AppStorage(SettingsKeys.SystemFocus.endName) private var endShortcut = ""

    @State private var calendarAccess = EventKitAccess.calendars
    @State private var remindersAccess = EventKitAccess.reminders
    @State private var calendars: [CalendarChoice] = []
    @State private var defaultCalendarID: String?
    /// Empty means all of them.
    @State private var readCalendars = IntegrationSettings.ids(IntegrationSettings.readCalendars)
    @State private var lists: [CalendarChoice] = []
    @State private var chosenLists = IntegrationSettings.ids(IntegrationSettings.reminderLists)
    @State private var shortcuts: [String] = []
    @State private var showingStarterPack = false

    var body: some View {
        SettingsColumns {
            calendarSection
            tasksSection
            codeSection
        } right: {
            macSection
            SettingsSection("Browser and music") {
                browserRow
                SettingsDivider()
                SettingsRow(title: "Focus music", detail: musicDetail) {
                    Text("In the menu").font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                }
            }
            SettingsNote(text: "The browser extension is free: sharper tracking, and tabs pause straight away. Pro adds blocking before pages load. Adding it never starts a trial.")
            SettingsNote(systemImage: "lock",
                         text: "FocusGuard reads the calendars you choose and writes only its own sessions. It never changes or deletes your events.")
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingStarterPack) {
            StarterPackSheet(installed: shortcuts) {
                Task { if let list = await SystemFocusBridge.availableShortcuts() { shortcuts = list } }
            }
        }
    }

    /// Access, the calendars and lists, and the shortcuts, as they are now.
    private func reload() async {
        calendarAccess = EventKitAccess.calendars
        remindersAccess = EventKitAccess.reminders
        appState.calendarAutostart.refreshAccess()
        calendars = await appState.integrations.calendarChoices()
        defaultCalendarID = await appState.integrations.defaultCalendarID()
        lists = await appState.integrations.reminderLists()
        if let list = await SystemFocusBridge.availableShortcuts() { shortcuts = list }
    }

    // MARK: - Calendar

    private var calendarSection: some View {
        SettingsSection("Calendar") {
            SettingsToggle(title: "Start sessions from events",
                           detail: "When the title has “\(keywordShown)”, for as long as it runs",
                           isOn: Binding(get: { calendarEnabled }, set: { on in
                               calendarEnabled = on
                               appState.calendarAutostart.enabled = on
                               if on { requestCalendarAccess() }
                           }))
            if calendarEnabled {
                SettingsDivider()
                SettingsRow(title: "When the title contains", detail: nextMatchDetail) {
                    TextField("focus", text: $calendarKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
            SettingsDivider()
            SettingsToggle(title: "Put sessions on your calendar",
                           detail: "As busy time in \(writeCalendarName), so nobody books over them",
                           isOn: calendarSwitch($sessionsOnCalendar))
            if sessionsOnCalendar && calendarAccess == .granted {
                SettingsDivider()
                SettingsRow(title: "Add them to") { writeCalendarPicker }
            }
            SettingsDivider()
            SettingsToggle(title: "Next meeting in the menu",
                           detail: "“Standup in 25 min”, from 30 minutes before",
                           isOn: calendarSwitch($nextMeeting))
            SettingsDivider()
            if calendarAccess == .granted {
                SettingsRow(title: "Calendars") { readCalendarsMenu }
            } else {
                calendarAccessRow
            }
        }
    }

    private var keywordShown: String {
        let trimmed = calendarKeyword.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "focus" : trimmed
    }

    private var nextMatchDetail: String? {
        let calendar = appState.calendarAutostart
        guard calendarAccess == .granted else { return nil }
        guard let title = calendar.nextMatchTitle, let start = calendar.nextMatchStart else {
            return "No matching events in the next 12 hours"
        }
        return "Next: \(title) · \(start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    /// A switch that needs the calendar: turning it on asks macOS once.
    private func calendarSwitch(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { on in
            value.wrappedValue = on
            if on { requestCalendarAccess() }
        })
    }

    private func requestCalendarAccess(openSettingsIfUnasked: Bool = false) {
        guard EventKitAccess.calendars != .granted else { return }
        Task {
            _ = await appState.calendarAutostart.requestAccess()
            await reload()
            if openSettingsIfUnasked && EventKitAccess.calendars == .notDetermined { Self.openPrivacy("Calendars") }
        }
    }

    @ViewBuilder
    private var calendarAccessRow: some View {
        if calendarAccess == .denied {
            SettingsRow(title: "Calendar access is off",
                        detail: "Turn it on in System Settings › Privacy & Security › Calendars") {
                Button("Open Settings") { Self.openPrivacy("Calendars") }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
        } else {
            SettingsRow(title: "Calendar access not granted yet", detail: "macOS asks once") {
                Button("Grant access") { requestCalendarAccess(openSettingsIfUnasked: true) }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
        }
    }

    private var writableCalendars: [CalendarChoice] { calendars.filter(\.canWrite) }

    /// The calendar sessions go to: the chosen one, else the default.
    private var writeCalendarID: String {
        let chosen = writableCalendars.contains { $0.id == sessionsCalendar } ? sessionsCalendar : ""
        return chosen.isEmpty ? (defaultCalendarID ?? "") : chosen
    }

    private var writeCalendarName: String {
        calendars.first { $0.id == writeCalendarID }?.title ?? "your calendar"
    }

    private var writeCalendarPicker: some View {
        let writable = writableCalendars
        return Picker("Add them to", selection: Binding(get: { writeCalendarID }, set: { sessionsCalendar = $0 })) {
            if !writable.contains(where: { $0.id == writeCalendarID }) {
                Text("Default calendar").tag(writeCalendarID)
            }
            ForEach(writable) { Text(Self.label($0, among: writable)).tag($0.id) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 170)
    }

    private var readCalendarsMenu: some View {
        Menu {
            Toggle("All calendars", isOn: Binding(get: { readCalendars.isEmpty }, set: { if $0 { setReadCalendars([]) } }))
            Divider()
            ForEach(calendars) { calendar in
                Toggle(Self.label(calendar, among: calendars), isOn: Binding(
                    get: { readCalendars.isEmpty || readCalendars.contains(calendar.id) },
                    set: { on in setRead(calendar.id, on) }))
            }
        } label: {
            Text(Self.summary(chosen: readCalendars, of: calendars, all: "All"))
        }
        .fixedSize()
    }

    private func setRead(_ id: String, _ on: Bool) {
        let all = calendars.map(\.id)
        var chosen = readCalendars.isEmpty ? all : readCalendars
        if on {
            if !chosen.contains(id) { chosen.append(id) }
        } else {
            chosen.removeAll { $0 == id }
            guard !chosen.isEmpty else { return }   // at least one stays
        }
        setReadCalendars(Set(chosen) == Set(all) ? [] : chosen)
    }

    private func setReadCalendars(_ ids: [String]) {
        readCalendars = ids
        UserDefaults.standard.set(ids, forKey: IntegrationSettings.readCalendars)
        Task { await appState.integrations.refreshNextMeeting() }
    }

    // MARK: - Tasks

    private var tasksUnlocked: Bool { entitlements.isUnlocked(.taskGoals) }

    private var tasksSection: some View {
        SettingsSection(title: "Tasks as session goals", trailing: { ProBadge() }) {
            TaskSourceRow(source: .reminders, detail: remindersDetail) {
                if tasksUnlocked || entitlements.canStartTrial {
                    Toggle("Reminders", isOn: Binding(get: { remindersOn && tasksUnlocked }, set: setReminders))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Theme.focusFill)
                } else {
                    Button("Get Pro") { openSheet(.upgrade(.taskGoals)) }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            }
            if remindersOn && tasksUnlocked {
                SettingsDivider()
                switch remindersAccess {
                case .granted:
                    SettingsRow(title: "Lists") { listsMenu }
                case .notDetermined:
                    SettingsRow(title: "Reminders access not granted yet", detail: "macOS asks once") {
                        Button("Grant access") { requestRemindersAccess(openSettingsIfUnasked: true) }
                            .buttonStyle(.capsule(.secondary, height: 26))
                    }
                case .denied:
                    SettingsRow(title: "Reminders access is off",
                                detail: "Turn it on in System Settings › Privacy & Security › Reminders") {
                        Button("Open Settings") { Self.openPrivacy("Reminders") }
                            .buttonStyle(.capsule(.secondary, height: 26))
                    }
                }
            }
            TaskSourceRows(integrations: appState.integrations, entitlements: entitlements)
        }
    }

    private var remindersDetail: String {
        if !tasksUnlocked && entitlements.canStartTrial {
            return "Ticked off when a session's done. Turning it on starts your \(Plan.trialDays)-day Pro trial"
        }
        if !tasksUnlocked { return "Ticked off when a session's done. Part of Pro" }
        return "Ticked off when a session's done"
    }

    private func setReminders(_ on: Bool) {
        guard on else {
            remindersOn = false
            return
        }
        if !tasksUnlocked { entitlements.startTrialIfNeeded(for: .taskGoals) }
        guard tasksUnlocked else { return }
        remindersOn = true
        requestRemindersAccess()
    }

    private func requestRemindersAccess(openSettingsIfUnasked: Bool = false) {
        guard EventKitAccess.reminders != .granted else { return }
        Task {
            _ = await appState.integrations.requestRemindersAccess()
            await reload()
            if openSettingsIfUnasked && EventKitAccess.reminders == .notDetermined { Self.openPrivacy("Reminders") }
        }
    }

    private var listsMenu: some View {
        Menu {
            Toggle("All lists", isOn: Binding(get: { chosenLists.isEmpty }, set: { if $0 { setLists([]) } }))
            Divider()
            ForEach(lists) { list in
                Toggle(Self.label(list, among: lists), isOn: Binding(
                    get: { chosenLists.isEmpty || chosenLists.contains(list.id) },
                    set: { on in setList(list.id, on) }))
            }
        } label: {
            Text(Self.summary(chosen: chosenLists, of: lists, all: "All lists"))
        }
        .fixedSize()
    }

    private func setList(_ id: String, _ on: Bool) {
        let all = lists.map(\.id)
        var chosen = chosenLists.isEmpty ? all : chosenLists
        if on {
            if !chosen.contains(id) { chosen.append(id) }
        } else {
            chosen.removeAll { $0 == id }
            guard !chosen.isEmpty else { return }
        }
        setLists(Set(chosen) == Set(all) ? [] : chosen)
    }

    private func setLists(_ ids: [String]) {
        chosenLists = ids
        UserDefaults.standard.set(ids, forKey: IntegrationSettings.reminderLists)
    }

    // MARK: - Code

    private var codeSection: some View {
        SettingsSection("Code") {
            SettingsToggle(title: "Suggest your Git branch as a goal",
                           detail: "The branch open in your editor",
                           isOn: $gitBranch)
            if gitBranch {
                SettingsDivider()
                SettingsRow(title: "Look in", detail: IntegrationSettings.shortPath(IntegrationSettings.gitFolder())) {
                    Button("Choose…", action: chooseGitFolder)
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            }
        }
    }

    private func chooseGitFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = IntegrationSettings.gitFolder()
        panel.prompt = "Choose"
        panel.message = "The folder your Git repos are in"
        let pick = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { gitFolder = url.path }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: pick)
        } else {
            pick(panel.runModal())
        }
    }

    // MARK: - macOS

    private var macSection: some View {
        SettingsSection("macOS") {
            SettingsRow(title: "Start a session with a Focus",
                        detail: "Add FocusGuard's filter to a Focus in System Settings") {
                Button("Open Focus…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.capsule(.secondary, height: 26))
            }
            SettingsDivider()
            SettingsRow(title: "Shortcuts to run", detail: shortcutDetail) { shortcutsMenu }
            SettingsDivider()
            SettingsRow("Control Center and widgets", detail: "Add them with Edit Controls or Edit Widgets")
        }
    }

    /// Off means none, whatever names are left from before.
    private func shortcut(_ name: String) -> String { shortcutsEnabled ? name : "" }

    private var shortcutsMenu: some View {
        Menu {
            shortcutPicker("When a session starts", selection: Binding(
                get: { shortcut(startShortcut) },
                set: { setShortcuts(start: $0, end: shortcut(endShortcut)) }))
            shortcutPicker("When it ends", selection: Binding(
                get: { shortcut(endShortcut) },
                set: { setShortcuts(start: shortcut(startShortcut), end: $0) }))
            Divider()
            Button("Starter pack…") { showingStarterPack = true }
        } label: {
            Text(shortcutSummary)
        }
        .fixedSize()
    }

    private func shortcutPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Nothing").tag("")
            ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
            if !selection.wrappedValue.isEmpty && !shortcuts.contains(selection.wrappedValue) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }

    /// Both names are written, so neither falls back to a default name.
    private func setShortcuts(start: String, end: String) {
        startShortcut = start
        endShortcut = end
        shortcutsEnabled = !start.isEmpty || !end.isEmpty
    }

    private var shortcutSummary: String {
        let names = [shortcut(startShortcut), shortcut(endShortcut)].filter { !$0.isEmpty }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private var shortcutDetail: String {
        let missing = [shortcut(startShortcut), shortcut(endShortcut)].first {
            !$0.isEmpty && !shortcuts.isEmpty && !shortcuts.contains($0)
        }
        return missing.map { "“\($0)” isn't in the Shortcuts app" } ?? "When a session starts and ends"
    }

    // MARK: - Browser and music

    private var browserRow: some View {
        let connected = appState.extensionBridge.connectedBrowsers
        let installed = ExtensionSheet.browsers.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil
        }
        let on = installed.filter { connected.contains($0.bundleId) }.map(\.name)
        let notYet = installed.filter { !connected.contains($0.bundleId) }.map(\.name)
        let detail = installed.isEmpty
            ? "For Chrome, Arc, Brave and Edge"
            : [on.isEmpty ? nil : "\(HabitFormat.list(on)) on", notYet.isEmpty ? nil : "\(HabitFormat.list(notYet)) not yet"]
                .compactMap { $0 }.joined(separator: " · ")
        return SettingsRow(title: "Browser extension", detail: detail) {
            if !installed.isEmpty && notYet.isEmpty {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bodyText)
            } else {
                Button(notYet.count == 1 ? "Add to \(notYet[0])…" : "Add…") { openSheet(.browserExtension) }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
        }
    }

    private var musicDetail: String {
        let music = appState.music
        guard let playlist = music.selected else { return "Pick a playlist from the menu; it plays with each session" }
        return "\(playlist.service.name) · \(playlist.title) plays with each session"
    }

    // MARK: - Helpers

    /// "Work", or "Calendar (Google)" when two share a name.
    static func label(_ choice: CalendarChoice, among all: [CalendarChoice]) -> String {
        let shared = all.contains { $0.id != choice.id && $0.title == choice.title }
        return shared && !choice.account.isEmpty ? "\(choice.title) (\(choice.account))" : choice.title
    }

    /// "All", "Work, Personal", or "Work, Personal +2".
    static func summary(chosen: [String], of all: [CalendarChoice], all allTitle: String) -> String {
        let names = all.filter { chosen.contains($0.id) }.map(\.title)
        guard !chosen.isEmpty, !names.isEmpty else { return allTitle }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    /// System Settings › Privacy & Security, at "Calendars" or "Reminders".
    static func openPrivacy(_ pane: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
