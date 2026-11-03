import SwiftUI

/// Settings › Sessions: when the card comes up, the shortcut, how much comes
/// back, and what it keeps.
struct SettingsPickUpSection: View {
    var pickUp: PickUpCoordinator
    var hotKey: PickUpHotKey

    @AppStorage(PickUpSettings.afterCall) private var afterCall = true
    @AppStorage(PickUpSettings.afterAway) private var afterAway = true
    @AppStorage(PickUpSettings.afterDrift) private var afterDrift = true
    @AppStorage(PickUpSettings.shortcut) private var shortcutOn = true
    @AppStorage(PickUpSettings.bringBack) private var bringBack = PickUpPlaces.most
    @AppStorage(HabitSettings.meetingAwareness) private var meetingAwareness = true
    @State private var forgotten = false

    var body: some View {
        SettingsSection(String(localized: "Pick up where you left off")) {
            SettingsToggle(title: String(localized: "After a call"),
                           detail: meetingAwareness ? String(localized: "Calls of 5 minutes or more")
                                                    : String(localized: "Needs “Calls never count as drift”"),
                           isOn: $afterCall)
                .disabled(!meetingAwareness)
            SettingsDivider()
            SettingsToggle(title: String(localized: "When you come back to your Mac"),
                           detail: String(localized: "After 5 minutes or more away"), isOn: $afterAway)
            SettingsDivider()
            SettingsToggle(title: String(localized: "After drifting"),
                           detail: String(localized: "After 2 minutes or more on a distracting site"), isOn: $afterDrift)
            SettingsDivider()
            SettingsRow(title: String(localized: "Shortcut", comment: "Settings row: the keyboard shortcut for Pick up"),
                        detail: hotKey.isTaken ? String(localized: "Another app is using it") : nil) {
                HStack(spacing: 10) {
                    Text(PickUpHotKey.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(shortcutOn ? Theme.primaryText : Theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MomentPalette.quietFill))
                        .accessibilityLabel(String(localized: "Control Option R"))
                    Toggle(String(localized: "Shortcut"), isOn: $shortcutOn)
                        .toggleStyle(.switch).labelsHidden().tint(Theme.focusFill)
                }
            }
            SettingsDivider()
            SettingsRow(title: String(localized: "Bring back"),
                        detail: String(localized: "It brings apps to the front and reopens pages. It can't restore unsaved work.")) {
                Picker("Bring back", selection: $bringBack) {
                    Text("Only the last app").tag(1)
                    Text("Up to 2 apps").tag(2)
                    Text("Up to 3 apps").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .onChange(of: shortcutOn) { hotKey.setEnabled(shortcutOn) }

        SettingsSection(String(localized: "What it keeps")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(PrivacyNote.pickUp)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("Choose what to exclude") {
                        NotificationCenter.default.post(name: .selectSettingsPane, object: SettingsPane.privacy)
                    }
                    if forgotten {
                        Text("Forgotten", comment: "Your last places were forgotten")
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Button("Forget my last places") {
                            pickUp.forgetPlaces()
                            forgotten = true
                        }
                    }
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}
