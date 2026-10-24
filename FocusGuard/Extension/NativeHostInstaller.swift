import Foundation

/// The extension's identity and the native-messaging host it talks to.
enum BrowserExtensionIDs {
    /// The host name the extension passes to `chrome.runtime.connectNative`.
    static let hostName = "com.anar.focusguard"

    /// The ID the unpacked extension gets from the fixed `key` in
    /// `extension/chrome/manifest.json`, so it's the same on every Mac.
    static let development = "abeehapgjhkgbfokheomoahlgidgcoik"

    /// The Chrome Web Store assigns its own ID on first upload. Add it here
    /// (and drop the `key` from the store build's manifest) once the listing
    /// exists. Edge Add-ons would add a third.
    static let store: String? = nil

    static var all: [String] { [development] + (store.map { [$0] } ?? []) }

    /// File name of the helper inside FocusGuard.app/Contents/Helpers.
    static let helperName = "FocusGuardBrowserHelper"
}

/// Writes the native-messaging host manifest for every Chromium browser on
/// this Mac, so the extension can start FocusGuard's helper. The manifest
/// points at the helper inside this copy of the app; it's rewritten when the
/// app moves or the contents change. Browsers that aren't installed (no
/// support folder) are left alone.
struct NativeHostInstaller {
    struct Browser: Equatable {
        let name: String
        /// Under ~/Library/Application Support.
        let supportFolder: String

        var hostsFolder: String { supportFolder + "/NativeMessagingHosts" }
    }

    static let browsers: [Browser] = [
        Browser(name: "Google Chrome", supportFolder: "Google/Chrome"),
        Browser(name: "Google Chrome Beta", supportFolder: "Google/Chrome Beta"),
        Browser(name: "Google Chrome Canary", supportFolder: "Google/Chrome Canary"),
        Browser(name: "Arc", supportFolder: "Arc/User Data"),
        Browser(name: "Brave", supportFolder: "BraveSoftware/Brave-Browser"),
        Browser(name: "Microsoft Edge", supportFolder: "Microsoft Edge"),
        Browser(name: "Microsoft Edge Beta", supportFolder: "Microsoft Edge Beta"),
        Browser(name: "Chromium", supportFolder: "Chromium"),
        Browser(name: "Vivaldi", supportFolder: "Vivaldi"),
    ]

    let applicationSupport: URL
    let helperPath: String
    var fileManager: FileManager = .default

    init(applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support"),
         helperPath: String = Self.bundledHelperPath()) {
        self.applicationSupport = applicationSupport
        self.helperPath = helperPath
    }

    static func bundledHelperPath(bundle: Bundle = .main) -> String {
        bundle.bundleURL
            .appendingPathComponent("Contents/Helpers")
            .appendingPathComponent(BrowserExtensionIDs.helperName)
            .path
    }

    static func manifest(helperPath: String, extensionIDs: [String] = BrowserExtensionIDs.all) -> Data {
        let object: [String: Any] = [
            "name": BrowserExtensionIDs.hostName,
            "description": "FocusGuard",
            "path": helperPath,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        // Sorted keys so an unchanged manifest is byte-for-byte the same.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data()
    }

    func manifestURL(for browser: Browser) -> URL {
        applicationSupport
            .appendingPathComponent(browser.hostsFolder)
            .appendingPathComponent(BrowserExtensionIDs.hostName + ".json")
    }

    /// Browsers whose manifest is in place after this call.
    @discardableResult
    func install() -> [Browser] {
        let data = Self.manifest(helperPath: helperPath)
        var installed: [Browser] = []
        for browser in Self.browsers {
            let support = applicationSupport.appendingPathComponent(browser.supportFolder)
            guard fileManager.fileExists(atPath: support.path) else { continue }
            let url = manifestURL(for: browser)
            if fileManager.contents(atPath: url.path) == data {
                installed.append(browser)
                continue
            }
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                installed.append(browser)
            } catch {
                Persistence.logger.error("couldn't write the \(browser.name, privacy: .public) host manifest: \(error.localizedDescription, privacy: .public)")
            }
        }
        return installed
    }

    /// Removes every manifest this installer wrote.
    func uninstall() {
        for browser in Self.browsers {
            try? fileManager.removeItem(at: manifestURL(for: browser))
        }
    }
}
