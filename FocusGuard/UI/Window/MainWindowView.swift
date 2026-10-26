import SwiftUI

extension Notification.Name {
    /// Switch the open main window to the `MainTab` in `object`.
    static let selectMainTab = Notification.Name("FocusGuard.selectMainTab")
    /// Show a sheet over the main window: `object` is a `WindowSheet`.
    /// Open the window first (`AppDelegate.openMainWindow`).
    static let presentWindowSheet = Notification.Name("FocusGuard.presentWindowSheet")
    /// Open Apps & Sites on "Sort your apps".
    static let openAppsSort = Notification.Name("FocusGuard.openAppsSort")
}

enum MainTab: Hashable, CaseIterable {
    case home, reports, workLog, apps, settings

    var title: String {
        switch self {
        case .home:     return "Today"
        case .reports:  return "Reports"
        case .workLog:  return "Work log"
        case .apps:     return "Apps & Sites"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home:     return "clock"
        case .reports:  return "chart.bar"
        case .workLog:  return "doc.text"
        case .apps:     return "square.grid.2x2"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Sheets the window can show over any page.
enum WindowSheet: Identifiable, Equatable {
    /// The Pro upgrade; the feature that led here, if any, starts the trial.
    case upgrade(ProFeature?)
    case licence
    case browserExtension

    var id: String {
        switch self {
        case .upgrade:          return "upgrade"
        case .licence:          return "licence"
        case .browserExtension: return "extension"
        }
    }
}

/// Opens a window sheet from anywhere inside the window.
struct WindowSheetAction {
    let open: (WindowSheet) -> Void
    func callAsFunction(_ sheet: WindowSheet) { open(sheet) }
}

private struct WindowSheetKey: EnvironmentKey {
    static let defaultValue = WindowSheetAction { sheet in
        NotificationCenter.default.post(name: .presentWindowSheet, object: sheet)
    }
}

extension EnvironmentValues {
    var openWindowSheet: WindowSheetAction {
        get { self[WindowSheetKey.self] }
        set { self[WindowSheetKey.self] = newValue }
    }
}

/// The main window: an inset glass sidebar with the sections and a live
/// session card, and the selected page beside it.
struct MainWindowView: View {
    @Bindable var appState: AppState
    @State private var tab: MainTab
    @State private var sheet: WindowSheet?
    @State private var appsMode: AppsMode = .used
    @State private var settingsPane: SettingsPane = .general

    init(appState: AppState, initialTab: MainTab = .home) {
        self._appState = Bindable(wrappedValue: appState)
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            WindowSidebar(tab: $tab, appState: appState)
                .frame(width: 228)
                .frame(maxHeight: .infinity)

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.windowBackground)
        .ignoresSafeArea()
        .frame(minWidth: 980, minHeight: 640)
        .environment(\.openWindowSheet, WindowSheetAction { sheet = $0 })
        .sheet(item: $sheet) { item in
            sheetView(item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMainTab)) { note in
            if let requested = note.object as? MainTab { tab = requested }
        }
        .onChange(of: tab) { if tab != .apps && appsMode == .sort { appsMode = .used } }
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsPane)) { note in
            if let pane = note.object as? SettingsPane { settingsPane = pane }
            tab = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAppsSort)) { _ in
            appsMode = .sort
            tab = .apps
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentWindowSheet)) { note in
            if let requested = note.object as? WindowSheet { sheet = requested }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .home:
            TodayPage(appState: appState) { tab = $0 }
        case .reports:
            ReportsPage(appState: appState)
        case .workLog:
            WorkLogPage(appState: appState)
        case .apps:
            AppsSitesPage(appState: appState, mode: $appsMode)
        case .settings:
            SettingsView(appState: appState, pane: $settingsPane)
        }
    }

    @ViewBuilder
    private func sheetView(_ item: WindowSheet) -> some View {
        switch item {
        case .upgrade(let feature):
            UpgradeSheet(feature: feature) { sheet = $0 }
        case .licence:
            LicenceSheet()
        case .browserExtension:
            ExtensionSheet(appState: appState)
        }
    }
}

// MARK: - Sidebar

private struct WindowSidebar: View {
    @Binding var tab: MainTab
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the window's traffic lights.
            Spacer().frame(height: 46)

            ForEach(MainTab.allCases, id: \.self) { item in
                navRow(item)
            }

            Spacer(minLength: 12)
            SidebarSessionCard(appState: appState)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { SidebarGlass() }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(8)
    }

    private func navRow(_ item: MainTab) -> some View {
        let selected = tab == item
        return Button { tab = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.focus : Theme.secondaryText)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item == .workLog && !WorkLogAccess.isOpen(shipped: FeatureFlags.debrief, unlocked: entitlements.isUnlocked(.workLog)) {
                    ProBadge()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.focusTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Liquid Glass on macOS 26+, a translucent panel before that.
private struct SidebarGlass: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(Theme.sidebarGlass)
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
                .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.08), radius: 10, y: 6)
        }
    }
}

/// Bottom of the sidebar: the running session, the break, or a quick
/// start. Everything in it truncates, so it never widens the sidebar.
private struct SidebarSessionCard: View {
    @Bindable var appState: AppState
    @State private var now = Date.now
    @AppStorage(WindowDefaultsKey.sessionLength) private var lengthChoice = 0
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = ""

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let state = appState.breakManager.current {
                card {
                    Image(systemName: "cup.and.saucer")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 34, height: 34)
                    lines("Break", "Back at \(WindowFormat.clock(now.addingTimeInterval(state.remaining(now: now))))")
                    if appState.breakManager.canEndEarly {
                        roundButton("stop.fill", "End break") { appState.breakManager.skip() }
                    }
                }
            } else if let session = appState.sessionManager.currentSession {
                let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
                let timeline = appState.liveTimeline(for: session, now: now)
                let progress = SessionTimeline.progress(elapsed: elapsed, timeline: timeline)
                let paused = session.pausedAt != nil
                let left = session.plannedDurationMinutes.map { max(0, Double($0 * 60) - elapsed) }
                card {
                    WindowSessionRing(segments: timeline.ringSegments(progress: paused ? nil : progress, gapDegrees: 3),
                                lineWidth: 4)
                        .frame(width: 30, height: 30)
                        .padding(2)
                        .accessibilityHidden(true)
                    lines(session.displayName,
                          paused ? "Paused" : (left.map { "\(AppState.minutesRoundedUp($0)) min left" } ?? "\(Int(elapsed / 60)) min in"))
                    roundButton(paused ? "play.fill" : "pause.fill", paused ? "Resume session" : "Pause session") {
                        if paused { appState.sessionManager.resumeSession() } else { appState.sessionManager.pauseSession() }
                    }
                }
            } else {
                let minutes: Int? = lengthChoice < 0 ? nil
                    : (lengthChoice > 0 ? lengthChoice : CoachRules.sessionMinutes() ?? defaultMinutes)
                Button {
                    appState.sessionManager.startSession(label: defaultLabel.isEmpty ? nil : defaultLabel,
                                                         plannedDurationMinutes: minutes)
                } label: {
                    Label(minutes.map { "Start \($0) min focus" } ?? "Start focus", systemImage: "play.fill")
                }
                .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
            }
        }
        .onReceive(ticker) { now = $0 }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.sidebarCard))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    private func lines(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roundButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
