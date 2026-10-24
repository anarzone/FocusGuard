import SwiftData
import SwiftUI

/// Blocking: the three levels (Pause the tab free, Block in the browser
/// Pro, Block on the whole Mac coming later), the extension, and how
/// letting yourself through works.
struct SettingsBlockingPane: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared

    @AppStorage(SettingsWindowKey.pauseTab) private var pauseTab = true
    @Environment(\.openWindowSheet) private var openSheet
    @State private var distractingCount = 0

    var body: some View {
        SettingsColumns {
            SettingsSection("How FocusGuard blocks") {
                level(1, title: "Pause the tab", badge: AnyView(FreeBadge()),
                      body: "When the pause screen shows, the tab switches to a calm FocusGuard page and any video stops.",
                      foot: "Safari, Chrome, Arc, Brave and Edge · quicker with the free extension") {
                    Toggle("Pause the tab", isOn: Binding(get: { pauseTab }, set: { on in
                        pauseTab = on
                        appState.tabPause.isEnabled = on
                    }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.focusFill)
                }
                SettingsDivider()
                browserLevel
                SettingsDivider()
                level(3, title: "Block on the whole Mac", badge: AnyView(HStack(spacing: 4) { ProBadge(); ComingLaterBadge() }),
                      body: "Every browser and app, private windows and new browsers too. Whole sites only.",
                      foot: "It needs a content filter signed by Apple, which comes in a later version") { EmptyView() }
            }
            SettingsSection(title: "Browser extension", trailing: { FreeBadge() }) {
                ExtensionStatusRows(appState: appState)
            }
            SettingsNote(text: "Free: sharper tracking, and tabs pause straight away. Pro adds blocking before pages load. Adding it never starts a trial.")
        } right: {
            SettingsSection("When it blocks") {
                SettingsRow("During focus sessions", detail: "After the pause screen appears, by your preset")
                SettingsDivider()
                SettingsRow("When a daily limit runs out", detail: "Any time of day, until midnight")
            }
            SettingsSection("Letting yourself through") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("“Let me through” follows your preset. Every pass lasts 2 minutes and counts as drift.")
                        .font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                    presetLine(.gentle, "Right away")
                    presetLine(.standard, "After a 5-second wait")
                    presetLine(.strict, "Never. “It's for work” unlocks after 10 s")
                    Button("Change preset") {
                        NotificationCenter.default.post(name: .selectSettingsPane, object: SettingsPane.sessions)
                    }
                    .buttonStyle(.textLink)
                }
                .padding(14)
            }
            SettingsSection("What gets blocked") {
                SettingsRow(title: "Everything marked Distracting") {
                    Text("\(distractingCount)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("The pause screen covers apps such as Discord too. Blocking them before they open needs Block on the whole Mac.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Manage in Apps & Sites") {
                        NotificationCenter.default.post(name: .selectMainTab, object: MainTab.apps)
                    }
                    .buttonStyle(.textLink)
                }
                .padding(14)
            }
        }
        .task {
            let raw = Classification.distraction.rawValue
            distractingCount = Persistence.fetchCount(appState.container.mainContext,
                                                      FetchDescriptor<AppRule>(predicate: #Predicate { $0.classificationRaw == raw }))
        }
    }

    @ViewBuilder
    private var browserLevel: some View {
        let unlocked = entitlements.isUnlocked(.blockInBrowser)
        let connected = !appState.extensionBridge.connectedBrowsers.isEmpty
        if unlocked {
            level(2, title: "Block in the browser", badge: AnyView(ProBadge()),
                  body: "Distracting pages never load. Block parts of sites too, like youtube.com/shorts.",
                  foot: connected ? "On through the browser extension" : "Needs the browser extension") {
                if connected {
                    Text("On").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.bodyText)
                } else {
                    Button("Add extension") { openSheet(.browserExtension) }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            }
        } else if appState.sessionManager.currentSession != nil {
            level(2, title: "Block in the browser", badge: AnyView(ProBadge()),
                  body: "Distracting pages never load. Part of Pro.", foot: "Works through the browser extension") { EmptyView() }
        } else {
            LockedProRow(feature: .blockInBrowser, title: "Block in the browser",
                         detail: "Distracting pages never load, and parts of sites can be blocked too. Works through the browser extension.",
                         onUpgrade: { openSheet(.upgrade(.blockInBrowser)) },
                         entitlements: entitlements)
                .padding(10)
        }
    }

    private func level<Trailing: View>(_ n: Int, title: String, badge: AnyView, body: String, foot: String,
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.lockedStroke, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    badge
                }
                Text(body).font(.system(size: 12)).foregroundStyle(Theme.bodyText).fixedSize(horizontal: false, vertical: true)
                Text(foot).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }

    private func presetLine(_ response: DriftResponse, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(response.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                .frame(width: 70, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.bodyText)
            if appState.escalationEngine.preset == response {
                Text("yours").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.link)
            }
        }
    }
}

// MARK: - Daily limits

