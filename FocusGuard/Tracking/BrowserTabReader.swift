import AppKit
import Foundation

/// Reads the active tab URL from a frontmost browser via AppleScript.
///
/// Why AppleScript and not the Accessibility API:
/// - Chromium browsers gate their AX tree behind `AXManualAccessibility` for
///   performance. Even with the flag set, the tree is brittle.
/// - Every browser ships an AppleScript dictionary with a stable
///   `active tab` / `current tab` accessor.
///
/// Threading: NSAppleScript blocks the calling thread for ~50–200ms. Running
/// it on the main actor every tracker tick caused visible UI hitches, so we
/// run scripts on a serial background queue and post the result back to the
/// main actor via `lastFetchedURL` (an in-memory cache the tracker reads).
///
/// Permission model: NSAppleEventsUsageDescription is set in Info.plist. macOS
/// prompts the first time we send to each browser. Denials are remembered in
/// UserDefaults so we don't re-prompt on every launch.
@MainActor
final class BrowserTabReader {
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static func isBrowser(bundleIdentifier: String) -> Bool {
        browserBundleIDs.contains(bundleIdentifier)
    }

    // MARK: - In-memory snapshot

    /// Last fetched URL per browser bundle id. Updated from the background
    /// fetch queue once a script returns.
    private var fetchedURL: [String: String?] = [:]
    /// Background fetch in flight per bundle id. Prevents stacking calls.
    private var fetchInFlight: Set<String> = []
    /// Wall-clock time of last fetch attempt per bundle id (cache TTL).
    private var lastFetchAttempt: [String: Date] = [:]
    private let cacheTTL: TimeInterval = 2.0

    /// Bundle ids the user denied automation access for. Persisted across launches.
    private var deniedAutomation: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "browserAutomationDenied") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "browserAutomationDenied") }
    }

    private let scriptQueue = DispatchQueue(label: "com.anar.focusguard.applescript",
                                            qos: .userInitiated)

    // MARK: - Public API

    /// Returns the most recently fetched URL for this browser, kicking off a
    /// background refresh if the cache is stale. Non-blocking — the first call
    /// for a given browser returns nil; the next call (after the script
    /// finishes ~100ms later) returns the URL.
    func currentURL(forBundleId bundleId: String) -> String? {
        if deniedAutomation.contains(bundleId) {
            return nil
        }

        let now = Date()
        let isStale: Bool
        if let last = lastFetchAttempt[bundleId] {
            isStale = now.timeIntervalSince(last) >= cacheTTL
        } else {
            isStale = true
        }

        if isStale && !fetchInFlight.contains(bundleId) {
            fetchInFlight.insert(bundleId)
            lastFetchAttempt[bundleId] = now
            scheduleFetch(forBundleId: bundleId)
        }
        return fetchedURL[bundleId] ?? nil
    }

    func resetAutomationDenials() {
        deniedAutomation = []
        fetchedURL.removeAll()
        lastFetchAttempt.removeAll()
    }

    // MARK: - Background fetch

    private func scheduleFetch(forBundleId bundleId: String) {
        guard let appName = Self.appName(for: bundleId),
              let source = Self.scriptSource(for: bundleId, appName: appName) else {
            fetchInFlight.remove(bundleId)
            return
        }

        scriptQueue.async { [weak self] in
            let result = Self.runScript(source: source, bundleId: bundleId)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchInFlight.remove(bundleId)
                switch result {
                case .url(let url):
                    self.fetchedURL[bundleId] = url
                case .denied:
                    var denied = self.deniedAutomation
                    denied.insert(bundleId)
                    self.deniedAutomation = denied
                    self.fetchedURL[bundleId] = nil
                case .error:
                    self.fetchedURL[bundleId] = nil
                }
            }
        }
    }

    // MARK: - Script execution (off-main)

    private enum FetchResult {
        case url(String)
        case denied
        case error
    }

    private static func runScript(source: String, bundleId: String) -> FetchResult {
        guard let script = NSAppleScript(source: source) else { return .error }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743/-1744 = "Not authorized to send Apple events"
            if code == -1743 || code == -1744 {
                return .denied
            }
            return .error
        }
        let value = descriptor.stringValue ?? ""
        return value.isEmpty ? .error : .url(value)
    }

    // MARK: - Static script generation

    private static func appName(for bundleId: String) -> String? {
        switch bundleId {
        case "com.google.Chrome":            return "Google Chrome"
        case "com.google.Chrome.canary":     return "Google Chrome Canary"
        case "com.google.Chrome.beta":       return "Google Chrome Beta"
        case "com.brave.Browser":            return "Brave Browser"
        case "com.brave.Browser.beta":       return "Brave Browser Beta"
        case "com.microsoft.edgemac":        return "Microsoft Edge"
        case "com.microsoft.edgemac.Beta":   return "Microsoft Edge Beta"
        case "com.apple.Safari":             return "Safari"
        case "com.apple.SafariTechnologyPreview": return "Safari Technology Preview"
        case "company.thebrowser.Browser":   return "Arc"
        case "com.vivaldi.Vivaldi":          return "Vivaldi"
        case "com.operasoftware.Opera":      return "Opera"
        default: return nil
        }
    }

    private static func scriptSource(for bundleId: String, appName: String) -> String? {
        let isSafari = bundleId.hasPrefix("com.apple.Safari")
        let tabAccessor = isSafari ? "current tab" : "active tab"
        return """
            tell application "\(appName)"
                if (count of windows) is 0 then return ""
                try
                    return URL of \(tabAccessor) of front window
                on error
                    return ""
                end try
            end tell
        """
    }
}
