import AppKit
import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Privacy & data: what's kept, which apps' titles aren't, what goes
/// online, how long history lasts, and taking it all back. "Send
/// diagnostics" builds a local report the user reads before sending it.
struct SettingsPrivacyPane: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared

    @State private var optOuts: [TitleOptOut] = []
    @State private var stats: StoreStats = .zero
    @State private var confirmDeleteToday = false
    @State private var confirmErase = false
    @State private var report: DiagnosticsReport.Prepared?
    @AppStorage(SettingsKeys.retentionDays) private var retentionDays = 365
    @AppStorage(SettingsWindowKey.siteIcons) private var siteIcons = true

    private var context: ModelContext { appState.container.mainContext }

    @State private var decisions = DecisionLog.shared.summary()

    /// How FocusGuard's own choices are doing: counts from the decision log.
    private var decisionsSection: some View {
        SettingsSection(String(localized: "How its choices are doing", comment: "Settings section: how often FocusGuard's suggestions, cards and blocks worked, last 7 days")) {
            decisionRow(String(localized: "Goal picked from a suggestion"), decisions.fromSuggestion, decisions.offeredSuggestions)
            SettingsDivider()
            decisionRow(String(localized: "Goals done"), decisions.done, decisions.verdicts)
            SettingsDivider()
            decisionRow(String(localized: "Island cards answered"), decisions.cardsAnswered, decisions.cardsShown)
            SettingsDivider()
            decisionRow(String(localized: "Blocks you went back to work from"), decisions.backToWork, decisions.blocksShown)
            SettingsDivider()
            SettingsRow(title: String(localized: "Each look at the app in front"),
                        detail: String(localized: "Counts from the last 7 days, kept on this Mac only: never goals, titles or sites.")) {
                Text(String(localized: "\(String(format: "%.1f", decisions.timing.average * 1000)) ms", comment: "How long something took, in milliseconds"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.bodyText)
            }
        }
        .onAppear { decisions = DecisionLog.shared.summary() }
    }

    private func decisionRow(_ title: String, _ count: Int, _ of: Int) -> some View {
        SettingsRow(title: title) {
            Text(of == 0 ? String(localized: "Nothing yet") : String(localized: "\(count) of \(of)", comment: "A count out of a total: 3 of 40"))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.bodyText)
        }
    }

    var body: some View {
        SettingsColumns {
            SettingsSection(String(localized: "Kept on this Mac")) {
                SettingsRow(title: stats.summary, detail: String(localized: "In FocusGuard's folder in your Library")) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([StoreStats.storeURL]) }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 7) {
                    bullet("checkmark", String(localized: "Which app or site is in front, once a second"))
                    bullet("checkmark", String(localized: "Window titles, except in the apps below"))
                    bullet("checkmark", String(localized: "Your sessions and how they went"))
                    bullet("xmark", String(localized: "Never keystrokes, screen contents, page text or passwords"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            titlesSection
            decisionsSection
            SettingsSection(String(localized: "Something wrong?")) {
                SettingsRow(title: String(localized: "Send diagnostics"),
                            detail: String(localized: "App logs and settings only, never your activity, titles or sites. You see it all before it's sent.")) {
                    Button("Review and send…") { report = DiagnosticsReport.prepare(appState: appState) }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            }
        } right: {
            SettingsSection(String(localized: "What leaves this Mac")) {
                SettingsRow(String(localized: "Update checks"), detail: String(localized: "Once a day; sends the app version"))
                SettingsDivider()
                SettingsToggle(title: String(localized: "Site icons"), detail: String(localized: "Each icon comes straight from its own site"), isOn: $siteIcons)
                SettingsDivider()
                SettingsRow(String(localized: "Licence check"), detail: String(localized: "Pro only, when you enter a key and when the app starts"))
                SettingsDivider()
                SettingsRow("Spotify", detail: String(localized: "Only if you sign in to search playlists"))
                SettingsDivider()
                SettingsRow(String(localized: "Todoist, Linear, GitHub and Jira"), detail: String(localized: "Only if you connect them: reads your tasks, and ticks off the one you finish"))
            }
            SettingsNote(systemImage: "lock",
                         text: PrivacyNote.onThisMac)
            SettingsSection(String(localized: "History", comment: "Settings section: how long activity is kept")) {
                SettingsRow(title: String(localized: "Keep history for"),
                            detail: entitlements.historyStart() == nil ? nil : String(localized: "Reports past \(Plan.freeHistoryDays) days need Pro")) {
                    Picker("Keep history for", selection: $retentionDays) {
                        ForEach(RetentionPolicy.choices, id: \.days) { Text($0.label).tag($0.days) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: retentionDays) { RetentionPolicy.prune(context: context); reload() }
                }
            }
            SettingsSection(String(localized: "Your data")) {
                SettingsRow(title: String(localized: "Export everything")) {
                    HStack(spacing: 6) {
                        Button("JSON") { DataExporter.export(.json, container: appState.container) }
                        Button("CSV") { DataExporter.export(.csv, container: appState.container) }
                    }
                    .buttonStyle(.capsule(.secondary, height: 26))
                }
                SettingsDivider()
                SettingsRow(title: String(localized: "Delete today's activity")) {
                    Button("Delete…") { confirmDeleteToday = true }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
                SettingsDivider()
                SettingsRow(title: String(localized: "Erase all FocusGuard data"), detail: String(localized: "Activity, sessions, rules and settings")) {
                    Button("Erase…") { confirmErase = true }
                        .buttonStyle(.capsule(.destructive, height: 26))
                }
            }
        }
        .task { reload() }
        .confirmationDialog("Delete today's activity?", isPresented: $confirmDeleteToday) {
            Button("Delete Today", role: .destructive) { DataEraser.deleteToday(appState: appState); reload() }
        } message: {
            Text("Today's activity and sessions are removed from this Mac. Earlier days stay.")
        }
        .confirmationDialog("Erase all FocusGuard data?", isPresented: $confirmErase) {
            Button("Erase Everything", role: .destructive) { DataEraser.eraseAll(appState: appState); reload() }
        } message: {
            Text("Every session, activity, rule and setting is removed. This can't be undone.")
        }
        .sheet(item: $report) { prepared in
            DiagnosticsSheet(prepared: prepared)
        }
    }

    // MARK: - Titles

    private var titlesSection: some View {
        SettingsSection(String(localized: "Don't record window titles in")) {
            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 6) {
                    ForEach(optOuts, id: \.bundleIdentifier) { entry in
                        HStack(spacing: 4) {
                            Text(Self.appName(entry.bundleIdentifier)).font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                            Button { remove(entry) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.secondaryText)
                                    .frame(width: 16, height: 16).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(Self.appName(entry.bundleIdentifier))")
                        }
                        .padding(.leading, 10).padding(.trailing, 4)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.chip))
                    }
                }
                Button("Add app…", action: addApp).buttonStyle(.textLink)
            }
            .padding(14)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .foregroundStyle(symbol == "xmark" ? Theme.secondaryText : Theme.focus)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.bodyText).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func appName(_ bundleId: String) -> String {
        RuleItemBuilder.appName(bundleId) ?? RuleItemBuilder.fallbackName(bundleId)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              !optOuts.contains(where: { $0.bundleIdentifier == id }) else { return }
        context.insert(TitleOptOut(bundleIdentifier: id))
        Persistence.save(context)
        appState.optOutCache.refresh()
        reload()
    }

    private func remove(_ entry: TitleOptOut) {
        context.delete(entry)
        Persistence.save(context)
        appState.optOutCache.refresh()
        reload()
    }

    private func reload() {
        optOuts = Persistence.fetch(context, FetchDescriptor<TitleOptOut>(sortBy: [SortDescriptor(\.bundleIdentifier)]))
        stats = StoreStats.compute(context: context)
    }
}

/// "41 days · 212 sessions · 38 MB".
struct StoreStats: Equatable {
    let days: Int
    let sessions: Int
    let bytes: Int

    static let zero = StoreStats(days: 0, sessions: 0, bytes: 0)

    static var storeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/default.store")
    }

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let dayCount = String(localized: "\(days) days", comment: "Plural on n: 1 day / 2 days")
        let sessionCount = String(localized: "\(sessions) sessions", comment: "Plural on n: 1 session / 2 sessions")
        return "\(dayCount) · \(sessionCount) · \(size)"
    }

    @MainActor
    static func compute(context: ModelContext, now: Date = .now) -> StoreStats {
        var first = FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.startedAt)])
        first.fetchLimit = 1
        let start = Persistence.fetch(context, first).first?.startedAt
        let days = start.map { max(1, (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: $0), to: now).day ?? 0) + 1) } ?? 0
        let sessions = Persistence.fetchCount(context, FetchDescriptor<Session>())
        let files = ["", "-wal", "-shm"].map { storeURL.path + $0 }
        let bytes = files.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0) }
        return StoreStats(days: days, sessions: sessions, bytes: bytes)
    }
}

