import AppKit
import SwiftUI

// The right-hand side of each onboarding step. The left panel's pictures
// are in OnboardingPanels.swift.

// MARK: - 1 · Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingEyebrow("Welcome")
            OnboardingHeading(title: "Focus that keeps itself honest.",
                              detail: "FocusGuard lives in your menu bar. Start a session, and it quietly notices when you drift and helps you back.",
                              size: 30)
            VStack(alignment: .leading, spacing: 20) {
                feature("play.fill", "Start from the shield",
                        "Click the shield in the menu bar, pick any length and start. It fills as you go.")
                feature("exclamationmark.shield", "A nudge when you drift",
                        "Wander to x.com and you'll get a nudge, then a pause screen if you stay.")
                feature("lock", "Your activity stays on this Mac", PrivacyStatement.short)
            }
            .padding(.top, 30)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.focusTint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(text).font(.system(size: 13)).lineSpacing(2).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 2 · Permissions

/// Whether FocusGuard can read the browsers' tabs: through the browser
/// extension, or by asking each open browser over Apple Events (macOS asks
/// the user once per browser).
enum BrowserAccess {
    enum State: Equatable { case allowed, ask, openSettings, asksOnUse }

    /// errAEEventNotPermitted: the user said no.
    static let notPermitted: OSStatus = -1743
    /// errAEEventWouldRequireUserConsent: not asked yet.
    static let notAsked: OSStatus = -1744

    /// From each open browser's answer, whether the extension is connected,
    /// and whether a browser turned FocusGuard down before.
    static func state(answers: [OSStatus], extensionConnected: Bool, deniedBefore: Bool) -> State {
        if extensionConnected || answers.contains(noErr) { return .allowed }
        if deniedBefore || answers.contains(notPermitted) { return .openSettings }
        if answers.contains(notAsked) { return .ask }
        return .asksOnUse
    }

    /// Browsers that are open now, by bundle id.
    @MainActor
    static var openBrowsers: [String] {
        Array(Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter(BrowserTabReader.isBrowser(bundleIdentifier:)))).sorted()
    }

    /// Each browser's answer. With `prompt`, macOS asks the user about the
    /// ones it hasn't asked yet; that blocks until they answer, so it runs
    /// off the main thread.
    static func answers(for browsers: [String], prompt: Bool) async -> [OSStatus] {
        await Task.detached(priority: .userInitiated) {
            browsers.map { id in
                let target = NSAppleEventDescriptor(bundleIdentifier: id)
                guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
                return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, prompt)
            }
        }.value
    }
}

struct PermissionsStep: View {
    @Bindable var appState: AppState
    @State private var browser: BrowserAccess.State = .asksOnUse
    @State private var calendar: CalendarAutostartCoordinator.AccessState = .notDetermined

    private var permissions: PermissionsCoordinator { appState.permissions }

