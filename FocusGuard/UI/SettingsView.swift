import SwiftUI

/// The nine settings panes, in the order the sub-nav shows them.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, sessions, blocking, limits, notifications, integrations, privacy, pro, about
    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:       return "General"
        case .sessions:      return "Sessions"
        case .blocking:      return "Blocking"
        case .limits:        return "Daily limits"
        case .notifications: return "Notifications"
        case .integrations:  return "Integrations"
        case .privacy:       return "Privacy & data"
        case .pro:           return "Pro & licence"
        case .about:         return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general:       return "Changes save straight away."
        case .sessions:      return "Names, defaults, and how hard FocusGuard pushes back."
        case .blocking:      return "What happens when you stay on a distracting site. Levels add up."
        case .limits:        return "A little of a site each day, then it pauses. Counts in and out of sessions."
        case .notifications: return "Few, quiet, and never with a sound."
        case .integrations:  return "Let your calendar, macOS and your other apps start and show your sessions."
        case .privacy:       return "What FocusGuard keeps, what leaves your Mac, and how to take it all back."
        case .pro:           return "Your plan, your trial and your licence key."
        case .about:         return ""
        }
    }

    var glyph: String {
        switch self {
        case .general:       return "gearshape.fill"
        case .sessions:      return "timer"
        case .blocking:      return "shield.fill"
        case .limits:        return "hourglass"
        case .notifications: return "bell.fill"
        case .integrations:  return "puzzlepiece.extension.fill"
        case .privacy:       return "lock.fill"
        case .pro:           return "star.fill"
        case .about:         return "info.circle.fill"
        }
    }
}

/// Settings inside the main window: a sub-nav of panes and the picked one
/// beside it, in two columns of grouped rows.
struct SettingsView: View {
    @Bindable var appState: AppState
    @Binding var pane: SettingsPane

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.44)
                    .foregroundStyle(Theme.primaryText)
                    .frame(height: 60, alignment: .center)
                    .accessibilityAddTraits(.isHeader)
                ForEach(SettingsPane.allCases) { item in navRow(item) }
                Spacer(minLength: 0)
            }
            .frame(width: 196)

            VStack(alignment: .leading, spacing: 12) {
                if pane != .about {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pane.label).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
                            .accessibilityAddTraits(.isHeader)
                        Text(pane.subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    .frame(height: 60, alignment: .center)
                }
                ScrollView {
                    content
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general:       SettingsGeneralPane(appState: appState)
        case .sessions:      SettingsSessionsPane(appState: appState)
        case .blocking:      SettingsBlockingPane(appState: appState)
        case .limits:        SettingsLimitsPane(appState: appState)
        case .notifications: SettingsNotificationsPane(appState: appState)
        case .integrations:  SettingsIntegrationsPane(appState: appState)
        case .privacy:       SettingsPrivacyPane(appState: appState)
        case .pro:           SettingsProPane()
        case .about:         SettingsAboutPane(updater: appState.updater)
        }
    }

    private func navRow(_ item: SettingsPane) -> some View {
        let selected = pane == item
        return Button { pane = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Theme.focusFill : Theme.neutral))
                Text(item.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.focusTint : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - General

struct SettingsGeneralPane: View {
    @Bindable var appState: AppState
    @ObservedObject private var updater: UpdaterController
    @State private var launchAtLogin = LoginItemController.isEnabled
    @AppStorage(SettingsKeys.showInDock) private var showInDock = true
    @AppStorage(SettingsKeys.menuBarShowTime) private var menuBarShowTime = true
    @AppStorage(SettingsKeys.reduceMotion) private var reduceMotion = false
    @AppStorage(SettingsWindowKey.appearance) private var appearance = AppAppearance.system.rawValue

    init(appState: AppState) {
        self._appState = Bindable(wrappedValue: appState)
        self._updater = ObservedObject(wrappedValue: appState.updater)
    }

    var body: some View {
        SettingsColumns {
            SettingsSection("Startup and menu bar") {
                SettingsToggle(title: "Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        LoginItemController.setEnabled(value)
                        launchAtLogin = LoginItemController.isEnabled
                    }))
                SettingsDivider()
                SettingsToggle(title: "Show in the Dock", detail: "Off keeps FocusGuard in the menu bar only", isOn: $showInDock)
                SettingsDivider()
                SettingsToggle(title: "Show time in the menu bar", detail: "Minutes left next to the shield", isOn: $menuBarShowTime)
            }
            SettingsSection("Look and language") {
                SettingsRow(title: "Appearance") {
                    SettingsSegments(options: AppAppearance.allCases.map { ($0.rawValue, $0.title) },
                                     selection: Binding(get: { appearance }, set: { value in
                                         appearance = value
                                         AppAppearance.applyStored()
                                     }))
                }
                SettingsDivider()
                SettingsRow(title: "Language", detail: "Deutsch and Azərbaycan dili are on the way") {
                    Text("English").font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                }
                if reduceMotion {
                    // The old in-app switch, kept only so it can be turned off.
                    SettingsDivider()
                    SettingsToggle(title: "Reduce motion in FocusGuard",
                                   detail: "Turn off to follow the system setting", isOn: $reduceMotion)
                }
            }
        } right: {
            SettingsSection("Updates") {
                SettingsToggle(title: "Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticChecks($0) }))
                SettingsDivider()
                SettingsRow(title: "FocusGuard \(AppVersion.short)", detail: UpdateWords.lastChecked()) {
                    Button("Check now") { updater.checkForUpdates() }
                        .buttonStyle(.capsule(.secondary, height: 26))
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            SettingsNote(systemImage: "figure.walk.motion",
                         text: "Animations follow Reduce motion in System Settings › Accessibility › Display.")
        }
    }
}

/// The app's version, as About and diagnostics show it.
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    /// "0.1.0 (1)".
    static var full: String { "\(short) (\(build))" }
}

/// "Last checked today at 09:02", from Sparkle's own record.
enum UpdateWords {
    static func lastChecked(_ date: Date? = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date,
                            now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "Not checked yet" }
        let time = WindowFormat.clock(date)
        if calendar.isDate(date, inSameDayAs: now) { return "Last checked today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Last checked yesterday at \(time)"
        }
        return "Last checked \(date.formatted(.dateTime.day().month(.wide))) at \(time)"
    }
}