// MARK: - Diagnostics

/// A plain-text report for support: the version, the Mac, the plan,
/// permission states, settings that say how the app is set up, what this
/// run has cost in CPU and wakeups (`EnergyUsage`), and this run's log
/// lines with sites and paths taken out. No activity, no titles, no sites. Nothing is sent: the user reads it, then opens Mail or a
/// GitHub issue themselves. It stays in English whatever the app's language,
/// since support reads it.
enum DiagnosticsReport {
    struct Prepared: Identifiable {
        let id = UUID()
        let text: String
        let file: URL?
    }

    static let issuesURL = URL(string: "https://github.com/anarzone/FocusGuard/issues/new")!

    @MainActor
    static func prepare(appState: AppState, now: Date = .now) -> Prepared {
        let text = build(sections: sections(appState: appState), logs: recentLogs(), now: now)
        return Prepared(text: text, file: try? write(text, now: now))
    }

    @MainActor
    static func sections(appState: AppState) -> [(String, [(String, String)])] {
        let d = UserDefaults.standard
        let engine = appState.escalationEngine
        let permissions = appState.permissions
        let plan: String
        switch Entitlements.shared.plan {
        case .free: plan = "Free"
        case .pro: plan = "Pro"
        case .trial: plan = "Trial, \(Entitlements.shared.plan.daysLeft(at: .now) ?? 0) days left"
        }
        let rules = Persistence.fetchCount(appState.container.mainContext, FetchDescriptor<AppRule>())
        return [
            ("App", [("Version", AppVersion.full),
                     ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
                     ("Plan", plan)]),
            ("Permissions", [("All granted", permissions.allGranted ? "yes" : "no")]),
            ("Settings", [("Drift preset", DriftResponse.current?.rawValue.capitalized ?? "tuned by hand"),
                          ("Nudge after", "\(Int(engine.notifyThreshold)) s"),
                          ("Pause screen after", "\(Int(engine.blockThreshold)) s"),
                          ("Strict", engine.strictMode ? "on" : "off"),
                          ("Daily goal", FocusGoal.format(minutes: FocusGoal.dailyMinutes)),
                          ("Notifications", d.object(forKey: SettingsKeys.showNotifications) as? Bool ?? true ? "on" : "off"),
                          ("Pause the tab", d.object(forKey: SettingsWindowKey.pauseTab) as? Bool ?? true ? "on" : "off"),
                          ("Keep history", "\(RetentionPolicy.days) days"),
                          ("Calendar starts", d.bool(forKey: SettingsKeys.Calendar.enabled) ? "on" : "off"),
                          ("Rules", "\(rules)"),
                          ("Daily limits", "\(appState.limits.statuses.count)")]),
            ("Browser extension", [("Connected browsers", "\(appState.extensionBridge.connectedBrowsers.count)")]),
            ("Energy, this run", EnergyUsage.sinceLaunch()?.rows ?? [("Usage", "unavailable")]),
            ("Decisions, last 7 days", DecisionLog.shared.summary().rows),
        ]
    }

