import SwiftUI

extension Notification.Name {
    /// Switch the open main window to the `MainTab` in `object`.
    static let selectMainTab = Notification.Name("FocusGuard.selectMainTab")
}

enum MainTab: Hashable, CaseIterable {
    case home, reports, apps, settings

    var title: String {
        switch self {
        case .home:     return "Today"
        case .reports:  return "Reports"
        case .apps:     return "Apps & sites"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home:     return "clock"
        case .reports:  return "chart.bar.fill"
        case .apps:     return "square.grid.2x2.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// The main window: a floating glass sidebar with the sections and a live
/// session card, and the selected page beside it.
struct MainWindowView: View {
    @Bindable var appState: AppState
    @State private var tab: MainTab

    init(appState: AppState, initialTab: MainTab = .home) {
        self._appState = Bindable(wrappedValue: appState)
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            WindowSidebar(tab: $tab, appState: appState)
                .frame(width: 228)
                .padding(8)

            Group {
                switch tab {
                case .home:
                    TodayPage(appState: appState) { tab = $0 }
                case .reports:
                    ReportsPage(appState: appState)
                case .apps:
                    AppsPage(appState: appState)
                case .settings:
                    SettingsView(appState: appState)
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.windowBackground)
        .ignoresSafeArea()
        .frame(minWidth: 980, minHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: .selectMainTab)) { note in
            if let requested = note.object as? MainTab { tab = requested }
        }
    }
}

// MARK: - Sidebar

private struct WindowSidebar: View {
    @Binding var tab: MainTab
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the window's traffic lights.
            Spacer().frame(height: 40)

            ForEach(MainTab.allCases, id: \.self) { item in
                let selected = tab == item
                Button { tab = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? Theme.focus : Color.secondary)
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
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

            Spacer(minLength: 0)
            SessionCard(appState: appState)
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background { SidebarGlass() }
    }
}

/// Liquid Glass on macOS 26+, the sidebar material before that.
private struct SidebarGlass: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        }
    }
}

/// Bottom of the sidebar: the running session, the break, or a quick start.
private struct SessionCard: View {
    @Bindable var appState: AppState
    @State private var now = Date.now
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = ""

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.cardBackground))
        .onReceive(ticker) { now = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if let state = appState.breakManager.current {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Break").font(.system(size: 12, weight: .semibold))
                Text("Back at \(now.addingTimeInterval(state.remaining(now: now)).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if appState.breakManager.canEndEarly {
                roundButton("stop.fill", "End break") { appState.breakManager.skip() }
            }
        } else if let session = appState.sessionManager.currentSession {
            let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
            let planned = session.plannedDurationMinutes.map { Double($0 * 60) }
            let paused = session.pausedAt != nil
            ZStack {
                Circle().stroke(Theme.control, lineWidth: 5)
                Circle().trim(from: 0, to: planned.map { min(1, elapsed / $0) } ?? 0.5)
                    .stroke(Theme.focus, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 30, height: 30)
            .padding(2)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(paused ? "Paused" : planned.map { "\(Int((max(0, $0 - elapsed) / 60).rounded(.up))) min left" } ?? "\(Int(elapsed / 60)) min")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            roundButton(paused ? "play.fill" : "pause.fill", paused ? "Resume" : "Pause") {
                if paused { appState.sessionManager.resumeSession() } else { appState.sessionManager.pauseSession() }
            }
        } else {
            let minutes = lastSessionMinutes > 0 ? lastSessionMinutes : defaultMinutes
            Button {
                lastSessionMinutes = minutes
                appState.sessionManager.startSession(label: defaultLabel.isEmpty ? nil : defaultLabel,
                                                     plannedDurationMinutes: minutes)
            } label: {
                Label("Start \(minutes) min focus", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.focusFill))
            }
            .buttonStyle(.plain)
        }
    }

    private func roundButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.control))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Shared page chrome

/// Page header: big title and subtitle on the left, controls on the right.
struct PageHeader<Controls: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 22, weight: .bold)).kerning(-0.4)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            controls()
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

/// White (or dark grey) rounded card for window content.
struct WindowCard<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    trailing
                }
            }
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.windowCard))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }
}

/// Glass capsule for toolbar-style controls in page headers.
struct HeaderCapsule<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .frame(height: 30)
            .background(Capsule().fill(Theme.windowCard))
            .overlay(Capsule().strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// ‹ › stepper for days, weeks, months.
struct PeriodStepper: View {
    @Binding var offset: Int
    let unit: String

    var body: some View {
        HeaderCapsule {
            Button { offset += 1 } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 30)
            }
            .help("Previous \(unit)")
            .accessibilityLabel("Previous \(unit)")
            Rectangle().fill(Theme.separator).frame(width: 0.5, height: 14)
            Button { offset = max(0, offset - 1) } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 30)
            }
            .disabled(offset == 0)
            .help("Next \(unit)")
            .accessibilityLabel("Next \(unit)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
    }
}

/// Small stat block used in the window's cards.
struct WindowStat: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Apps & sites page

private struct AppsPage: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Apps & sites",
                       subtitle: "Decide what counts as focus. Changes also update past reports.") { EmptyView() }
            WindowCard {
                AppsPane(appState: appState, close: nil, listHeight: nil)
            }
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.bottom, 24)
    }
}
