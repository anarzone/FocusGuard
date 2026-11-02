import AppKit
import SwiftUI

/// Notifications: nudges in a session and the habit notices of the day.
/// The habit switches are the habits session's (`HabitSettings`).
struct SettingsNotificationsPane: View {
    @Bindable var appState: AppState

    @AppStorage(SettingsKeys.showNotifications) private var allowed = true
    @AppStorage(SettingsKeys.Escalation.notificationsEnabled) private var nudges = true
    @AppStorage(HabitSettings.meetingAwareness) private var quietInCalls = true
    @AppStorage(HabitSettings.autoStartOffer) private var autoStartOffer = true
    @AppStorage(HabitSettings.morningPlan) private var morningPlan = true
    @AppStorage(HabitSettings.eveningWrapUp) private var eveningWrapUp = true

    var body: some View {
        SettingsColumns {
            SettingsSection(String(localized: "FocusGuard notifications")) {
                SettingsToggle(title: String(localized: "Allow notifications"),
                               detail: String(localized: "Off silences every one of them; the pause screen still works"),
                               isOn: $allowed)
            }
            SettingsSection(String(localized: "During a session")) {
                SettingsToggle(title: String(localized: "Nudge when you drift"), detail: nudgeDetail, isOn: $nudges)
                SettingsDivider()
                SettingsToggle(title: String(localized: "Stay quiet during calls"),
                               detail: String(localized: "Zoom, FaceTime, Meet and Teams count as neutral, and nudges wait during calls"),
                               isOn: $quietInCalls)
            }
            .disabled(!allowed)
            SettingsSection(String(localized: "Your day")) {
                SettingsToggle(title: String(localized: "Morning plan"),
                               detail: String(localized: "A \(Self.hour(HabitSchedule.morningHours.lowerBound)) notification with free slots for today's sessions"),
                               isOn: $morningPlan)
                SettingsDivider()
                SettingsToggle(title: String(localized: "Evening wrap-up"),
                               detail: String(localized: "After \(Self.hour(HabitSchedule.wrapUpHour)): focused time against your goal, and when to start tomorrow"),
                               isOn: $eveningWrapUp)
                SettingsDivider()
                SettingsToggle(title: String(localized: "Offer to start a session"),
                               detail: String(localized: "After 5 focused minutes outside a session. It counts from when you began"),
                               isOn: $autoStartOffer)
            }
            .disabled(!allowed)
        } right: {
            SettingsSection(String(localized: "What they look like")) {
                VStack(spacing: 8) {
                    sample(time: "09:00", title: String(localized: "Plan your day"),
                           body: String(localized: "Yesterday: \(WindowFormat.hm(4 * 3600 + 20 * 60)) focused. Start with \(defaultLength) minutes?"))
                    sample(time: "18:30", title: String(localized: "\(WindowFormat.hm(3 * 3600 + 23 * 60)) focused today"),
                           body: String(localized: "37 minutes short of your goal. One short session tonight keeps your streak."))
                    sample(time: String(localized: "now", comment: "Time on a sample notification"), title: String(localized: "Back to your session?"),
                           body: String(localized: "You've been on a distracting site for 30 seconds. The pause screen comes in a minute."))
                }
                .padding(12)
            }
            SettingsNote(text: String(localized: "These are examples. macOS decides how notifications appear; change banners or alerts in System Settings › Notifications."))
            Button("Open Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.textLink)
            .padding(.leading, 4)
        }
    }

    /// "09:00", in the 24-hour style the rest of the window uses.
    static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

    private var defaultLength: Int {
        UserDefaults.standard.object(forKey: SessionDefaultsKey.durationMinutes) as? Int ?? 50
    }

    private var nudgeDetail: String {
        let engine = appState.escalationEngine
        if engine.strictMode { return String(localized: "Strict pauses the screen straight away instead") }
        return String(localized: "After \(DriftTimingsSheet.seconds(Int(engine.notifyThreshold))) on a distracting site · \(engine.preset.title)")
    }

    private func sample(time: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AppGlyph(kind: .focusguard, size: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("FocusGuard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text(time).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(body).font(.system(size: 12)).foregroundStyle(Theme.bodyText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
        .accessibilityElement(children: .combine)
    }
}
