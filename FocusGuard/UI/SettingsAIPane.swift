import SwiftUI

/// Settings → AI. Configures the optional, opt-in focus-insights feature:
/// provider, model, credentials (stored in the Keychain), and a connection
/// test. Mirrors the layout helpers used by the other settings panes.
struct SettingsAIPane: View {
    @State private var settings = AISettings.load()
    @State private var secret = ""                 // never pre-filled from Keychain
    @State private var secretSaved = false
    @State private var showDisclosure = false

    @State private var testing = false
    @State private var testResult: TestResult?

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("AI Insights")
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                Text("Optional AI coaching from your focus data. Off by default.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                statusBanner

                sectionHeader("Enable", topPad: 20)
                groupCard {
                    settingsRow(title: "Generate AI insights",
                                help: "Adds a “Generate insights” button to Reports. Data is sent only when you click it.") {
                        Toggle("", isOn: $settings.enabled)
                            .toggleStyle(.switch).labelsHidden()
                            .onChange(of: settings.enabled) { _, on in
                                persist()
                                // Give immediate feedback: verify the saved
                                // credential the moment AI is switched on.
                                if on && secretSaved { runTest() } else { testResult = nil }
                            }
                    }
                }

                if settings.enabled {
                    providerSection
                    credentialSection
                    disclosureSection
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: settings.provider) { _, _ in
            // Default the model to the new provider's default, refresh secret state.
            settings.model = settings.provider.defaultModel
            persist()
            refreshSecretState()
            testResult = nil
        }
        .onChange(of: settings.anthropicAuth) { _, _ in
            persist(); refreshSecretState(); testResult = nil
        }
        .onAppear(perform: refreshSecretState)
    }

    // MARK: - Status banner

    private struct Status { let symbol: String; let color: Color; let text: String }

    private var status: Status {
        if !settings.enabled {
            return Status(symbol: "moon.zzz.fill", color: .gray, text: "AI insights are off.")
        }
        if !secretSaved {
            return Status(symbol: "key.fill", color: Theme.warning,
                          text: "Enabled — add a \(secretLabel.lowercased()) below to start.")
        }
        switch testResult {
        case .success:
            return Status(symbol: "checkmark.seal.fill", color: Theme.focus,
                          text: "Connected to \(settings.provider.label). Use “Generate insights” on Reports.")
        case .failure(let message):
            return Status(symbol: "exclamationmark.triangle.fill", color: Theme.distraction, text: message)
        case nil:
            return Status(symbol: "checkmark.circle.fill", color: Theme.focus,
                          text: "\(secretLabel) saved (\(settings.provider.label)). Run Test to verify.")
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            if testing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.symbol).foregroundStyle(status.color)
            }
            Text(testing ? "Checking connection…" : status.text)
                .font(.system(size: 12)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((testing ? Color.gray : status.color).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 16)
    }

    // MARK: - Provider

    private var providerSection: some View {
        Group {
            sectionHeader("Provider")
            groupCard {
                settingsRow(title: "Service",
                            help: "Anthropic uses Claude; OpenAI-compatible works with OpenRouter, Groq, Ollama, and more.") {
                    Picker("", selection: $settings.provider) {
                        ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 180)
                }
                Rectangle().fill(Theme.separator).frame(height: 0.5)
                settingsRow(title: "Model") {
                    TextField(settings.provider.defaultModel, text: $settings.model)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit(persist)
                }
                if settings.provider == .openAICompatible {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    settingsRow(title: "Base URL",
                                help: "Origin only, e.g. http://localhost:11434 for Ollama.") {
                        TextField(OpenAIProvider.defaultBaseURL, text: $settings.baseURL)
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                            .onSubmit(persist)
                    }
                }
            }
        }
    }

    // MARK: - Credentials

