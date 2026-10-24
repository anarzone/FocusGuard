import AppKit
import XCTest
@testable import FocusGuard

/// Free "Pause the tab": the `focusguard://` routes, the paused page's URL,
/// and what happens to a paused tab through a session.
@MainActor
final class TabPauseTests: XCTestCase {

    // MARK: - Routes

    func test_routes_parse() {
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://back")!), .back)
        XCTAssertEqual(FocusGuardURL(URL(string: "FocusGuard://Back")!), .back)
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://tab/reopen-later?id=ab-12")!), .reopenLater(pauseID: "ab-12"))
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://tab/keep-paused?id=ab-12")!), .keepPaused(pauseID: "ab-12"))
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://break?minutes=10")!), .startBreak(minutes: 10))
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://break")!), .startBreak(minutes: 10))
    }

    func test_routes_roundTrip() {
        let routes: [FocusGuardURL] = [.back, .reopenLater(pauseID: "x-1"), .keepPaused(pauseID: "x-1"), .startBreak(minutes: 25)]
        for route in routes {
            XCTAssertEqual(FocusGuardURL(route.url), route, route.url.absoluteString)
        }
    }

    func test_routes_refuseAnythingElse() {
        XCTAssertNil(FocusGuardURL(URL(string: "https://back")!))
        XCTAssertNil(FocusGuardURL(URL(string: "focusguard://session/end")!))
        XCTAssertNil(FocusGuardURL(URL(string: "focusguard://tab/reopen-later")!), "needs an id")
        XCTAssertNil(FocusGuardURL(URL(string: "focusguard://tab/reopen-later?id=a%22b")!), "ids are plain")
        XCTAssertNil(FocusGuardURL(URL(string: "focusguard://tab/keep-paused?id=")!))
    }

    func test_breakMinutes_areKeptInRange() {
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://break?minutes=900")!), .startBreak(minutes: 60))
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://break?minutes=-3")!), .startBreak(minutes: 1))
    }

    // MARK: - The page's URL

    private let base = URL(fileURLWithPath: "/Applications/FocusGuard.app/Contents/Resources/paused.html")

    /// The page's fields, decoded the way its script does.
    private func fields(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (url.fragment(percentEncoded: true) ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            out[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return out
    }

    private func tab(_ reason: PausedTab.Reason = .session, url: String = "https://x.com/home?a=1&b=2#top") -> PausedTab {
        PausedTab(id: "id-1", browser: "com.apple.Safari", host: "x.com", originalURL: URL(string: url)!,
                  reason: reason, endsAt: Date(timeIntervalSince1970: 1_792_840_000), backTo: "Xcode & Co")
    }

    func test_pageURL_carriesTheStateSafely() {
        let url = PausedPage.url(base: base, for: tab(), state: .paused)
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, base.path)
        let f = fields(url)
        XCTAssertEqual(f["id"], "id-1")
        XCTAssertEqual(f["host"], "x.com")
        XCTAssertEqual(f["url"], "https://x.com/home?a=1&b=2#top")
        XCTAssertEqual(f["state"], "paused")
        XCTAssertEqual(f["ends"], "1792840000")
        XCTAssertEqual(f["back"], "Xcode & Co")
        XCTAssertNil(f["minutes"])
        XCTAssertFalse(url.absoluteString.contains("\""), "it travels inside an AppleScript string")
        XCTAssertTrue(url.absoluteString.contains(PausedPage.idMarker("id-1")))
    }

    func test_pageURL_forALimit() {
        let f = fields(PausedPage.url(base: base, for: tab(.limit(minutes: 30)), state: .limit))
        XCTAssertEqual(f["state"], "limit")
        XCTAssertEqual(f["minutes"], "30")
    }

    func test_ids() {
        XCTAssertTrue(PausedPage.isValidID(PausedPage.newID()))
        XCTAssertFalse(PausedPage.isValidID("a\"b"))
        XCTAssertFalse(PausedPage.isValidID("a&b"))
        XCTAssertFalse(PausedPage.isValidID(String(repeating: "a", count: 65)))
    }

    func test_appleScriptLiteral_escapesQuotes() {
        XCTAssertEqual(AppleScriptTabPauser.literal(#"a"b\c"#), #""a\"b\\c""#)
    }

    /// The scripts against each browser's dictionary, where it's installed.
    func test_tabScriptsCompile() throws {
        let page = PausedPage.url(base: base, for: tab(), state: .paused)
        var checked = 0
        for browser in AppleScriptTabPauser.appNames.keys.sorted()
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) != nil {
            let scripts = [AppleScriptTabPauser.frontURLScript(browser),
                           AppleScriptTabPauser.pauseScript(browser, page: page),
                           AppleScriptTabPauser.redirectScript(browser, pauseID: "id-1", to: page)]
            for source in scripts {
                let script = try XCTUnwrap(NSAppleScript(source: try XCTUnwrap(source)))
                var error: NSDictionary?
                XCTAssertTrue(script.compileAndReturnError(&error), "\(browser)\n\(String(describing: error))")
            }
            checked += 1
        }
        try XCTSkipIf(checked == 0, "no supported browser installed")
    }

    func test_thePageShipsInTheApp_andLoadsNothingOnline() throws {
        let url = try XCTUnwrap(PausedPage.fileURL, "paused.html is missing from the app's resources")
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("http://") || html.contains("https://"), "no remote resources")
        XCTAssertTrue(html.contains("focusguard://"))
    }

    // MARK: - The coordinator

    final class FakePauser: TabPauser {
        var browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
        var succeeds = true
        /// Hold completions back to act like a slow script.
        var holds = false
        var held: [@MainActor (Bool) -> Void] = []
        var pauses: [(browser: String, host: String, page: URL)] = []
        var redirects: [(id: String, browser: String, url: URL)] = []

        func canPause(browser: String) -> Bool { browsers.contains(browser) }
        func pauseFrontTab(in browser: String, showing host: String, with page: URL,
                           completion: @escaping @MainActor (Bool) -> Void) {
            pauses.append((browser, host, page))
            if holds { held.append(completion) } else { completion(succeeds) }
        }
        func redirectTab(showing pauseID: String, in browser: String, to url: URL) {
            redirects.append((pauseID, browser, url))
        }
    }

    private var pauser: FakePauser!
    private var coordinator: TabPauseCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        pauser = FakePauser()
        coordinator = TabPauseCoordinator(pauser: pauser, page: base)
    }