    static func build(sections: [(String, [(String, String)])], logs: [String], now: Date) -> String {
        var lines = ["FocusGuard diagnostics, \(now.formatted(.iso8601))", ""]
        for (title, rows) in sections {
            lines.append("## \(title)")
            lines += rows.map { "\($0.0): \($0.1)" }
            lines.append("")
        }
        lines.append("## Log, this run")
        lines += logs.isEmpty ? ["(nothing logged)"] : logs.map(scrub)
        return lines.joined(separator: "\n")
    }

    /// Takes out anything that looks like a site or a path in the user's
    /// home folder, so a log line can't say where someone was.
    static func scrub(_ line: String) -> String {
        var out = line.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let patterns = [
            #"https?://\S+"#,
            #"\b(?:[a-z0-9-]+\.)+(?:com|org|net|io|app|dev|co|tv|gg|me|ai|edu|gov|uk|de|fr|ru|az)\b"#,
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "<site>", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// This run's log lines from FocusGuard itself, newest last.
    static func recentLogs(limit: Int = 300) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = store.position(timeIntervalSinceLatestBoot: max(0, ProcessInfo.processInfo.systemUptime - 6 * 3600))
        guard let entries = try? store.getEntries(at: since) else { return [] }
        var out: [String] = []
        for case let entry as OSLogEntryLog in entries where entry.subsystem == "com.anar.focusguard" {
            out.append("\(entry.date.formatted(.iso8601)) [\(entry.category)] \(entry.composedMessage)")
        }
        return Array(out.suffix(limit))
    }

    static func write(_ text: String, now: Date) throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusGuard Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("FocusGuard diagnostics \(stamp).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// The report, in full, before it goes anywhere.
private struct DiagnosticsSheet: View {
    let prepared: DiagnosticsReport.Prepared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send diagnostics").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
            Text("This is everything in the report. Nothing has been sent. Mail opens with it attached; for a GitHub issue it's copied so you can paste it in.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(prepared.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.windowCard))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            HStack(spacing: 8) {
                if let file = prepared.file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(.textLink)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Open a GitHub issue") {
                    copy()
                    NSWorkspace.shared.open(DiagnosticsReport.issuesURL)
                }
                .buttonStyle(.capsule(.secondary, height: 32))
                Button("Open in Mail") { mail() }
                    .buttonStyle(.capsule(.primary, height: 32))
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.windowBackground)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prepared.text, forType: .string)
        copied = true
    }

