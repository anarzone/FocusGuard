import AppKit
import SwiftUI

/// Settings › Sessions: the card when the user reaches for a distraction
/// while a tool works, and the tools that can say exactly when they finish.
struct SettingsWaitsSection: View {
    @AppStorage(WaitSettings.enabled) private var isOn = true
    @State private var states: [WaitConnector: WaitConnector.State] = [:]
    @State private var problem: String?
    @State private var copied = false

    private let files = WaitConnectorFiles()

    var body: some View {
        SettingsSection(String(localized: "While a tool works", comment: "Settings section: waits on an AI agent, a chat or a build")) {
            SettingsToggle(title: String(localized: "Warn me when I drift while a tool works"),
                           detail: String(localized: "When a tool is working and you open a distracting site, FocusGuard tells you what it cost last time and takes you back. Connected tools below say exactly when they work and finish; otherwise only a command running in a terminal counts. Never what you type."),
                           isOn: $isOn)
            ForEach(WaitConnector.allCases) { connector in
                SettingsDivider()
                SettingsRow(title: connector.name, detail: detail(connector)) {
                    button(connector)
                }
                .disabled(!isOn)
            }
            SettingsDivider()
            SettingsRow(title: String(localized: "Your own scripts and agents"),
                        detail: String(localized: "Add this to your shell, then run them as “fgwait ./my-agent.sh”.")) {
                Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(WaitConnector.shellFunction, forType: .string)
                    copied = true
                }
            }
            .disabled(!isOn)
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
            }
        }
        .onAppear(perform: refresh)
    }

    private func detail(_ connector: WaitConnector) -> String {
        switch states[connector] ?? .notInstalled {
        case .notInstalled:
            return String(localized: "Not on this Mac. Its waits are worked out from what’s in front.")
        case .notConnected:
            return connector == .claudeCode
                ? String(localized: "Adds hooks to its settings, so FocusGuard knows exactly when it starts, finishes or needs you. They share the folder’s name, which session it is and the time, never what you type.")
                : String(localized: "Adds a notify command to its settings, so FocusGuard knows exactly when a turn ends. It shares the folder’s name and the time, never what you type.")
        case .connected:
            return String(localized: "Connected: its waits are exact.")
        case .hasOwnNotify:
            return String(localized: "Codex already runs a notify command of yours, which FocusGuard won’t replace. Its waits are worked out from what’s in front.")
        }
    }

    @ViewBuilder
    private func button(_ connector: WaitConnector) -> some View {
        switch states[connector] ?? .notInstalled {
        case .notConnected:
            Button(String(localized: "Connect", comment: "Button: add FocusGuard's hook to a tool")) { change(connector, connect: true) }
        case .connected:
            Button(String(localized: "Disconnect", comment: "Button: take FocusGuard's hook out of a tool")) { change(connector, connect: false) }
        case .notInstalled, .hasOwnNotify:
            EmptyView()
        }
    }

    private func change(_ connector: WaitConnector, connect: Bool) {
        do {
            if connect { try files.connect(connector) } else { try files.disconnect(connector) }
            problem = nil
        } catch WaitConnector.Problem.hasOwnNotify {
            problem = nil
        } catch {
            problem = String(localized: "Couldn’t change \(connector.name)’s settings. Its file may not be valid JSON or TOML.",
                             comment: "The tool's name: Claude Code")
        }
        refresh()
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: WaitConnector.allCases.map { ($0, files.state($0)) })
    }
}