    @ViewBuilder
    private var credentialSection: some View {
        sectionHeader("Credentials")
        groupCard {
            if settings.provider == .anthropic {
                settingsRow(title: "Authentication",
                            help: anthropicAuthHelp + " Only the selected method is used for requests.") {
                    Picker("", selection: $settings.anthropicAuth) {
                        ForEach(AnthropicAuthMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 180)
                }
                Rectangle().fill(Theme.separator).frame(height: 0.5)
            }

            settingsRow(title: secretLabel,
                        help: secretSaved ? "Saved to your Keychain." : "Stored only in the macOS Keychain — never synced or logged.") {
                HStack(spacing: 8) {
                    SecureField(secretSaved ? "••••••••" : "Paste here", text: $secret)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit(saveSecret)
                    Button("Save", action: saveSecret)
                        .disabled(secret.isEmpty)
                    if secretSaved {
                        Button(role: .destructive) {
                            KeychainStore.delete(account: settings.keychainAccount)
                            secret = ""; refreshSecretState(); testResult = nil
                        } label: { Image(systemName: "trash") }
                        .help("Remove the saved credential.")
                    }
                }
            }

            Rectangle().fill(Theme.separator).frame(height: 0.5)
            settingsRow(title: "Test connection",
                        help: "Sends a one-token request to verify the credential.") {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    testResultBadge
                    Button("Test", action: runTest)
                        .disabled(testing || !secretSaved)
                }
            }
        }
    }

    @ViewBuilder
    private var testResultBadge: some View {
        switch testResult {
        case .success:
            Label("OK", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).font(.system(size: 11))
                .foregroundStyle(Theme.focus)
        case .failure(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).font(.system(size: 11))
                .foregroundStyle(Theme.distraction).lineLimit(2)
                .frame(maxWidth: 220, alignment: .trailing)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Disclosure

    private var disclosureSection: some View {
        Group {
            sectionHeader("Privacy")
            groupCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("FocusGuard only sends an aggregated summary — minutes, percentages, streaks, and the names/hosts of your top distractions. It never sends window titles, full URLs, or raw activity.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(showDisclosure ? "Hide example payload" : "Show example payload") {
                        showDisclosure.toggle()
                    }
                    .buttonStyle(.link).font(.system(size: 11.5))
                    if showDisclosure {
                        Text(examplePayload)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.fill3, in: RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Helpers

    private var secretLabel: String {
        switch settings.provider {
        case .anthropic:
            return settings.anthropicAuth == .subscription ? "Subscription token" : "API key"
        case .openAI, .openAICompatible:
            return "API key"
        }
    }

    private var anthropicAuthHelp: String {
        settings.anthropicAuth == .subscription
            ? "Use a Claude Pro/Max subscription. Generate a token with `claude setup-token` and paste it below."
            : "A console API key from console.anthropic.com (pay-as-you-go)."
    }

    private var examplePayload: String {
        FocusSummaryBuilder.summary(.init(
            rangeLabel: "Today",
            breakdown: BreakdownSnapshot(focus: 95 * 60, neutral: 40 * 60, distraction: 120 * 60),
            distractions: [
                DistractionEntry(kind: .generic, name: "twitter.com", subtitle: "twitter.com",
                                 seconds: 60 * 60, fractionOfTotal: 0.5, host: "twitter.com", bundleId: "com.apple.Safari"),
                DistractionEntry(kind: .generic, name: "youtube.com", subtitle: "youtube.com",
                                 seconds: 40 * 60, fractionOfTotal: 0.33, host: "youtube.com", bundleId: "com.apple.Safari"),
            ],
            currentStreak: 3,
            weeklyAverageFocusSeconds: 110 * 60
        ))
    }

    private func persist() { settings.save() }

    private func refreshSecretState() {
        secretSaved = settings.hasSecret
    }

    private func saveSecret() {
        guard !secret.isEmpty else { return }
        KeychainStore.set(secret, account: settings.keychainAccount)
        secret = ""
        refreshSecretState()
        testResult = nil
        // Immediately verify so the user gets a clear Connected ✓ / error
        // signal right after saving — no guessing whether it works.
        if settings.enabled { runTest() }
    }

    private func runTest() {
        guard let provider = settings.makeProvider() else {
            testResult = .failure(LLMError.missingCredential.localizedDescription); return
        }
        testing = true
        testResult = nil
        Task {
            do {
                _ = try await provider.complete(system: "Reply with the single word: ok",
                                                user: "ping", maxTokens: 5)
                testResult = .success
            } catch {
                let msg = (error as? LLMError)?.localizedDescription ?? error.localizedDescription
                testResult = .failure(msg)
            }
            testing = false
        }
    }

    // MARK: - Layout helpers (mirrors the other settings panes)

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
                        .lineLimit(3)
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
