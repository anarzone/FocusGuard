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
            SettingsIslandSection(permissions: appState.permissions) { appState.notificationPresenter.presentSampleCard() }
                .disabled(!allowed)
        }
    }

    /// "09:00", in the 24-hour style the rest of the window uses.
    static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

    private var nudgeDetail: String {
        let engine = appState.escalationEngine
        if engine.strictMode { return String(localized: "Strict pauses the screen straight away instead") }
        return String(localized: "After \(DriftTimingsSheet.seconds(Int(engine.notifyThreshold))) on a distracting site · \(engine.preset.title)")
    }
}

/// "Show them as": FocusGuard's own cards or macOS notifications.
struct SettingsIslandSection: View {
    let permissions: PermissionsCoordinator
    let showSample: () -> Void

    @AppStorage(IslandSettings.surface) private var surface = IslandSettings.Surface.cards
    @AppStorage(IslandSettings.softSound) private var softSound = false
    @AppStorage(IslandSettings.quietWhileSharing) private var quietWhileSharing = true

    /// True to what it does: it knows these apps, and macOS only gets asked.
    private var sharingDetail: String {
        permissions.screenRecording == .granted
            ? String(localized: "Notices Zoom, Teams, Webex and Google Meet in a browser. Held cards show when you stop, if they still matter. macOS is also asked to leave cards out of captures.")
            : String(localized: "Needs Screen Recording to notice Zoom, Teams, Webex and Google Meet in a browser. macOS is still asked to leave cards out of captures.")
    }

    var body: some View {
        section.modifier(IslandPermissionWatch(permissions: permissions, surface: surface))
    }

    @ViewBuilder
    private var section: some View {
        SettingsSection(String(localized: "Show them as")) {
            VStack(alignment: .leading, spacing: 6) {
                Picker(String(localized: "Show them as"), selection: $surface) {
                    Text("FocusGuard cards").tag(IslandSettings.Surface.cards)
                    Text("macOS notifications").tag(IslandSettings.Surface.macOS)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("macOS notifications can reach Notification Center and your Focus settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            SettingsDivider()
            SettingsToggle(title: String(localized: "Play a soft sound"),
                           detail: String(localized: "Only for a drift nudge and a finished session"),
                           isOn: $softSound)
                .disabled(surface != .cards)
            SettingsDivider()
            SettingsToggle(title: String(localized: "Stay quiet while sharing your screen"),
                           detail: sharingDetail,
                           isOn: $quietWhileSharing)
                .disabled(surface != .cards)
        }
        Button(surface == .cards ? String(localized: "Show a sample card") : String(localized: "Send a sample notification"), action: showSample)
            .padding(.leading, 4)
        if surface == .macOS {
            macOSPermission
        } else {
            SettingsNote(text: String(localized: "To hold cards during a Focus, add FocusGuard under Focus filters in that Focus's settings and turn on Keep cards quiet."))
            Button("Open Focus Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.textLink)
            .padding(.leading, 4)
        }
    }

    /// How macOS's permission stands. It's only needed, and only asked for, here.
    @ViewBuilder
    private var macOSPermission: some View {
        switch permissions.notifications {
        case .granted:
            SettingsNote(text: String(localized: "macOS decides how notifications appear; change banners or alerts in System Settings › Notifications."))
        case .notDetermined:
            SettingsNote(systemImage: "exclamationmark.triangle", text: String(localized: "macOS hasn't been asked yet, so nothing can show."))
            Button("Allow notifications…") { Task { await permissions.requestNotifications() } }
                .buttonStyle(.textLink)
                .padding(.leading, 4)
        case .denied, .unknown:
            SettingsNote(systemImage: "exclamationmark.triangle", text: String(localized: "macOS has notifications off for FocusGuard, so nothing will show until you allow them."))
        }
        if permissions.notifications != .notDetermined {
            Button("Open Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.textLink)
            .padding(.leading, 4)
        }
    }
}

/// Keeps the section's permission states fresh, and asks when macOS gets picked.
private struct IslandPermissionWatch: ViewModifier {
    let permissions: PermissionsCoordinator
    let surface: IslandSettings.Surface

    func body(content: Content) -> some View {
        content
            .task { await permissions.refresh() }
            .onChange(of: surface) { _, picked in
                guard picked == .macOS else { return }
                Task { await permissions.askForNotificationsIfNeeded() }
            }
    }
}
