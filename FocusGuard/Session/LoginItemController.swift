import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for "Launch at login".
/// `SMAppService` is the modern replacement for the LSSharedFileList APIs
/// — works on macOS 13+ without any helper bundle.
enum LoginItemController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[LoginItemController] toggle failed: \(error)\n".utf8
            ))
        }
    }
}