// MARK: - About

struct SettingsAboutPane: View {
    @ObservedObject var updater: UpdaterController
    var entitlements: Entitlements = .shared

    private static let repo = URL(string: "https://github.com/anarzone/FocusGuard")!

    var body: some View {
        VStack(spacing: 12) {
            AppGlyph(kind: .focusguard, size: 84)
                .padding(.top, 36)
                .accessibilityLabel("FocusGuard app icon")
            Text("FocusGuard")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("Version \(AppVersion.full) · \(planLine)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 10) {
                Text(UpdateWords.lastChecked()).font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                Button("Check for updates") { updater.checkForUpdates() }
                    .buttonStyle(.capsule(.secondary, height: 26))
                    .disabled(!updater.canCheckForUpdates)
            }
            .padding(.top, 4)
            Text(PrivacyStatement.network)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 14)
            Button("Privacy & data") {
                NotificationCenter.default.post(name: .selectSettingsPane, object: SettingsPane.privacy)
            }
            .buttonStyle(.textLink)
            HStack(spacing: 18) {
                Button("Help") { NSWorkspace.shared.open(Self.repo) }
                Button("Send feedback") { NSWorkspace.shared.open(Self.repo.appendingPathComponent("issues/new")) }
                Button("Acknowledgements") { NSWorkspace.shared.open(URL(string: "https://sparkle-project.org")!) }
            }
            .buttonStyle(.textLink)
            .padding(.top, 10)
            Text("© 2026 Anar Haqverdiyev")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var planLine: String {
        switch entitlements.plan {
        case .free: return "Free"
        case .pro: return "Pro"
        case .trial: return "Pro trial, \(WindowFormat.count(entitlements.plan.daysLeft(at: .now) ?? 0, "day")) left"
        }
    }
}
