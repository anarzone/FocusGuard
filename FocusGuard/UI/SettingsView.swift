import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, sessions, escalation, rules, ai, privacy, about
    var id: String { rawValue }

    /// The panes in the sidebar: AI only while the app offers it.
    static var visible: [SettingsPane] {
        allCases.filter { $0 != .ai || AISettings.isAvailable }
    }

    var label: String {
        switch self {
        case .general:    return "General"
        case .sessions:   return "Sessions"
        case .escalation: return "Escalation"
        case .rules:      return "Rules"
        case .ai:         return "AI tips"
        case .privacy:    return "Privacy"
        case .about:      return "About"
        }
    }

    var glyph: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .sessions:   return "timer"
        case .escalation: return "bell.badge.fill"
        case .rules:      return "list.bullet.rectangle.fill"
        case .ai:         return "sparkles"
        case .privacy:    return "lock.fill"
        case .about:      return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general:    return Color(red: 142/255, green: 142/255, blue: 147/255)
        case .sessions:   return Theme.focus
        case .escalation: return Theme.warning
        case .rules:      return Color(red: 94/255, green: 92/255, blue: 230/255)
        case .ai:         return Color(red: 175/255, green: 82/255, blue: 222/255)
        case .privacy:    return Color(red: 26/255, green: 115/255, blue: 232/255)
        case .about:      return Theme.distraction
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    /// Hero Numeric variant defaults to General.
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
                .background(Color.primary.opacity(0.012))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.separator).frame(width: 0.5)
                }

            Group {
                switch pane {
                case .general:    SettingsGeneralPane()
                case .sessions:   SettingsSessionsPane(appState: appState)
                case .escalation: SettingsEscalationPane(appState: appState)
                case .rules:      SettingsRulesPane(appState: appState)
                case .ai:         SettingsAIPane()
                case .privacy:    SettingsPrivacyPane(appState: appState)
                case .about:      SettingsAboutPane(updater: appState.updater)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.visible) { p in
                Button {
                    pane = p
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(p.tint)
                                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            Image(systemName: p.glyph)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 22, height: 22)

                        Text(p.label)
                            .font(.system(size: 13))
                            .foregroundStyle(pane == p ? Color.white : Color.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        pane == p ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
    }
}

// MARK: - General pane

struct SettingsGeneralPane: View {
    @State private var launchAtLogin = LoginItemController.isEnabled
    @AppStorage("reduceMotion")           private var reduceMotion    = false
    @AppStorage(SettingsKeys.showNotifications) private var showNotifications = true
    @AppStorage(SettingsKeys.menuBarShowTime) private var menuBarShowTime = true
    @AppStorage(SettingsKeys.showInDock)  private var showInDock      = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General")
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                Text("Appearance and launch behavior.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                sectionHeader("Startup", topPad: 24)
                groupCard {
                    settingsRow(title: "Launch at login",
                                help: "Open FocusGuard automatically when you sign in.") {
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch).labelsHidden()
                            .onChange(of: launchAtLogin) { _, newValue in
                                LoginItemController.setEnabled(newValue)
                                launchAtLogin = LoginItemController.isEnabled
                            }
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    settingsRow(title: "Show in Dock",
                                help: "Adds a permanent FocusGuard icon to your Dock so you can launch it without finding the menu bar item. Takes effect immediately.") {
                        Toggle("", isOn: $showInDock)
                            .toggleStyle(.switch).labelsHidden()
                    }
                }

                sectionHeader("Appearance")
                groupCard {
                    settingsRow(title: "Show time in menu bar",
                                help: "Minutes left beside the FocusGuard icon during a session or break, like “24m”.") {
                        Toggle("", isOn: $menuBarShowTime).toggleStyle(.switch).labelsHidden()
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    settingsRow(title: "Reduce motion",
                                help: "Use cross-fades instead of sliding transitions.") {
                        Toggle("", isOn: $reduceMotion).toggleStyle(.switch).labelsHidden()
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    settingsRow(title: "Show notifications",
                                help: "Drift nudges, session and break updates, and the daily wrap-up. Turn off to silence every FocusGuard notification.") {
                        Toggle("", isOn: $showNotifications).toggleStyle(.switch).labelsHidden()
                    }
                }

            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func settingsRow<Right: View>(
        title: String,
        help: String? = nil,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                if let help {
                    Text(help)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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

struct SettingsAboutPane: View {
    @ObservedObject var updater: UpdaterController

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            AppGlyph(kind: .focusguard, size: 84)
            Text("FocusGuard")
                .font(.system(size: 22, weight: .semibold))
            Text(versionString)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .controlSize(.regular)
            .disabled(!updater.canCheckForUpdates)
            .padding(.top, 8)

            Toggle("Check automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticChecks($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            Text(PrivacyStatement.network)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
