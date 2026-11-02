import AppKit
import SwiftUI

/// Integrations: the calendar, tasks as session goals, code, status in
/// Slack and Discord, macOS and the browser. Calendar, Reminders and Things
/// ask macOS once; Todoist and Linear take a personal token
/// (`TaskSourceRows`); only Slack signs in.
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
            SettingsStatusSection()
            macSection
            SettingsSection(String(localized: "Browser and music")) {
                browserRow
                SettingsDivider()
                SettingsRow(title: String(localized: "Focus music"), detail: musicDetail) {
                    Text("In the menu").font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                }
            }
            SettingsNote(text: String(localized: "The browser extension is free: sharper tracking, and tabs pause straight away. Pro adds blocking before pages load. Adding it never starts a trial."))
            SettingsNote(systemImage: "lock",
                         text: String(localized: "FocusGuard reads the calendars you choose and writes only its own sessions. It never changes or deletes your events."))
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
        SettingsSection(String(localized: "Calendar")) {
            SettingsToggle(title: String(localized: "Start sessions from events"),
                           detail: String(localized: "When the title has “\(keywordShown)”, for as long as it runs"),
                           isOn: Binding(get: { calendarEnabled }, set: { on in
                               calendarEnabled = on
                               appState.calendarAutostart.enabled = on
                               if on { requestCalendarAccess() }
                           }))
            if calendarEnabled {
                SettingsDivider()
                SettingsRow(title: String(localized: "When the title contains"), detail: nextMatchDetail) {
                    // The keyword itself: it's matched as written, so it isn't translated.
                    TextField("focus" as String, text: $calendarKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
            SettingsDivider()
            SettingsToggle(title: String(localized: "Put sessions on your calendar"),
                           detail: writeCalendarDetail,
                           isOn: calendarSwitch($sessionsOnCalendar))
            if sessionsOnCalendar && calendarAccess == .granted {
                SettingsDivider()
                SettingsRow(title: String(localized: "Add them to", comment: "Them: sessions. The calendar they go on")) { writeCalendarPicker }
            }
            SettingsDivider()
            SettingsToggle(title: String(localized: "Next meeting in the menu"),
                           detail: String(localized: "“Standup in 25 min”, from 30 minutes before"),
                           isOn: calendarSwitch($nextMeeting))
            SettingsDivider()
            if calendarAccess == .granted {
                SettingsRow(title: String(localized: "Calendars")) { readCalendarsMenu }
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
            return String(localized: "No matching events in the next 12 hours")
        }
        return String(localized: "Next: \(title) · \(start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
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
            SettingsRow(title: String(localized: "Calendar access is off"),
                        detail: String(localized: "Turn it on in System Settings › Privacy & Security › Calendars")) {
                Button("Open Settings") { Self.openPrivacy("Calendars") }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
        } else {
            SettingsRow(title: String(localized: "Calendar access not granted yet"), detail: String(localized: "macOS asks once")) {
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

    private var writeCalendarDetail: String {
        guard let name = calendars.first(where: { $0.id == writeCalendarID })?.title else {
            return String(localized: "As busy time in your calendar, so nobody books over them")
        }
        return String(localized: "As busy time in \(name), so nobody books over them")
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
            Text(Self.summary(chosen: readCalendars, of: calendars, all: String(localized: "All", comment: "Every calendar is picked")))
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
        SettingsSection(title: String(localized: "Tasks as session goals"), trailing: { ProBadge() }) {
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
                    SettingsRow(title: String(localized: "Lists", comment: "Reminders lists")) { listsMenu }
                case .notDetermined:
                    SettingsRow(title: String(localized: "Reminders access not granted yet"), detail: String(localized: "macOS asks once")) {
                        Button("Grant access") { requestRemindersAccess(openSettingsIfUnasked: true) }
                            .buttonStyle(.capsule(.secondary, height: 26))
                    }
                case .denied:
                    SettingsRow(title: String(localized: "Reminders access is off"),
                                detail: String(localized: "Turn it on in System Settings › Privacy & Security › Reminders")) {
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
            return String(localized: "Ticked off when a session's done. Turning it on starts your \(Plan.trialDays)-day Pro trial")
        }
        if !tasksUnlocked { return String(localized: "Ticked off when a session's done. Part of Pro") }
        return String(localized: "Ticked off when a session's done")
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
            Text(Self.summary(chosen: chosenLists, of: lists, all: String(localized: "All lists")))
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
        SettingsSection(String(localized: "Code", comment: "Settings section: source code")) {
            SettingsToggle(title: String(localized: "Suggest your Git branch as a goal"),
                           detail: String(localized: "The branch open in your editor"),
                           isOn: $gitBranch)
            if gitBranch {
                SettingsDivider()
                SettingsRow(title: String(localized: "Look in", comment: "The folder to look for Git repos in"), detail: IntegrationSettings.shortPath(IntegrationSettings.gitFolder())) {
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
        panel.prompt = String(localized: "Choose", comment: "Button in the panel that picks a folder")
        panel.message = String(localized: "The folder your Git repos are in")
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
            SettingsRow(title: String(localized: "Start a session with a Focus"),
                        detail: String(localized: "Add FocusGuard's filter to a Focus in System Settings")) {
                Button("Open Focus…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.capsule(.secondary, height: 26))
            }
            SettingsDivider()
            SettingsRow(title: String(localized: "Shortcuts to run"), detail: shortcutDetail) { shortcutsMenu }
            SettingsDivider()
            SettingsRow(String(localized: "Control Center and widgets"), detail: String(localized: "Add them with Edit Controls or Edit Widgets"))
        }
    }

    /// Off means none, whatever names are left from before.
    private func shortcut(_ name: String) -> String { shortcutsEnabled ? name : "" }

    private var shortcutsMenu: some View {
        Menu {
            shortcutPicker(String(localized: "When a session starts"), selection: Binding(
                get: { shortcut(startShortcut) },
                set: { setShortcuts(start: $0, end: shortcut(endShortcut)) }))
            shortcutPicker(String(localized: "When it ends", comment: "It: a session"), selection: Binding(
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
        return names.isEmpty ? String(localized: "None", comment: "No shortcut is chosen") : names.joined(separator: ", ")
    }

    private var shortcutDetail: String {
        let missing = [shortcut(startShortcut), shortcut(endShortcut)].first {
            !$0.isEmpty && !shortcuts.isEmpty && !shortcuts.contains($0)
        }
        return missing.map { String(localized: "“\($0)” isn't in the Shortcuts app") } ?? String(localized: "When a session starts and ends")
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
            ? String(localized: "For Chrome, Arc, Brave and Edge")
            : [on.isEmpty ? nil : String(localized: "\(HabitFormat.list(on)) on", comment: "Browsers the extension is connected in: Chrome and Arc on"),
               notYet.isEmpty ? nil : String(localized: "\(HabitFormat.list(notYet)) not yet", comment: "Browsers still without the extension: Brave and Edge not yet")]
                .compactMap { $0 }.joined(separator: " · ")
        return SettingsRow(title: String(localized: "Browser extension"), detail: detail) {
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
        guard let playlist = music.selected else { return String(localized: "Pick a playlist from the menu; it plays with each session") }
        return String(localized: "\(playlist.service.name) · \(playlist.title) plays with each session")
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
