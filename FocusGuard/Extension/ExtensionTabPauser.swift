import Foundation

/// Free "Pause the tab" through the browser extension: `tabs.update` to the
/// extension's own paused page, with the same fields and states as
/// paused.html (paused, queued, over, limit). No Automation permission, and
/// it reaches every Chromium browser the extension runs in.
@MainActor
final class ExtensionTabPauser: TabPauser {
    private weak var bridge: ExtensionBridge?

    init(bridge: ExtensionBridge) {
        self.bridge = bridge
    }

    func canPause(browser: String) -> Bool {
        bridge?.connectedBrowsers.contains(browser) ?? false
    }

    func pauseFrontTab(in browser: String, showing host: String, with page: URL,
                       completion: @escaping @MainActor (Bool) -> Void) {
        guard let bridge, let fragment = Self.fragment(of: page) else { return completion(false) }
        bridge.pauseFrontTab(browser: browser, host: host, fragment: fragment, completion: completion)
    }

    func redirectTab(showing pauseID: String, in browser: String, to url: URL) {
        guard let bridge, PausedPage.isValidID(pauseID) else { return }
        if Self.isWebPage(url) {
            bridge.redirectTab(pauseID: pauseID, browser: browser, url: url)
        } else if let fragment = Self.fragment(of: url) {
            bridge.redirectTab(pauseID: pauseID, browser: browser, fragment: fragment)
        }
    }

    /// The paused page's fields, still percent-encoded as `PausedPage` made them.
    nonisolated static func fragment(of page: URL) -> String? {
        URLComponents(url: page, resolvingAgainstBaseURL: false)?.percentEncodedFragment.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The site a tab goes back to, as opposed to the paused page.
    nonisolated static func isWebPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// Pauses through the extension in browsers where it's connected, and with
/// AppleScript everywhere else. A tab goes back through whichever paused it.
@MainActor
final class PreferringTabPauser: TabPauser {
    private let primary: TabPauser
    private let fallback: TabPauser
    /// Which one paused each tab, by pause id.
    private var pausedBy: [String: TabPauser] = [:]

    init(primary: TabPauser, fallback: TabPauser) {
        self.primary = primary
        self.fallback = fallback
    }

    func canPause(browser: String) -> Bool {
        primary.canPause(browser: browser) || fallback.canPause(browser: browser)
    }

    func pauseFrontTab(in browser: String, showing host: String, with page: URL,
                       completion: @escaping @MainActor (Bool) -> Void) {
        let pauser = primary.canPause(browser: browser) ? primary : fallback
        let id = Self.pauseID(in: page)
        pauser.pauseFrontTab(in: browser, showing: host, with: page) { [weak self] done in
            if done, let id { self?.pausedBy[id] = pauser }
            completion(done)
        }
    }

    func redirectTab(showing pauseID: String, in browser: String, to url: URL) {
        let pauser = pausedBy[pauseID] ?? (primary.canPause(browser: browser) ? primary : fallback)
        // Back at the site: this tab is done with.
        if ExtensionTabPauser.isWebPage(url) { pausedBy[pauseID] = nil }
        pauser.redirectTab(showing: pauseID, in: browser, to: url)
    }

    /// The `id` field of a paused page's fragment.
    nonisolated static func pauseID(in page: URL) -> String? {
        guard let fragment = ExtensionTabPauser.fragment(of: page) else { return nil }
        return fragment.split(separator: "&").lazy
            .compactMap { pair -> String? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                return parts.count == 2 && parts[0] == "id" ? String(parts[1]).removingPercentEncoding : nil
            }
            .first
    }
}