    private var ready: Int {
        [browser == .allowed, permissions.notifications == .granted,
         calendar == .authorized, permissions.screenRecording == .granted].filter { $0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingEyebrow("Permissions · \(ready) of 4 ready")
            OnboardingHeading(title: "What FocusGuard can see",
                              detail: "Only what it needs to tell focus from drift. This screen updates as you allow each one.")
            VStack(spacing: 10) {
                PermissionRow(symbol: "globe", title: "Browser access", optional: false,
                              detail: "Reads the front tab's address, so x.com counts as drift and github.com as focus. macOS asks once per browser.",
                              status: browserStatus, action: askBrowsers)
                PermissionRow(symbol: "bell", title: "Notifications", optional: false,
                              detail: "For nudges, session ends, and a morning plan if you want one.",
                              status: status(permissions.notifications)) {
                    Task { await permissions.requestNotifications() }
                }
                PermissionRow(symbol: "calendar", title: "Calendar", optional: true,
                              detail: "Starts sessions from events with “focus” in the title, finds free slots, and keeps meetings out of your drift.",
                              status: calendarStatus, action: askCalendar)
                PermissionRow(symbol: "macwindow", title: "Window titles", optional: true,
                              detail: "Shows which file or doc you were in. macOS calls this Screen Recording; FocusGuard never records your screen.",
                              status: permissions.screenRecording == .granted ? .allowed : .ask) {
                    permissions.requestScreenRecording()
                }
            }
            .padding(.top, 20)
            Text("No Accessibility access needed. Change any of this later in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 12)
        }
        .task {
            // Pick up grants made in System Settings without a Refresh button.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var browserStatus: PermissionRow.Status {
        switch browser {
        case .allowed:      return .allowed
        case .ask:          return .ask
        case .openSettings: return .openSettings
        case .asksOnUse:    return .note("macOS asks on first use")
        }
    }

    private var calendarStatus: PermissionRow.Status {
        switch calendar {
        case .authorized:    return .allowed
        case .denied:        return .openSettings
        case .notDetermined: return .ask
        }
    }

    private func status(_ status: PermissionStatus) -> PermissionRow.Status {
        switch status {
        case .granted: return .allowed
        case .denied:  return .openSettings
        default:       return .ask
        }
    }

    private func refresh() async {
        await permissions.refresh()
        calendar = appState.calendarAutostart.accessState
        let answers = await BrowserAccess.answers(for: BrowserAccess.openBrowsers, prompt: false)
        let denied = !(UserDefaults.standard.stringArray(forKey: SettingsKeys.browserAutomationDenied) ?? []).isEmpty
        browser = BrowserAccess.state(answers: answers, extensionConnected: !appState.extensionBridge.connectedBrowsers.isEmpty,
                                      deniedBefore: denied)
    }

    private func askBrowsers() {
        if browser == .openSettings {
            Self.openPrivacy("Privacy_Automation")
            return
        }
        Task {
            _ = await BrowserAccess.answers(for: BrowserAccess.openBrowsers, prompt: true)
            await refresh()
        }
    }

    private func askCalendar() {
        if calendar == .denied {
            Self.openPrivacy("Privacy_Calendars")
            return
        }
        Task {
            await appState.calendarAutostart.requestAccess()
            await refresh()
        }
    }

    private static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One permission: an icon, what it's for, and its state or a button.
struct PermissionRow: View {
    enum Status: Equatable {
        case allowed, ask, openSettings
        /// A line of text instead of a button.
        case note(String)
    }

    let symbol: String
    let title: String
    /// Optional ones get a grey icon and a quiet button.
    let optional: Bool
    let detail: String
    let status: Status
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(optional ? Theme.secondaryText : Theme.focus)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(optional ? OnboardingPalette.quietTile : Theme.focusTint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    if optional {
                        Text("Optional").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OnboardingPalette.cardStroke, lineWidth: 0.5))
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .allowed:
            Label("Allowed", systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.link)
                .fixedSize()
        case .ask:
            Button("Allow…", action: action)
                .buttonStyle(.capsule(optional ? .secondary : .primary, height: 28))
                .accessibilityLabel("Allow \(title)")
        case .openSettings:
            Button("Open Settings…", action: action)
                .buttonStyle(.capsule(.secondary, height: 28))
                .help("macOS was told no before; turn it on in System Settings.")
        case .note(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

// MARK: - 3 · Setup

struct SetupStep: View {
    let entitlements: Entitlements
    /// Strict is running a session, so the preset can't change.
    let presetLocked: Bool
    /// Switches the preset; false when it couldn't.
    let setPreset: (DriftResponse) -> Bool
    @Binding var level: BlockingLevel
    @Binding var drift: DriftResponse?

    @AppStorage(SettingsKeys.Goal.dailyFocusMinutes) private var goalMinutes = GoalDefaults.dailyFocusMinutes
    @AppStorage(SettingsKeys.Session.defaultDurationMinutes) private var sessionMinutes = 50
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0

    /// What each preset does, on its card.
    static func summary(_ preset: DriftResponse) -> String {
        switch preset {
        case .gentle:   return "Nudge after 1 min, block after 3."
        case .standard: return "Nudge after 30 s, block after 90 s."
        case .strict:   return "Block as soon as you drift. No passes; “It's for work” after 10 s."
        }
    }

    /// The line under the blocking cards: what a Pro level does to the plan.
    @MainActor
    static func planNote(_ entitlements: Entitlements, now: Date = .now) -> String {
        switch entitlements.plan {
        case .pro:
            return "Pro is on, so every level is yours."
        case .trial:
            let days = entitlements.plan.daysLeft(at: now) ?? 0
            return "Your Pro trial has \(days == 1 ? "1 day" : "\(days) days") left."
        case .free:
            return entitlements.canStartTrial
                ? "A Pro level starts a \(Plan.trialDays)-day free trial. No card, and a reminder \(Plan.trialReminderDays) days before it ends."
                : "Your free trial has been used, so the Pro levels need Pro."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingEyebrow("Your setup")
            OnboardingHeading(title: "Make it yours", detail: "Sensible defaults. Change them any time from the menu.")

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    rowTitle("Daily focus goal")
                    Text(FocusGoal.format(minutes: goalMinutes))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                        .frame(minWidth: 56, alignment: .trailing)
                    HStack(spacing: 0) {
                        stepButton("minus", "Lower the goal") { goalMinutes = max(FocusGoal.range.lowerBound, goalMinutes - 15) }
                        stepButton("plus", "Raise the goal") { goalMinutes = min(FocusGoal.range.upperBound, goalMinutes + 15) }
                    }
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
                }
                HStack(spacing: 12) {
                    rowTitle("Usual session length")
                    lengthPicker
                }
            }
            .padding(.top, 20)

            sectionTitle("When you drift").padding(.top, 20)
            HStack(spacing: 8) {
                ForEach(DriftResponse.allCases) { preset in
                    card(selected: drift == preset, enabled: !presetLocked) {
                        if setPreset(preset) { drift = preset }
                    } content: {
                        Text(preset.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        Text(Self.summary(preset)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            if presetLocked {
                note("Strict stays on until this session ends.")
            } else if drift == nil {
                note("You've set your own timings in Settings. Pick one to replace them.")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionTitle("Blocking")
                Text("what happens when the block screen comes up")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 18)
            HStack(spacing: 8) {
                ForEach(BlockingLevel.allCases) { option in
                    levelCard(option)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            note(Self.planNote(entitlements))
        }
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var lengthPicker: some View {
        HStack(spacing: 2) {
            ForEach(Constants.SessionDurations.presets, id: \.self) { minutes in
                let selected = sessionMinutes == minutes
                Button {
                    sessionMinutes = minutes
                    lastSessionMinutes = minutes
                } label: {
                    Text("\(minutes) min")
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Theme.segment : .clear)
                            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usual session length")
    }

    private func levelCard(_ option: BlockingLevel) -> some View {
        let available = option.isAvailable(entitlements)
        let detail = option == .browser && !available ? "Your free trial has been used. This needs Pro." : option.detail
        return card(selected: level == option, enabled: available) {
            level = option
        } content: {
            HStack(spacing: 6) {
                if option.isPro { ProBadge() } else { FreeBadge() }
                if option == .wholeMac {
                    Text("Coming later").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                }
            }
            Text(option.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
        .help(option == .wholeMac ? "Whole-Mac blocking is coming later." : "")
    }

    /// A choice card: white, with a 2 pt indigo ring when picked.
    private func card<Content: View>(selected: Bool, enabled: Bool, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) { content() }
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(shape.fill(OnboardingPalette.card))
                .overlay(shape.strokeBorder(selected ? Theme.focus : OnboardingPalette.cardStroke, lineWidth: selected ? 2 : 0.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.7)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 4 · Browser extension

/// Where "Add to Chrome…" goes: the Chrome Web Store listing once it
/// exists, until then the extension's folder and its install steps.
enum ExtensionLinks {
    static var addToChrome: URL? {
        if let id = BrowserExtensionIDs.store {
            return URL(string: "https://chromewebstore.google.com/detail/\(id)")
        }
        return URL(string: "https://github.com/anarzone/FocusGuard/tree/main/extension/chrome")
    }

    /// Chromium browsers the extension works in, in the order to prefer.
    static let chromiumBrowsers = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac"]

    /// Opens the link in the first of those that's installed, else in the default browser.
    @MainActor
    static func openAddToChrome() {
        guard let url = addToChrome else { return }
        let workspace = NSWorkspace.shared
        if let app = chromiumBrowsers.lazy.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first {
            workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
    }
}

struct ExtensionStep: View {
    let bridge: ExtensionBridge
    let entitlements: Entitlements
    let level: BlockingLevel

    private var chromeConnected: Bool {
        !bridge.connectedBrowsers.filter { $0 != "com.apple.Safari" }.isEmpty
    }

    /// Adding the extension never starts a trial; a Pro level picked in
    /// setup already did.
    static func note(level: BlockingLevel, plan: Plan) -> String {
        let base = "Free to add, and adding it never starts a trial."
        guard level == .browser else { return base }
        switch plan {
        case .trial: return base + " Your Pro trial covers the extras."
        case .pro:   return base + " Pro covers the extras."
        case .free:  return base
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingEyebrow(text: "Browser extension · optional") { FreeBadge() }
            OnboardingHeading(title: "Add FocusGuard to your browser",
                              detail: "It's free. FocusGuard sees the exact page you're on, so your day is tracked more accurately and a tab pauses the moment you drift.")

            VStack(alignment: .leading, spacing: 8) {
                check("More accurate tracking, page by page")
                check("Pause the tab, in any window")
                check("Change a site's category from the toolbar")
            }
            .padding(.top, 16)

            HStack(spacing: 8) {
                Text("With Pro").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                ProBadge()
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Pages never load during a session")
                bullet("Block parts of sites, like youtube.com/shorts")
                bullet("YouTube decided video by video, and as many daily limits as you like")
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                browserRow("Chrome", "Also works in Arc, Brave and Edge.") {
                    if chromeConnected {
                        Label("On", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.link)
                    } else {
                        Button("Add to Chrome…") { ExtensionLinks.openAddToChrome() }
                            .buttonStyle(.capsule(.primary, height: 30))
                    }
                }
                browserRow("Safari", "FocusGuard reads Safari's tabs without it for now.") {
                    Text("Coming later").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.top, 20)
            Text(Self.note(level: level, plan: entitlements.plan))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 10)
        }
    }

    private func check(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.focus)
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.focus).frame(width: 6, height: 6).padding(.horizontal, 4.5)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func browserRow<Trailing: View>(_ name: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(OnboardingPalette.quietTile))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OnboardingPalette.cardStroke, lineWidth: 0.5))
    }
}
