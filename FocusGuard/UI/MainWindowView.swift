import SwiftUI

enum MainTab: Hashable {
    case reports, settings
}

struct MainWindowView: View {
    @Bindable var appState: AppState
    @State private var tab: MainTab

    init(appState: AppState, initialTab: MainTab = .reports) {
        self._appState = Bindable(wrappedValue: appState)
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            MainWindowToolbar(
                tab: $tab,
                status: statusText,
                onExport: { format in
                    DataExporter.export(format, container: appState.container)
                }
            )
                .frame(height: 52)
                .background(.regularMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }

            Group {
                switch tab {
                case .reports:
                    ReportsView(appState: appState)
                case .settings:
                    SettingsView(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .frame(minWidth: 880, minHeight: 580)
    }

    private var statusText: String {
        if appState.sessionManager.currentSession != nil {
            return "Session"
        }
        return "Tracking"
    }
}

// MARK: - Toolbar

struct MainWindowToolbar: View {
    @Binding var tab: MainTab
    let status: String
    var onExport: (DataExporter.Format) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 16) {
            // Traffic lights area is auto-managed by the OS at left of the title bar;
            // we leave a leading spacer matching its inset so our content lines up.
            Spacer().frame(width: 70)

            // App name + status badge
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("FocusGuard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(status)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            // Top tabs (NSToolbar pill segmented)
            HStack(spacing: 0) {
                tabButton(.reports, label: "Reports")
                tabButton(.settings, label: "Settings")
            }
            .padding(2)
            .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 7))

            // Toolbar actions (Export... shown only on Reports)
            HStack(spacing: 6) {
                if tab == .reports {
                    Menu {
                        Button("Export as JSON…")  { onExport(.json) }
                        Button("Export as CSV…")   { onExport(.csv) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export")
                        }
                        .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 100, alignment: .trailing)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }

    private func tabButton(_ kind: MainTab, label: String) -> some View {
        Button {
            tab = kind
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(
                    tab == kind ? Theme.cardBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
    }
}
