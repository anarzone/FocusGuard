import AppKit
import ApplicationServices
import Foundation

/// How picking up reaches other apps. Behind a protocol so tests never
/// activate or open anything real.
@MainActor
protocol PickUpOpening: AnyObject {
    /// Brings the app to the front, opening it if it was quit.
    func bringToFront(bundleId: String) async -> Bool
    /// Whether the browser already shows this page, so it needn't open again.
    func isShowing(_ url: String, inBrowser bundleId: String) -> Bool
    /// Opens the page in the browser it came from.
    func openPage(_ url: URL, inBrowser bundleId: String) async -> Bool
    /// Opens the page wherever the Mac opens web pages.
    func openInDefaultBrowser(_ url: URL)
    /// Raises the app's window with this title, where Accessibility is already allowed.
    func raiseWindow(bundleId: String, title: String) -> Bool
    /// Reopens the document last seen under this title, if macOS said which it was.
    func reopenDocument(bundleId: String, title: String) async -> Bool
    /// The user's in this window now: notes its document, for this run only.
    func noteFrontWindow(bundleId: String, title: String?)
}

/// Goes back to the places, the last-used app last so it ends up in front.
enum PickUpRestore {
    struct Result: Equatable {
        var back: [PickUpPlace] = []
        var failed: [PickUpPlace] = []
    }

    /// `places` newest first, as the card lists them.
    @MainActor
    static func run(_ places: [PickUpPlace], with opener: PickUpOpening) async -> Result {
        var result = Result()
        for place in places.reversed() {
            guard await opener.bringToFront(bundleId: place.bundleId) else {
                result.failed.insert(place, at: 0)
                continue
            }
            if let address = place.url {
                guard let url = URL(string: address) else {
                    result.failed.insert(place, at: 0)
                    continue
                }
                if !opener.isShowing(address, inBrowser: place.bundleId) {
                    guard await opener.openPage(url, inBrowser: place.bundleId) else {
                        result.failed.insert(place, at: 0)
                        continue
                    }
                }
            } else if let title = place.title, !opener.raiseWindow(bundleId: place.bundleId, title: title) {
                // The app's in front either way; the exact document is a bonus.
                _ = await opener.reopenDocument(bundleId: place.bundleId, title: title)
            }
            result.back.insert(place, at: 0)
        }
        return result
    }
}

/// Used by the UI tests' copy of the app, which keeps to itself.
@MainActor
final class NoPickUpOpener: PickUpOpening {
    func bringToFront(bundleId: String) async -> Bool { false }
    func isShowing(_ url: String, inBrowser bundleId: String) -> Bool { false }
    func openPage(_ url: URL, inBrowser bundleId: String) async -> Bool { false }
    func openInDefaultBrowser(_ url: URL) {}
    func raiseWindow(bundleId: String, title: String) -> Bool { false }
    func reopenDocument(bundleId: String, title: String) async -> Bool { false }
    func noteFrontWindow(bundleId: String, title: String?) {}
}

/// The real thing, through NSWorkspace and, where it's already allowed,
/// Accessibility. Nothing here asks for a permission.
@MainActor
final class SystemPickUpOpener: PickUpOpening {
    /// The page a browser last showed, from the extension (set by AppState).
    var lastPage: (String) -> String? = { _ in nil }

    /// Documents macOS named for each app's window, for this run only.
    private var documents: [String: (title: String?, url: URL)] = [:]

    nonisolated private static let messagingTimeout: Float = 0.25

    func bringToFront(bundleId: String) async -> Bool {
        guard let app = appURL(bundleId) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
                done.resume(returning: running != nil && error == nil)
            }
        }
        // Lets the switch land, so the next app comes up in front of this one.
        try? await Task.sleep(for: .milliseconds(150))
        return opened
    }

    func isShowing(_ url: String, inBrowser bundleId: String) -> Bool {
        lastPage(bundleId) == url
    }

    func openPage(_ url: URL, inBrowser bundleId: String) async -> Bool {
        guard let browser = appURL(bundleId) else { return false }
        return await open(url, with: browser)
    }

    func openInDefaultBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func raiseWindow(bundleId: String, title: String) -> Bool {
        guard AXIsProcessTrusted(), let app = running(bundleId) else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var name: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &name) == .success,
                  name as? String == title else { continue }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
        return false
    }

    func reopenDocument(bundleId: String, title: String) async -> Bool {
        guard let document = documents[bundleId], document.title == title,
              FileManager.default.fileExists(atPath: document.url.path),
              let app = appURL(bundleId) else { return false }
        return await open(document.url, with: app)
    }

    func noteFrontWindow(bundleId: String, title: String?) {
        guard AXIsProcessTrusted(), let pid = running(bundleId)?.processIdentifier else { return }
        // Accessibility waits on the other app, so not on the main thread.
        Task.detached(priority: .utility) { [weak self] in
            let url = Self.frontDocument(pid: pid)
            await MainActor.run {
                self?.documents[bundleId] = url.map { (title, $0) }
            }
        }
    }

    nonisolated private static func frontDocument(pid: pid_t) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(focused, to: AXUIElement.self), kAXDocumentAttribute as CFString, &document) == .success,
              let address = document as? String, let url = URL(string: address), url.isFileURL else { return nil }
        return url
    }

    private func open(_ url: URL, with app: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { running, error in
                done.resume(returning: running != nil && error == nil)
            }
        }
    }

    private func running(_ bundleId: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    /// The running copy first, in case several are installed.
    private func appURL(_ bundleId: String) -> URL? {
        running(bundleId)?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }
}
