import SwiftUI

struct SettingsEscalationPane: View {
    @Bindable var appState: AppState

    @AppStorage(SettingsKeys.Escalation.silenceThreshold) private var silence: Int = Constants.Escalation.defaultSilenceSeconds
    @AppStorage(SettingsKeys.Escalation.notifyThreshold)  private var notify:  Int = Constants.Escalation.defaultNotifySeconds
    @AppStorage(SettingsKeys.Escalation.blockThreshold)   private var block:   Int = Constants.Escalation.defaultBlockSeconds
    @AppStorage(SettingsKeys.Escalation.cooldown)         private var cooldown: Int = Constants.Escalation.defaultCooldownSeconds
    @AppStorage(SettingsKeys.Escalation.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(SettingsKeys.Escalation.strictMode)       private var strictMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                stagesSection
                modeSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: combinedConfig) { _, _ in applyToEngine() }
        .onAppear { applyToEngine() }
    }

    private struct EngineConfig: Equatable {
        let silence: Int
        let notify: Int
        let cooldown: Int
        let block: Int
        let strictMode: Bool
    }

    private var combinedConfig: EngineConfig {
        EngineConfig(silence: silence, notify: notify, cooldown: cooldown, block: block, strictMode: strictMode)
    }

    private func applyToEngine() {
        let engine = appState.escalationEngine
        engine.silenceThreshold = TimeInterval(silence)
        engine.notifyThreshold  = TimeInterval(notify)
        engine.notifyCooldown   = TimeInterval(cooldown)
        engine.blockThreshold   = TimeInterval(block)
        engine.strictMode       = strictMode
    }

    private var header: some View {
        Group {
            Text("Escalation")
                .font(.system(size: 26, weight: .bold))
                .kerning(-0.5)
            Text("How FocusGuard responds when distraction is detected during a focus session.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var stagesSection: some View {
        Group {
            sectionLabel("STAGES")
            groupCard {
                silenceRow
                divider
                notificationToggleRow
                divider
                notifyThresholdRow
                divider
                cooldownRow
                divider
                blockThresholdRow
            }
        }
    }

    private var modeSection: some View {
        Group {
            sectionLabel("MODE")
            groupCard {
                strictModeRow
                divider
                testNotificationRow
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    // MARK: - Rows

    private var silenceRow: some View {
        settingsRow(
            title: "Silence threshold",
            help: "No action below this duration. Distractions are still logged."
        ) {
            Stepper(value: $silence, in: 0...300, step: 5) {
                Text("\(silence) sec")
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private var notificationToggleRow: some View {
        settingsRow(
            title: "Motivational notification",
            help: "Send a calm reminder once distraction crosses the next threshold."
        ) {
            Toggle("", isOn: $notificationsEnabled)
                .toggleStyle(.switch).labelsHidden()
        }
    }

    private var notifyThresholdRow: some View {
        settingsRow(
            title: "Notify threshold",
            help: "Seconds of continuous distraction before a notification fires."
        ) {
            Stepper(value: $notify, in: 5...600, step: 5) {
                Text("\(notify) sec")
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
            .disabled(!notificationsEnabled)
        }
    }

    private var cooldownRow: some View {
        settingsRow(
            title: "Notification cooldown",
            help: "Minimum seconds between repeated notifications for the same streak."
        ) {
            Stepper(value: $cooldown, in: 15...600, step: 15) {
                Text("\(cooldown) sec")
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
            .disabled(!notificationsEnabled)
        }
    }

    private var blockThresholdRow: some View {
        settingsRow(
            title: "Block threshold",
            help: "Seconds of continuous distraction before the full-screen block overlay fires."
        ) {
            Stepper(value: $block, in: 30...900, step: 15) {
                Text("\(block) sec")
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private var strictModeRow: some View {
        settingsRow(
            title: "Strict mode",
            help: "Skip silence + notify thresholds. Any distraction during a session triggers the block overlay immediately."
        ) {
            Toggle("", isOn: $strictMode)
                .toggleStyle(.switch).labelsHidden()
        }
    }

    private var testNotificationRow: some View {
        settingsRow(
            title: "Send test notification",
            help: "Verify notifications are coming through."
        ) {
            Button("Send") {
                appState.notificationPresenter.presentDistractionWarning(
                    appName: "Test app",
                    currentURL: nil
                )
            }
        }
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
                Text(title).font(.system(size: 13))
                if let help {
                    Text(help)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
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
