import AppKit
import SwiftUI

/// Status in Slack and Discord (Pro), in Settings › Integrations: while a
/// session runs, Slack shows "Focusing until 19:32" with notifications
/// paused, and Discord shows "Focusing". Each row shows once its app's ID
/// is built in; with neither, the section isn't there.
struct SettingsStatusSection: View {
    var sync: StatusSync = .shared
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet

    @AppStorage(StatusSettings.slack) private var slackOn = true
    @AppStorage(StatusSettings.slackStatus) private var setStatus = true
    @AppStorage(StatusSettings.slackText) private var statusText = StatusSettings.defaultText
    @AppStorage(StatusSettings.slackSnooze) private var snooze = true
    @AppStorage(StatusSettings.discord) private var discordOn = false
    @State private var showingSlack = false

    static let slackTint = Color(red: 0x5B / 255, green: 0x2A / 255, blue: 0x63 / 255)
    static let discordTint = Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255)

    var body: some View {
        if sync.isAvailable {
            SettingsSection(title: String(localized: "Status in Slack and Discord"), trailing: { ProBadge() }) {
                if sync.slack.isConfigured { slackRows }
                if sync.slack.isConfigured && sync.discord.isConfigured { SettingsDivider() }
                if sync.discord.isConfigured { discordRow }
            }
            .sheet(isPresented: $showingSlack) { SlackStatusSheet(sync: sync) }
        }
    }

    private var unlocked: Bool { entitlements.isUnlocked(.statusSync) }
    private var slack: SlackAccount { sync.slack }

    // MARK: - Slack

    @ViewBuilder
    private var slackRows: some View {
        StatusServiceRow(letter: "S", tint: Self.slackTint, title: slackTitle, detail: slackDetail) { slackControl }
        if slack.isConnected && unlocked && slackOn && !slack.isWaiting {
            SettingsDivider()
            HStack(spacing: 8) {
                Text("Shows", comment: "Before a preview of your Slack status: Shows Focusing until 19:32").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Text(showsText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.focusTint))
                Spacer(minLength: 0)
                Button("Edit…") { showingSlack = true }.buttonStyle(.textLink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var slackTitle: String {
        guard slack.isConnected, let team = slack.teamName, !team.isEmpty else { return "Slack" }
        return "Slack · \(team)"
    }

    private var slackDetail: String {
        if !unlocked && entitlements.canStartTrial {
            return String(localized: "Status and paused notifications while you focus. Connecting starts your \(Plan.trialDays)-day Pro trial")
        }
        if !unlocked { return String(localized: "Status and paused notifications while you focus. Part of Pro") }
        if slack.isWaiting { return String(localized: "Finish in your browser, then come back here") }
        switch slack.problem {
        case .connectFailed: return String(localized: "Slack didn't connect. Try again")
        case .signedOut:     return String(localized: "Slack signed FocusGuard out. Connect again")
        case nil:            return String(localized: "Status and paused notifications while you focus")
        }
    }

    @ViewBuilder
    private var slackControl: some View {
        if !unlocked && !entitlements.canStartTrial {
            Button("Get Pro") { openSheet(.upgrade(.statusSync)) }
                .buttonStyle(.capsule(.secondary, height: 26))
        } else if slack.isWaiting {
            Button("Cancel") { slack.cancelConnect() }
                .buttonStyle(.capsule(.secondary, height: 26))
        } else if slack.isConnected && unlocked {
            Toggle("Slack status", isOn: Binding(get: { slackOn }, set: { on in
                slackOn = on
                sync.update()
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(Theme.focusFill)
        } else {
            Button("Connect…") { showingSlack = true }
                .buttonStyle(.capsule(.secondary, height: 26))
        }
    }

    /// The status as it would read now, or what else Slack does.
    private var showsText: String {
        if setStatus { return StatusText.render(statusText, end: sync.previewEnd()) }
        return snooze ? String(localized: "Notifications paused") : String(localized: "Nothing", comment: "Slack shows nothing during a session")
    }

    // MARK: - Discord

    private var discordRow: some View {
        StatusServiceRow(letter: "D", tint: Self.discordTint, title: "Discord", detail: discordDetail) {
            if unlocked || entitlements.canStartTrial {
                Toggle("Discord activity", isOn: Binding(get: { discordOn && unlocked }, set: setDiscord))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.focusFill)
            } else {
                Button("Get Pro") { openSheet(.upgrade(.statusSync)) }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
        }
    }

    private var discordDetail: String {
        if !unlocked && entitlements.canStartTrial {
            return String(localized: "Shows “Focusing” under your name while it's open. Turning it on starts your \(Plan.trialDays)-day Pro trial")
        }
        if !unlocked { return String(localized: "Shows “Focusing” under your name while it's open. Part of Pro") }
        return String(localized: "Shows “Focusing” under your name while it's open")
    }

    private func setDiscord(_ on: Bool) {
        if on && !unlocked { entitlements.startTrialIfNeeded(for: .statusSync) }
        discordOn = on && unlocked
        sync.update()
    }
}

/// A settings row with the app's letter tile in front.
private struct StatusServiceRow<Trailing: View>: View {
    let letter: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            StatusAppTile(letter: letter, tint: tint, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
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

/// "S" on Slack's aubergine, "D" on Discord's blurple.
private struct StatusAppTile: View {
    let letter: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size / 4, style: .continuous).fill(tint))
            .accessibilityHidden(true)
    }
}

// MARK: - Connect sheet

/// "Show your focus in Slack": what Slack shows and does during a session,
/// with a preview, before going to the browser to connect. Once connected,
/// "Edit…" opens it to change those, or to disconnect.
struct SlackStatusSheet: View {
    let sync: StatusSync
    var entitlements: Entitlements = .shared

    @Environment(\.dismiss) private var dismiss
    @State private var setStatus = StatusSettings.isOn(StatusSettings.slackStatus)
    @State private var text = StatusSettings.text()
    @State private var snooze = StatusSettings.isOn(StatusSettings.slackSnooze)
    @FocusState private var fieldFocused: Bool

    private var slack: SlackAccount { sync.slack }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            choices
            preview
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock").foregroundStyle(Theme.secondaryText)
                Text("FocusGuard asks Slack for two things only: to change your status and to pause your notifications. It can't read your messages or channels.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.bodyText)
            footer
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 520)
        .background(Theme.windowBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusAppTile(letter: "S", tint: SettingsStatusSection.slackTint, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Show your focus in Slack")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    ProBadge()
                }
                Text("While a session runs, your teammates see you're focusing. When it ends, your status clears and notifications come back.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var choices: some View {
        VStack(spacing: 0) {
            SettingsToggle(title: String(localized: "Set my status"), detail: String(localized: "With the time the session ends"), isOn: $setStatus)
            if setStatus {
                HStack(spacing: 12) {
                    Text("Status").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(width: 64, alignment: .leading)
                    TextField(StatusSettings.defaultText, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($fieldFocused)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.windowCard))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(fieldFocused ? Theme.focus.opacity(0.6) : Theme.hairline, lineWidth: fieldFocused ? 2 : 0.5))
                        .accessibilityLabel("Status")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            SettingsDivider()
            SettingsToggle(title: String(localized: "Pause my notifications"), detail: String(localized: "Slack's Do Not Disturb, until the session ends"),
                           isOn: $snooze)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.inset))
    }

    private var preview: some View {
        let name = NSFullUserName().isEmpty ? String(localized: "You", comment: "Stands in for your name in the Slack preview") : NSFullUserName()
        return VStack(alignment: .leading, spacing: 6) {
            Text("What teammates see")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 10) {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.focusTint))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    if setStatus {
                        Label(StatusText.render(text, end: sync.previewEnd()), systemImage: "headphones")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.bodyText)
                            .lineLimit(1)
                    } else {
                        Text("No status").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if snooze {
                    Label("Notifications paused", systemImage: "bell.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.bottom, 14)
            HStack(spacing: 8) {
                if slack.isConnected {
                    Button("Disconnect") {
                        sync.disconnectSlack()
                        dismiss()
                    }
                    .buttonStyle(.textLink)
                } else {
                    Text("You'll pick the workspace in your browser.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 30))
                    .keyboardShortcut(.cancelAction)
                Button(slack.isConnected ? "Done" : "Continue in browser", action: confirm)
                    .buttonStyle(.capsule(.primary, height: 30))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Keeps the choices; not connected yet, starts the trial if it can and
    /// opens Slack in the browser.
    private func confirm() {
        let defaults = UserDefaults.standard
        defaults.set(setStatus, forKey: StatusSettings.slackStatus)
        defaults.set(snooze, forKey: StatusSettings.slackSnooze)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed.isEmpty ? StatusSettings.defaultText : trimmed, forKey: StatusSettings.slackText)
        if slack.isConnected {
            sync.update()
        } else {
            if !entitlements.isUnlocked(.statusSync) { entitlements.startTrialIfNeeded(for: .statusSync) }
            if entitlements.isUnlocked(.statusSync) {
                defaults.set(true, forKey: StatusSettings.slack)
                slack.connect()
            }
        }
        dismiss()
    }
}
