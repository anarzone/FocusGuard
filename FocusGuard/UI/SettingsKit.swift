import AppKit
import SwiftUI

// MARK: - Keys

/// Settings the window's panes add.
enum SettingsWindowKey {
    /// "system", "light" or "dark".
    static let appearance = "ui.appearance"
    /// Pause the tab when the pause screen shows. Read once at launch.
    static let pauseTab = "blocking.pauseTab.enabled"
    /// Fetch site icons from the sites themselves.
    static let siteIcons = "privacy.siteIcons"
}

/// The habit switches the habits session reads (`HabitSettings` there).
/// Same strings, so either side can land first. All default to on.
enum WindowHabitKey {
    static let morningPlan = "habits.morningPlan.enabled"
    static let eveningWrapUp = "habits.eveningWrapUp.enabled"
    static let autoStartOffer = "habits.autoStartOffer.enabled"
    static let meetingAwareness = "habits.meetingAwareness.enabled"
}

// MARK: - Appearance

/// System, Light or Dark for the whole app.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static var stored: AppAppearance {
        parse(UserDefaults.standard.string(forKey: SettingsWindowKey.appearance))
    }

    /// The stored value, or System for anything it doesn't know.
    static func parse(_ raw: String?) -> AppAppearance {
        raw.flatMap(AppAppearance.init) ?? .system
    }

    /// Applies the stored choice; called at launch and when it changes.
    @MainActor
    static func applyStored() { stored.apply() }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Layout

/// A pane's two columns of sections, tops aligned.
struct SettingsColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) { left() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 14) { right() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A titled group: a grey heading over a white card of rows.
struct SettingsSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                trailing()
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.windowCard))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = { EmptyView() }
        self.content = content
    }
}

/// The hairline between two rows of a section.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline.opacity(0.8)).frame(height: 0.5).padding(.leading, 14)
    }
}

/// One row: a title (and a grey line under it) on the left, a control on
/// the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
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

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
        self.trailing = { EmptyView() }
    }
}

/// A row with a switch.
struct SettingsToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Theme.focusFill)
        }
    }
}

/// A grey note with an icon, under or between sections.
struct SettingsNote: View {
    var systemImage = "info.circle"
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(Theme.secondaryText)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.bodyText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
    }
}

/// System, Light, Dark: a small segmented control.
struct SettingsSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let picked = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: picked ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if picked {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.switchThumb)
                                    .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.switchTrack))
        .fixedSize()
    }
}

/// Opens another settings pane, or another page, from inside a pane.
extension Notification.Name {
    /// `object`: the `SettingsPane` to show.
    static let selectSettingsPane = Notification.Name("FocusGuard.selectSettingsPane")
}

// MARK: - Browser extension rows

/// The browsers the extension runs in, and whether it's connected in each.
struct ExtensionStatusRows: View {
    @Bindable var appState: AppState
    @Environment(\.openWindowSheet) private var openSheet

    var body: some View {
        let connected = appState.extensionBridge.connectedBrowsers
        let installed = ExtensionSheet.browsers.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil
        }
        if installed.isEmpty {
            SettingsRow(title: "Chrome, Arc, Brave, Edge", detail: "None of these browsers is on this Mac") {
                Button("Add…") { openSheet(.browserExtension) }.buttonStyle(.capsule(.secondary, height: 26))
            }
        }
        ForEach(Array(installed.enumerated()), id: \.element.bundleId) { index, browser in
            if index > 0 { SettingsDivider() }
            SettingsRow(title: browser.name, detail: connected.contains(browser.bundleId) ? nil : "Not added yet") {
                if connected.contains(browser.bundleId) {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.bodyText)
                } else {
                    Button("Add extension") { openSheet(.browserExtension) }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            }
        }
    }
}