    private func mail() {
        let items: [Any] = prepared.file.map { [$0] } ?? [prepared.text]
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.subject = "FocusGuard diagnostics"
        service.perform(withItems: items)
    }
}

/// What leaves this Mac, said the same way everywhere. Keep it in step with
/// the code: update checks (Sparkle), site icons (`FaviconLoader`, from the
/// sites themselves), Spotify (`FocusMusic`, `SpotifyAccount`), Todoist,
/// Linear, GitHub and Jira (`TodoistTasks`, `LinearTasks`, `GitHubTasks`,
/// `JiraTasks`), Slack once it's built in (`SlackAccount`) and, while the
/// app offers them, AI tips.
enum PrivacyStatement {
    /// For the Privacy and About panes.
    static var network: String { networkStatement(slack: StatusSync.slackAvailable) }

    /// - Parameter slack: Slack is built in, for the status while you focus.
    static func networkStatement(slack: Bool) -> String {
        switch (slack, AISettings.isAvailable) {
        case (true, true):
            return String(localized: "Your activity is stored on this Mac. FocusGuard goes online only to check for updates, to fetch site icons from the sites themselves, for Spotify, Todoist, Linear, GitHub, Jira and Slack when you use them, and for AI tips, which send a short summary (never window titles or full URLs) when you ask.")
        case (false, true):
            return String(localized: "Your activity is stored on this Mac. FocusGuard goes online only to check for updates, to fetch site icons from the sites themselves, for Spotify, Todoist, Linear, GitHub and Jira when you use them, and for AI tips, which send a short summary (never window titles or full URLs) when you ask.")
        case (true, false):
            return String(localized: "Your activity is stored on this Mac. FocusGuard goes online only to check for updates, to fetch site icons from the sites themselves, and for Spotify, Todoist, Linear, GitHub, Jira and Slack when you use them.")
        case (false, false):
            return String(localized: "Your activity is stored on this Mac. FocusGuard goes online only to check for updates, to fetch site icons from the sites themselves, and for Spotify, Todoist, Linear, GitHub and Jira when you use them.")
        }
    }

    /// For onboarding's welcome step.
    static var short: String {
        AISettings.isAvailable
            ? String(localized: "It's recorded only here. FocusGuard goes online just for updates, site icons, and Spotify, Todoist, Linear, GitHub or Jira if you use them. AI tips, if you turn them on, send a short summary.")
            : String(localized: "It's recorded only here. FocusGuard goes online just for updates, site icons, and Spotify, Todoist, Linear, GitHub or Jira if you use them.")
    }
}

/// What's worked out on this Mac, naming only the Pro AI that has shipped.
enum PrivacyNote {
    /// "What it keeps", under Pick up where you left off.
    static var pickUp: String {
        String(localized: "It uses the activity FocusGuard already tracks, from the past 7 days, only on this Mac. Private windows and titles you've excluded are left out. Safari doesn't say which of its windows are private, so those can't be left out.")
    }

    static var onThisMac: String {
        make(smartCategories: FeatureFlags.smartCategories, debrief: FeatureFlags.debrief, coach: FeatureFlags.coach,
             ask: FeatureFlags.ask, monthlyReview: FeatureFlags.monthlyReview)
    }

    static func make(smartCategories: Bool, debrief: Bool, coach: Bool, ask: Bool = false,
                     monthlyReview: Bool = false) -> String {
        // The first item starts the sentence, so it has its own capitalised key.
        var parts: [String] = smartCategories
            ? [String(localized: "Smart categories", comment: "Starts a sentence: Smart categories, highlights and session names are worked out on this Mac"), String(localized: "highlights", comment: "In a list, not first: Smart categories, highlights and session names are worked out on this Mac")]
            : [String(localized: "Highlights", comment: "Starts a sentence: Highlights and session names are worked out on this Mac")]
        parts.append(String(localized: "session names", comment: "In a list of things worked out on this Mac"))
        if debrief { parts += [String(localized: "debriefs", comment: "In a list of things worked out on this Mac"), String(localized: "your week", comment: "In a list of things worked out on this Mac")] }
        if coach { parts.append(String(localized: "the weekly coach", comment: "In a list of things worked out on this Mac")) }
        if ask { parts.append(String(localized: "answers in Ask", comment: "In a list of things worked out on this Mac")) }
        if monthlyReview { parts.append(String(localized: "the month in review", comment: "In a list of things worked out on this Mac")) }
        return String(localized: "\(HabitFormat.list(parts)) are worked out on this Mac.", comment: "The list is features, like: Highlights and session names")
    }
}
