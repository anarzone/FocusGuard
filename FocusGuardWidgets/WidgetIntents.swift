import AppIntents
import AppKit

// The buttons on the widgets and the Control Center control. They run in
// this sandboxed extension, which can't reach the session, so each one
// leaves a command for the app and waits briefly for it to be carried
// out; WidgetKit then reloads the widget with the new state. None of them
// shows in Shortcuts: the app has its own actions for that.

enum CommandSender {
    static let appBundleID = "com.anar.focusguard"

    static func send(_ action: SurfaceCommand.Action) async {
        guard let store = SurfaceStore.shared else { return }
        let command = SurfaceCommand(action: action, issuedAt: .now)
        do { try store.post(command) } catch { return }
        if await waitUntilHandled(command.id, in: store, seconds: 2) { return }
        // FocusGuard isn't running: open it; it takes waiting commands on launch.
        guard openAppIfNeeded() else { return }
        _ = await waitUntilHandled(command.id, in: store, seconds: 10)
    }

    private static func waitUntilHandled(_ id: UUID, in store: SurfaceStore, seconds: Double) async -> Bool {
        let steps = Int(seconds / 0.1)
        for _ in 0..<steps {
            if store.isHandled(id) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return store.isHandled(id)
    }

    /// The app that contains this extension, opened in the background.
    private static func openAppIfNeeded() -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty else { return false }
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        return true
    }
}

struct WidgetStartIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus Session"
    static let isDiscoverable = false

    @Parameter(title: "Minutes")
    var minutes: Int

    init() {}

    init(minutes: Int) {
        self.minutes = minutes
    }

    func perform() async throws -> some IntentResult {
        await CommandSender.send(.start(minutes: minutes))
        return .result()
    }
}

struct WidgetEndIntent: AppIntent {
    static let title: LocalizedStringResource = "End Focus Session"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await CommandSender.send(.end)
        return .result()
    }
}

struct WidgetPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Focus Session"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await CommandSender.send(.togglePause)
        return .result()
    }
}

struct WidgetEndBreakIntent: AppIntent {
    static let title: LocalizedStringResource = "End Break"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await CommandSender.send(.endBreak)
        return .result()
    }
}

struct WidgetExtendBreakIntent: AppIntent {
    static let title: LocalizedStringResource = "Add 5 Minutes to the Break"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await CommandSender.send(.extendBreak(minutes: 5))
        return .result()
    }
}

/// The Control Center control's toggle: on starts a session of the usual
/// length; off ends the session, or the break.
@available(macOS 26.0, *)
struct ControlSessionIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start or End Focus Session"
    static let isDiscoverable = false

    @Parameter(title: "Focusing")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let snapshot = SurfaceStore.shared?.readSnapshot()?.projected(to: .now)
        if let action = SurfaceSnapshot.controlAction(turningOn: value, snapshot: snapshot) {
            await CommandSender.send(action)
        }
        return .result()
    }
}
