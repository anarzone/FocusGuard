import AppKit

/// Brings another app to the front from FocusGuard, which is never the active
/// app when its island or menu is pressed. `NSRunningApplication.activate()`
/// is ignored then (macOS 14 on), so this asks the system to open the app,
/// which brings it forward whether it's running or not.
@MainActor
enum AppActivator {
    static func bringForward(_ bundleId: String, then: (() -> Void)? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
            then?()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { then?() }
        }
    }
}
