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
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // The user denied or the request failed; refresh will reflect it.
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

    private func openSettings(path: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)")!
        NSWorkspace.shared.open(url)
    }
}
