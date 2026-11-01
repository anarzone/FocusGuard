import AppKit
import SwiftUI

// Settings › Integrations › Tasks as session goals, after Reminders:
// Things (when it's installed), Todoist and Linear, each its own switch.
// Todoist and Linear take a personal token, kept in the Keychain.

/// A task source's row: its letter, its name and a line on what it
/// offers, and its switch.
struct TaskSourceRow<Trailing: View>: View {
    let source: TaskSource
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(String(source.name.prefix(1)))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.primaryText.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// Things, Todoist and Linear, under Reminders.
struct TaskSourceRows: View {
    let integrations: IntegrationsCoordinator
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet

    @AppStorage(IntegrationSettings.things) private var thingsOn = false
    @AppStorage(IntegrationSettings.todoist) private var todoistOn = false
    @AppStorage(IntegrationSettings.linear) private var linearOn = false

    @State private var thingsInstalled = ThingsTasks.isInstalled
    /// Sources with a token saved.
    @State private var connected: Set<TaskSource>
    /// What's typed in each token field.
    @State private var typed: [TaskSource: String] = [:]
    @State private var connecting: TaskSource?
    /// How the last Connect went, until the field changes.
    @State private var checks: [TaskSource: TokenCheck] = [:]

    init(integrations: IntegrationsCoordinator, entitlements: Entitlements = .shared) {
        self.integrations = integrations
        self.entitlements = entitlements
        _connected = State(initialValue: Self.savedTokens(in: integrations))
    }

    private var unlocked: Bool { entitlements.isUnlocked(.taskGoals) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if thingsInstalled {
                SettingsDivider()
                TaskSourceRow(source: .things, detail: "Your Today list, while Things is open") {
                    sourceSwitch(.things, isOn: $thingsOn)
                }
                if thingsOn && unlocked && integrations.taskProblems[.things] == .notAllowed {
                    SettingsDivider()
                    SettingsRow(title: "Access to Things is off",
                                detail: "Turn it on in System Settings › Privacy & Security › Automation") {
                        Button("Open Settings") { SettingsIntegrationsPane.openPrivacy("Automation") }
                            .buttonStyle(.capsule(.secondary, height: 26))
                    }
                }
            }
            SettingsDivider()
            TaskSourceRow(source: .todoist, detail: "Tasks due today or overdue") {
                sourceSwitch(.todoist, isOn: $todoistOn)
            }
            if todoistOn && unlocked { tokenRow(.todoist) }
            SettingsDivider()
            TaskSourceRow(source: .linear, detail: "Issues assigned to you, moved to done when you finish") {
                sourceSwitch(.linear, isOn: $linearOn)
            }
            if linearOn && unlocked { tokenRow(.linear) }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func reload() {
        thingsInstalled = ThingsTasks.isInstalled
        connected = Self.savedTokens(in: integrations)
    }

    private static func savedTokens(in integrations: IntegrationsCoordinator) -> Set<TaskSource> {
        Set([TaskSource.todoist, .linear].filter { integrations.isConnected($0) })
    }

    // MARK: - Switches

    /// The switch, or Get Pro once the trial's used.
    @ViewBuilder
    private func sourceSwitch(_ source: TaskSource, isOn: Binding<Bool>) -> some View {
        if unlocked || entitlements.canStartTrial {
            Toggle(source.name, isOn: Binding(get: { isOn.wrappedValue && unlocked }, set: { on in
                turn(source, on: on, isOn: isOn)
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(Theme.focusFill)
        } else {
            Button("Get Pro") { openSheet(.upgrade(.taskGoals)) }
                .buttonStyle(.capsule(.secondary, height: 26))
        }
    }

    private func turn(_ source: TaskSource, on: Bool, isOn: Binding<Bool>) {
        if on && !unlocked { entitlements.startTrialIfNeeded(for: .taskGoals) }
        guard !on || unlocked else { return }
        isOn.wrappedValue = on
        Task {
            // Things asks macOS once, the first time it's read.
            if on && source == .things {
                await integrations.requestThingsAccess()
            } else {
                await integrations.refreshTasks()
            }
        }
    }

    // MARK: - Tokens

    @ViewBuilder
    private func tokenRow(_ source: TaskSource) -> some View {
        SettingsDivider()
        if connected.contains(source) {
            let rejected = integrations.taskProblems[source] == .rejected
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rejected ? "\(source.name) no longer takes this token" : "Connected")
                        .font(.system(size: 13))
                        .foregroundStyle(rejected ? Theme.distraction : Theme.primaryText)
                    Text(rejected ? "Disconnect, then paste a new one" : "The token is in your Keychain")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Disconnect") { disconnect(source) }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SecureField(Self.placeholder(source), text: tokenBinding(source))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect(source) }
                    if connecting == source {
                        ProgressView().controlSize(.small)
                    }
                    Button("Connect") { connect(source) }
                        .buttonStyle(.capsule(.secondary, height: 26))
                        .disabled(connecting != nil || (typed[source] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let failed = Self.failure(checks[source], source: source) {
                    Text(failed)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.distraction)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Self.hint(source))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func tokenBinding(_ source: TaskSource) -> Binding<String> {
        Binding(get: { typed[source] ?? "" }, set: { text in
            typed[source] = text
            checks[source] = nil
        })
    }

    private func connect(_ source: TaskSource) {
        let token = (typed[source] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, connecting == nil else { return }
        connecting = source
        Task {
            let check = await integrations.connect(source, token: token)
            connecting = nil
            checks[source] = check
            if check == .accepted {
                typed[source] = nil
                reload()
            }
        }
    }

    private func disconnect(_ source: TaskSource) {
        integrations.disconnect(source)
        checks[source] = nil
        reload()
    }

    // MARK: - Copy

    static func placeholder(_ source: TaskSource) -> String {
        source == .linear ? "Paste your API key" : "Paste your API token"
    }

    /// Where to get the token.
    static func hint(_ source: TaskSource) -> String {
        switch source {
        case .todoist: return "From Todoist › Settings › Integrations › Developer. Kept in your Keychain."
        case .linear:  return "From Linear › Settings › Security & access › Personal API keys. Kept in your Keychain."
        default:       return ""
        }
    }

    /// The line under the field after Connect, when it didn't work.
    static func failure(_ check: TokenCheck?, source: TaskSource) -> String? {
        switch check {
        case .rejected:    return "\(source.name) didn't take that \(source == .linear ? "key" : "token"). Check it and try again."
        case .unreachable: return "Couldn't reach \(source.name). Check your connection and try again."
        default:           return nil
        }
    }
}
