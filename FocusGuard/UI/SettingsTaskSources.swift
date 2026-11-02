import AppKit
import SwiftUI

// Settings › Integrations › Tasks as session goals, after Reminders:
// Things (when it's installed), Todoist, Linear, GitHub and Jira, each its
// own switch. All but Things take a personal token, kept in the Keychain;
// Jira takes its site and email too. GitHub and Linear offer signing in first
// once their apps are registered (`SettingsTaskSignIn`).

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

/// Things, Todoist, Linear, GitHub and Jira, under Reminders.
struct TaskSourceRows: View {
    let integrations: IntegrationsCoordinator
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet

    @AppStorage(IntegrationSettings.things) private var thingsOn = false
    @AppStorage(IntegrationSettings.todoist) private var todoistOn = false
    @AppStorage(IntegrationSettings.linear) private var linearOn = false
    @AppStorage(IntegrationSettings.github) private var githubOn = false
    @AppStorage(IntegrationSettings.jira) private var jiraOn = false

    @State private var thingsInstalled = ThingsTasks.isInstalled
    /// Sources with a token saved.
    @State private var connected: Set<TaskSource>
    /// Those connected by signing in, not with a pasted token.
    @State private var signedIn: Set<TaskSource> = []
    /// Those whose service ended the sign-in.
    @State private var signedOut: Set<TaskSource> = []
    /// Those showing the token field although signing in is offered.
    @State private var usingToken: Set<TaskSource> = []
    /// What's typed in each token field.
    @State private var typed: [TaskSource: String] = [:]
    /// Jira's site and email, typed above its token.
    @State private var jiraSite = ""
    @State private var jiraEmail = ""
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
                TaskSourceRow(source: .things, detail: String(localized: "Your Today list, while Things is open")) {
                    sourceSwitch(.things, isOn: $thingsOn)
                }
                if thingsOn && unlocked && integrations.taskProblems[.things] == .notAllowed {
                    SettingsDivider()
                    SettingsRow(title: String(localized: "Access to Things is off"),
                                detail: String(localized: "Turn it on in System Settings › Privacy & Security › Automation")) {
                        Button("Open Settings") { SettingsIntegrationsPane.openPrivacy("Automation") }
                            .buttonStyle(.capsule(.secondary, height: 26))
                    }
                }
            }
            SettingsDivider()
            TaskSourceRow(source: .todoist, detail: String(localized: "Tasks due today or overdue")) {
                sourceSwitch(.todoist, isOn: $todoistOn)
            }
            if todoistOn && unlocked { tokenRow(.todoist) }
            SettingsDivider()
            TaskSourceRow(source: .linear, detail: String(localized: "Issues assigned to you, moved to done when you finish")) {
                sourceSwitch(.linear, isOn: $linearOn)
            }
            if linearOn && unlocked { connectionRow(.linear) }
            SettingsDivider()
            TaskSourceRow(source: .github, detail: String(localized: "Open issues assigned to you, closed when you finish")) {
                sourceSwitch(.github, isOn: $githubOn)
            }
            if githubOn && unlocked { connectionRow(.github) }
            SettingsDivider()
            TaskSourceRow(source: .jira, detail: String(localized: "Issues assigned to you, moved to done when you finish")) {
                sourceSwitch(.jira, isOn: $jiraOn)
            }
            if jiraOn && unlocked { tokenRow(.jira) }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .onChange(of: integrations.taskProblems) { reload() }
        .onChange(of: integrations.githubSignIn?.phase) { reload() }
        .onChange(of: integrations.linearSignIn?.phase) { reload() }
    }

    private func reload() {
        thingsInstalled = ThingsTasks.isInstalled
        connected = Self.savedTokens(in: integrations)
        signedIn = connected.filter { integrations.isSignedIn($0) }
        signedOut = Set([TaskSource.linear, .github].filter { integrations.wasSignedOut($0) })
    }

    private static func savedTokens(in integrations: IntegrationsCoordinator) -> Set<TaskSource> {
        Set([TaskSource.todoist, .linear, .github, .jira].filter { integrations.isConnected($0) })
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

    // MARK: - Signing in

    /// Signing in when it's offered; otherwise, or by choice, the token field.
    @ViewBuilder
    private func connectionRow(_ source: TaskSource) -> some View {
        if integrations.offersSignIn(source) && !connected.contains(source) && !usingToken.contains(source) {
            SettingsDivider()
            if source == .github, let signIn = integrations.githubSignIn {
                GitHubSignInRow(signIn: signIn, signedOut: signedOut.contains(source)) { usingToken.insert(source) }
            } else if source == .linear, let signIn = integrations.linearSignIn {
                LinearSignInRow(signIn: signIn, signedOut: signedOut.contains(source)) { usingToken.insert(source) }
            }
        } else {
            tokenRow(source)
            if source == .github && signedIn.contains(source) {
                GitHubAccessRow(integrations: integrations, installURL: integrations.githubSignIn?.installURL)
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
                    Text(rejected ? rejectedTitle(source) : connectedTitle(source))
                        .font(.system(size: 13))
                        .foregroundStyle(rejected ? Theme.distraction : Theme.primaryText)
                    Text(connectedDetail(source, rejected: rejected))
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
                if source == .jira {
                    TextField(String(localized: "Site, like acme.atlassian.net"), text: jiraBinding($jiraSite))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    TextField(String(localized: "Your Atlassian email"), text: jiraBinding($jiraEmail))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                HStack(spacing: 8) {
                    SecureField(Self.placeholder(source), text: tokenBinding(source))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect(source) }
                    if connecting == source {
                        ProgressView().controlSize(.small)
                    }
                    Button("Connect") { connect(source) }
                        .buttonStyle(.capsule(.secondary, height: 26))
                        .disabled(connecting != nil || !isReady(source))
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
                if integrations.offersSignIn(source) {
                    Button("Sign in instead") { usingToken.remove(source) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
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

    private func jiraBinding(_ field: Binding<String>) -> Binding<String> {
        Binding(get: { field.wrappedValue }, set: { text in
            field.wrappedValue = text
            checks[.jira] = nil
        })
    }

    private func connectedTitle(_ source: TaskSource) -> String {
        guard source == .jira, let site = integrations.jiraAccount?.site else { return String(localized: "Connected") }
        return String(localized: "Connected to \(site)")
    }

    private func rejectedTitle(_ source: TaskSource) -> String {
        signedIn.contains(source)
            ? String(localized: "\(source.name) no longer takes this sign-in")
            : String(localized: "\(source.name) no longer takes this token")
    }

    private func connectedDetail(_ source: TaskSource, rejected: Bool) -> String {
        switch (rejected, signedIn.contains(source)) {
        case (true, true):   return String(localized: "Disconnect, then connect again")
        case (true, false):  return String(localized: "Disconnect, then paste a new one")
        case (false, true):  return String(localized: "Your sign-in is in your Keychain")
        case (false, false): return String(localized: "The token is in your Keychain")
        }
    }

    /// Everything Connect needs is filled in.
    private func isReady(_ source: TaskSource) -> Bool {
        var fields = [typed[source] ?? ""]
        if source == .jira { fields += [jiraSite, jiraEmail] }
        return fields.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func connect(_ source: TaskSource) {
        let token = (typed[source] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady(source), connecting == nil else { return }
        connecting = source
        Task {
            let check = source == .jira
                ? await integrations.connectJira(site: jiraSite, email: jiraEmail, token: token)
                : await integrations.connect(source, token: token)
            connecting = nil
            checks[source] = check
            if check == .accepted {
                typed[source] = nil
                reload()
            }
        }
    }

    private func disconnect(_ source: TaskSource) {
        // Left in the fields, so a new token is all it takes.
        if source == .jira, let account = integrations.jiraAccount {
            jiraSite = account.site
            jiraEmail = account.email
        }
        integrations.disconnect(source)
        checks[source] = nil
        reload()
    }

    // MARK: - Copy

    static func placeholder(_ source: TaskSource) -> String {
        switch source {
        case .linear: return String(localized: "Paste your API key")
        case .github: return String(localized: "Paste your access token")
        default:      return String(localized: "Paste your API token")
        }
    }

    /// Where to get the token.
    static func hint(_ source: TaskSource) -> String {
        switch source {
        case .todoist: return String(localized: "From Todoist › Settings › Integrations › Developer. Kept in your Keychain.")
        case .linear:  return String(localized: "From Linear › Settings › Security & access › Personal API keys. Kept in your Keychain.")
        case .github:  return String(localized: "From github.com/settings/tokens. A fine-grained token covers one owner's repositories and needs Issues: Read and write; a classic token needs repo. Kept in your Keychain.")
        case .jira:    return String(localized: "From id.atlassian.com › Security › API tokens. Choose Create API token, not the one with scopes. Kept in your Keychain.")
        default:       return ""
        }
    }

    /// The line under the field after Connect, when it didn't work.
    static func failure(_ check: TokenCheck?, source: TaskSource) -> String? {
        switch check {
        case .rejected:
            return source == .linear
                ? String(localized: "\(source.name) didn't take that key. Check it and try again.")
                : String(localized: "\(source.name) didn't take that token. Check it and try again.")
        case .unreachable: return String(localized: "Couldn't reach \(source.name). Check your connection and try again.")
        case .badSite:     return String(localized: "That's not a Jira Cloud site. Use an address like acme.atlassian.net.")
        default:           return nil
        }
    }
}
