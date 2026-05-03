import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import UserNotifications

enum PermissionStatus: Equatable {
    case unknown
    case granted
    case denied
    case notDetermined
}

@Observable
@MainActor
final class PermissionsCoordinator {
    var notifications: PermissionStatus = .unknown
    var accessibility: PermissionStatus = .unknown
    var screenRecording: PermissionStatus = .unknown

    var allGranted: Bool {
        notifications == .granted
            && accessibility == .granted
            && screenRecording == .granted
    }

    func refresh() async {
        notifications = await currentNotificationStatus()
        accessibility = currentAccessibilityStatus()
        screenRecording = currentScreenRecordingStatus()
    }

    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings().authorizationStatus
        // requestAuthorization only pops a prompt when status is .notDetermined.
        // Once denied (or revoked via System Settings), Apple won't re-prompt
        // and silently returns — perceived as "the button does nothing". Fall
        // through to opening System Settings → Notifications for FocusGuard
        // so the user can flip it back on, same as the Accessibility / Screen
        // Recording flows.
        if current == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // refresh below will reflect the result.
            }
        } else if current == .denied {
            openSettings(path: "id=com.anar.focusguard", scheme: "notifications")
        }
        notifications = await currentNotificationStatus()
    }

    /// Triggers the system prompt the first time; subsequent calls just open
    /// System Settings if not yet granted.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibility = currentAccessibilityStatus()
        if accessibility != .granted {
            openSettings(path: "Privacy_Accessibility")
        }
    }

    /// Triggers the system prompt the first time; otherwise opens System Settings.
    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        screenRecording = currentScreenRecordingStatus()
        if screenRecording != .granted {
            openSettings(path: "Privacy_ScreenCapture")
        }
    }

    private func currentNotificationStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private func currentAccessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    private func currentScreenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private func openSettings(path: String, scheme: String = "security") {
        // Notifications lives under a different preference pane than security.
        let pane = scheme == "notifications" ? "com.apple.preference.notifications" : "com.apple.preference.security"
        let url = URL(string: "x-apple.systempreferences:\(pane)?\(path)")!
        NSWorkspace.shared.open(url)
    }
}
