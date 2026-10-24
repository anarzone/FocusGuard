import AppKit
import Foundation

/// Points browser tabs at FocusGuard's paused page and back. The AppleScript
/// version works with no extension; the browser extension can add its own
/// implementation (tabs.update) and take over for the browsers it's in.
@MainActor
protocol TabPauser: AnyObject {
    /// Whether this pauser can act on that browser (by bundle id).
    func canPause(browser: String) -> Bool
    /// Points the browser's front tab at `page`, but only if it still shows
    /// `host` (or a subdomain). Reports whether it did, on the main actor.
    func pauseFrontTab(in browser: String, showing host: String, with page: URL,
                       completion: @escaping @MainActor (Bool) -> Void)
    /// Points the tab showing paused page `pauseID` at `url`: the page in
    /// another state, or the site it paused.
    func redirectTab(showing pauseID: String, in browser: String, to url: URL)
}

/// Free level 1: pauses tabs through each browser's AppleScript dictionary,
/// the same access `BrowserTabReader` already uses to read the URL, so it
/// asks for no new permission. Scripts run off the main thread, in order,
/// on the shared AppleScript queue.
@MainActor
final class AppleScriptTabPauser: TabPauser {
    /// Safari, Chrome, Arc, Brave and Edge.
    nonisolated static let appNames: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave Browser",
        "com.brave.Browser.beta": "Brave Browser Beta",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
    ]

    private let queue = AppleScriptQueue.shared

    func canPause(browser: String) -> Bool { Self.appNames[browser] != nil }

    func pauseFrontTab(in browser: String, showing host: String, with page: URL,
                       completion: @escaping @MainActor (Bool) -> Void) {
        guard let read = Self.frontURLScript(browser), let write = Self.pauseScript(browser, page: page),
              Self.isRunning(browser) else { return completion(false) }
        queue.async {
            // Check the tab still shows the site, then swap it, back to back.
            let current = Self.run(read).flatMap { URL(string: $0)?.host }
            let done = current.map { Classifier.host($0, matches: host) } == true && Self.run(write) == "ok"
            DispatchQueue.main.async { completion(done) }
        }
    }

    func redirectTab(showing pauseID: String, in browser: String, to url: URL) {
        guard PausedPage.isValidID(pauseID), let script = Self.redirectScript(browser, pauseID: pauseID, to: url),
              Self.isRunning(browser) else { return }
        queue.async { _ = Self.run(script) }
    }

    // MARK: - Scripts

    nonisolated static func frontURLScript(_ browser: String) -> String? {
        guard let app = appNames[browser] else { return nil }
        return """
            tell application \(literal(app))
                if (count of windows) is 0 then return ""
                return URL of \(frontTab(for: browser))
            end tell
            """
    }

    nonisolated static func pauseScript(_ browser: String, page: URL) -> String? {
        guard let app = appNames[browser] else { return nil }
        return """
            tell application \(literal(app))
                set URL of \(frontTab(for: browser)) to \(literal(page.absoluteString))
                return "ok"
            end tell
            """
    }

    /// Finds the tab by the id in its paused page's URL, in any window.
    nonisolated static func redirectScript(_ browser: String, pauseID: String, to url: URL) -> String? {
        guard let app = appNames[browser] else { return nil }
        return """
            tell application \(literal(app))
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) contains \(literal(PausedPage.idMarker(pauseID))) then
                            set URL of t to \(literal(url.absoluteString))
                            return "ok"
                        end if
                    end repeat
                end repeat
                return ""
            end tell
            """
    }

    /// `tell application` launches a browser that isn't running; never do that.
    private static func isRunning(_ browser: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: browser).isEmpty
    }

    nonisolated static func frontTab(for browser: String) -> String {
        browser.hasPrefix("com.apple.Safari") ? "current tab of front window" : "active tab of front window"
    }

    /// A quoted AppleScript string.
    nonisolated static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The script's text result; nil on any error, a denied permission included.
    nonisolated private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}