/// Daily limits: today's use of each, adding one (Free keeps one), and
/// what happens when one runs out.
struct SettingsLimitsPane: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared

    @Environment(\.openWindowSheet) private var openSheet
    @State private var candidates: [UsageRow] = []
    @State private var newSite = ""
    @State private var addingSite = false
    @State private var note: String?

    private var limits: DailyLimitsEngine { appState.limits }

    var body: some View {
        SettingsColumns {
            SettingsSection("Today") {
                if limits.statuses.isEmpty {
                    SettingsRow("No daily limits yet", detail: "Pick a site or app you'd like a little of each day")
                    SettingsDivider()
                }
                ForEach(limits.statuses) { status in
                    limitRow(status)
                    SettingsDivider()
                }
                addRow
            }
            planNote
            if let note { SettingsNote(text: note) }
        } right: {
            SettingsSection("When a limit runs out") {
                SettingsRow("The site pauses until midnight", detail: "In and out of sessions, with the pause screen")
            }
            SettingsSection("Details") {
                SettingsRow("You're warned 5 minutes before", detail: "If notifications are on")
                SettingsDivider()
                SettingsRow(title: "Limits reset at midnight", detail: "They count in and out of sessions") {
                    Text("00:00").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.bodyText)
                }
            }
            SettingsSection("Extra time") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When a limit runs out, your preset decides if you can have a little more.")
                        .font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(DriftResponse.allCases) { response in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(response.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                                .frame(width: 70, alignment: .leading)
                            Text(Self.extra(response.overridePolicy)).font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Change preset") {
                        NotificationCenter.default.post(name: .selectSettingsPane, object: SettingsPane.sessions)
                    }
                    .buttonStyle(.textLink)
                }
                .padding(14)
            }
        }
        .task {
            let now = Date.now
            candidates = MenuInsightsBuilder.usageRows(context: appState.container.mainContext,
                                                       from: AppsRange.week.start(now: now), to: now, limit: 40)
        }
    }

    static func extra(_ policy: OverridePolicy) -> String {
        let extra = policy.extraTime
        guard extra.isOffered else { return "None. Limits can only be changed for tomorrow" }
        let times = extra.timesPerDay == 1 ? "once a day" : "up to \(extra.timesPerDay) times a day"
        let wait = extra.waitSeconds > 0 ? " after a \(extra.waitSeconds)-second wait" : ""
        return "\(extra.minutes) more minutes\(wait), \(times)"
    }

    private func limitRow(_ status: LimitStatus) -> some View {
        HStack(spacing: 10) {
            WindowItemIcon(name: status.name, bundleId: status.isSite ? nil : status.target,
                           host: status.isSite ? status.target : nil, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(status.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int(status.used / 60)) of \(status.minutes + status.extraMinutes) min")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
                WindowBar(fraction: status.allowance > 0 ? status.used / status.allowance : 0,
                          color: status.isUsedUp ? Theme.distraction : Theme.focus, height: 4)
                if let pending = status.pending {
                    Text(pending == .removal ? "Goes away tomorrow" : "Changes tomorrow")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            Menu {
                ForEach([10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Button("\(minutes) min") { apply(limits.setMinutes(minutes, for: status.id)) }
                }
                Divider()
                Button("Remove limit", role: .destructive) { apply(limits.removeLimit(status.id)) }
            } label: {
                HStack(spacing: 4) {
                    Text("\(status.minutes) min")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.inset))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Limit for \(status.name): \(status.minutes) minutes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var addRow: some View {
        if LimitGate.canAdd(existing: limits.statuses.count, entitlements: entitlements) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        let taken = Set(limits.statuses.map(\.target))
                        ForEach(candidates.filter { !taken.contains($0.host ?? $0.bundleId) }.prefix(12)) { row in
                            Button(row.name) { add(row) }
                        }
                        Divider()
                        Button("Another site…") { addingSite = true }
                    } label: {
                        Label("Add a limit", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.link)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer()
                }
                if addingSite {
                    HStack(spacing: 8) {
                        TextField("reddit.com", text: $newSite)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addSite)
                        Button("Add", action: addSite)
                            .buttonStyle(.capsule(.secondary, height: 26))
                            .disabled(DailyLimitsEngine.siteTarget(newSite) == nil)
                    }
                }
            }
            .padding(14)
        } else if appState.sessionManager.currentSession != nil {
            SettingsRow("Free keeps one daily limit", detail: "More are part of Pro")
        } else {
            LockedProRow(feature: .unlimitedLimits, title: "Daily limits for any site",
                         detail: "Free keeps one daily limit. Pro sets one for every app and site.",
                         systemImage: "hourglass",
                         onUpgrade: { openSheet(.upgrade(.unlimitedLimits)) },
                         entitlements: entitlements)
                .padding(10)
        }
    }

    @ViewBuilder
    private var planNote: some View {
        switch entitlements.plan {
        case .free:
            SettingsNote(systemImage: "hourglass", text: "Free includes one daily limit. Pro sets one for every app and site.")
        case .trial(let endsAt):
            SettingsNote(systemImage: "hourglass",
                         text: "Free includes one daily limit. You're on the Pro trial until \(endsAt.formatted(.dateTime.day().month(.wide))), so you can set as many as you like.")
        case .pro:
            EmptyView()
        }
    }

    private func add(_ row: UsageRow) {
        _ = limits.addLimit(target: row.host ?? row.bundleId, isSite: row.isSite, name: row.name, minutes: 30)
    }

    private func addSite() {
        guard DailyLimitsEngine.siteTarget(newSite) != nil else { return }
        _ = limits.addLimit(target: newSite, isSite: true, minutes: 30)
        newSite = ""
        addingSite = false
    }

    private func apply(_ change: LimitChange?) {
        note = change == .fromTomorrow ? "Strict is on, so limit changes take effect tomorrow." : nil
    }
}