    private func snap(_ url: String?, bundleId: String = "com.apple.Safari") -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleId, appName: "Safari", windowTitle: nil,
                         url: url, classification: .distraction, observedAt: .now)
    }

    private func pause(_ url: String = "https://www.x.com/home", reason: PausedTab.Reason = .session) -> String? {
        coordinator.blockShown(reason, snapshot: snap(url), endsAt: Date(timeIntervalSince1970: 1_792_840_000), backTo: "Xcode")
        return coordinator.lastPausedID
    }

    func test_blockScreen_pausesTheFrontTab() throws {
        let id = try XCTUnwrap(pause())
        XCTAssertEqual(pauser.pauses.count, 1)
        XCTAssertEqual(pauser.pauses.first?.host, "x.com")
        let f = fields(try XCTUnwrap(pauser.pauses.first?.page))
        XCTAssertEqual(f["state"], "paused")
        XCTAssertEqual(f["back"], "Xcode")
        XCTAssertEqual(f["id"], id)
        XCTAssertEqual(coordinator.tabs[id]?.originalURL.absoluteString, "https://www.x.com/home")
    }

    func test_onlyWebPagesInSupportedBrowsersArePaused() {
        coordinator.blockShown(.session, snapshot: snap(nil, bundleId: "com.valvesoftware.steam"), endsAt: nil, backTo: nil)
        coordinator.blockShown(.session, snapshot: snap("https://x.com", bundleId: "org.mozilla.firefox"), endsAt: nil, backTo: nil)
        coordinator.blockShown(.session, snapshot: snap("file:///Users/me/notes.html"), endsAt: nil, backTo: nil)
        coordinator.isEnabled = false
        coordinator.blockShown(.session, snapshot: snap("https://x.com"), endsAt: nil, backTo: nil)
        XCTAssertTrue(pauser.pauses.isEmpty)
        XCTAssertNil(coordinator.lastPausedID)
    }

    func test_aFailedPause_isForgotten() {
        pauser.succeeds = false
        _ = pause()
        XCTAssertTrue(coordinator.tabs.isEmpty)
        XCTAssertNil(coordinator.lastPausedID)
    }

    func test_letThrough_putsTheTabBack() throws {
        let id = try XCTUnwrap(pause())
        coordinator.letThrough()
        XCTAssertEqual(pauser.redirects.first?.id, id)
        XCTAssertEqual(pauser.redirects.first?.url.absoluteString, "https://www.x.com/home")
        XCTAssertTrue(coordinator.tabs.isEmpty)
    }

    func test_letThroughBeforeThePauseLands_stillPutsItBack() throws {
        pauser.holds = true
        let id = try XCTUnwrap(pause())
        coordinator.letThrough()
        XCTAssertTrue(pauser.redirects.isEmpty)
        pauser.held.first?(true)
        XCTAssertEqual(pauser.redirects.first?.id, id)
        XCTAssertEqual(pauser.redirects.first?.url.absoluteString, "https://www.x.com/home")
        XCTAssertTrue(coordinator.tabs.isEmpty)
    }

    func test_reopenLater_andUndo_updateThePage() throws {
        let id = try XCTUnwrap(pause())
        coordinator.setReopensAfterSession(true, pauseID: id)
        XCTAssertEqual(fields(try XCTUnwrap(pauser.redirects.last?.url))["state"], "queued")
        coordinator.setReopensAfterSession(false, pauseID: id)
        XCTAssertEqual(fields(try XCTUnwrap(pauser.redirects.last?.url))["state"], "paused")
        XCTAssertEqual(coordinator.browser(for: id), "com.apple.Safari")
    }

    func test_unknownIds_areIgnored() {
        coordinator.setReopensAfterSession(true, pauseID: "nope")
        XCTAssertTrue(pauser.redirects.isEmpty)
    }

    func test_sessionEnd_reopensQueuedTabs_andOffersABreakOnTheRest() throws {
        let queued = try XCTUnwrap(pause("https://x.com/a"))
        let stays = try XCTUnwrap(pause("https://reddit.com/r/b"))
        let limited = try XCTUnwrap(pause("https://youtube.com/c", reason: .limit(minutes: 30)))
        coordinator.setReopensAfterSession(true, pauseID: queued)
        pauser.redirects = []

        coordinator.sessionEnded()

        let byID = Dictionary(uniqueKeysWithValues: pauser.redirects.map { ($0.id, $0.url) })
        XCTAssertEqual(byID[queued]?.absoluteString, "https://x.com/a")
        XCTAssertEqual(fields(try XCTUnwrap(byID[stays]))["state"], "over")
        XCTAssertNil(byID[limited], "a limit's pause lasts until midnight, not the session")
        XCTAssertEqual(Array(coordinator.tabs.keys), [limited])
    }

    func test_aLimitPause_hasNoSessionClock() throws {
        _ = pause("https://youtube.com/c", reason: .limit(minutes: 30))
        let f = fields(try XCTUnwrap(pauser.pauses.first?.page))
        XCTAssertEqual(f["state"], "limit")
        XCTAssertNil(f["ends"])
    }
}
