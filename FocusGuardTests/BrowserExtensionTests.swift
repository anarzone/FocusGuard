import Darwin
import SwiftData
import XCTest
@testable import FocusGuard

/// The browser extension's message protocol, framing, host manifests and
/// the app's bookkeeping of connected extensions.
@MainActor
final class BrowserExtensionTests: XCTestCase {

    // MARK: - Framing

    func test_framesRoundTripThroughPartialReads() throws {
        let one = Data(#"{"type":"hello"}"#.utf8)
        let two = Data(#"{"type":"tab","tab":null}"#.utf8)
        let stream = NativeMessageFraming.frame(one) + NativeMessageFraming.frame(two)
        XCTAssertEqual(Array(stream.prefix(4)), [UInt8(one.count), 0, 0, 0], "length is little-endian")

        var buffer = Data()
        var received: [Data] = []
        // Feed it a few bytes at a time, the way a socket can.
        for chunk in stride(from: 0, to: stream.count, by: 5) {
            buffer.append(stream[chunk..<min(chunk + 5, stream.count)])
            received += try NativeMessageFraming.takeFrames(from: &buffer)
        }
        XCTAssertEqual(received, [one, two])
        XCTAssertTrue(buffer.isEmpty)
    }

    func test_oversizedFrameIsRejected() {
        var length = UInt32(NativeMessageFraming.maxMessageBytes + 1).littleEndian
        var buffer = Data(bytes: &length, count: 4)
        XCTAssertThrowsError(try NativeMessageFraming.takeFrames(from: &buffer)) { error in
            XCTAssertEqual(error as? NativeMessageFraming.FrameError, .tooLarge(NativeMessageFraming.maxMessageBytes + 1))
        }
    }

    func test_socketLivesInApplicationSupportUnlessThePathIsTooLong() {
        XCTAssertEqual(BrowserSocketLocation.path(home: "/Users/ann", uid: 501, environment: [:]),
                       "/Users/ann/Library/Application Support/FocusGuard/browser.sock")
        let longHome = "/Users/" + String(repeating: "a", count: 80)
        XCTAssertEqual(BrowserSocketLocation.path(home: longHome, uid: 501, environment: [:]), "/tmp/focusguard-501.sock")
        XCTAssertEqual(BrowserSocketLocation.path(home: "/Users/ann", uid: 501,
                                                  environment: [BrowserSocketLocation.overrideVariable: "/tmp/x.sock"]),
                       "/tmp/x.sock")
    }

    // MARK: - Extension → app

    private func decode(_ json: String) throws -> ExtensionMessage {
        try ExtensionMessage.decode(Data(json.utf8))
    }

    func test_decodesEveryMessageTheExtensionSends() throws {
        XCTAssertEqual(try decode(#"{"type":"helperHello","browser":"com.google.Chrome","origin":"chrome-extension://abc/"}"#),
                       .helperHello(browser: "com.google.Chrome", origin: "chrome-extension://abc/"))
        XCTAssertEqual(try decode(#"{"type":"hello","v":1,"extensionVersion":"1.0.0","siteAccess":true,"incognito":false}"#),
                       .hello(extensionVersion: "1.0.0", siteAccess: true, incognito: false))
        XCTAssertEqual(try decode(#"{"type":"tab","tab":{"url":"https://x.com/home","title":"Home / X","tabId":7,"windowId":2}}"#),
                       .tab(BrowserTabReport(url: "https://x.com/home", title: "Home / X", tabId: 7, windowId: 2)))
        XCTAssertEqual(try decode(#"{"type":"tab","tab":null}"#), .tab(nil))
        XCTAssertEqual(try decode(#"{"type":"tab","tab":{"url":"https://www.youtube.com/watch?v=1","title":"Talk - YouTube","video":{"title":"Talk","channel":"Swift"}}}"#),
                       .tab(BrowserTabReport(url: "https://www.youtube.com/watch?v=1", title: "Talk - YouTube",
                                             video: .init(title: "Talk", channel: "Swift"))))
        XCTAssertEqual(try decode(#"{"type":"classify","id":"1","url":"https://medium.com/a"}"#),
                       .classify(id: "1", url: "https://medium.com/a"))
        XCTAssertEqual(try decode(#"{"type":"setCategory","id":"2","url":"https://medium.com/a","scope":"page","category":"distracting"}"#),
                       .setCategory(id: "2", url: "https://medium.com/a", scope: .page, category: .distracting))
        XCTAssertEqual(try decode(#"{"type":"startSession","id":"3","minutes":50}"#), .startSession(id: "3", minutes: 50))
        XCTAssertEqual(try decode(#"{"type":"startSession","id":"4","minutes":null}"#), .startSession(id: "4", minutes: nil))
        XCTAssertEqual(try decode(#"{"type":"extendBreak","id":"5","minutes":5}"#), .extendBreak(id: "5", minutes: 5))
        XCTAssertEqual(try decode(#"{"type":"endBreak","id":"6"}"#), .endBreak(id: "6"))
        XCTAssertEqual(try decode(#"{"type":"openApp","page":"reports"}"#), .openApp(page: "reports"))
        XCTAssertEqual(try decode(#"{"type":"backToWork","id":"7"}"#), .backToWork(id: "7"))
        XCTAssertEqual(try decode(#"{"type":"requestPass","id":"8","host":"www.x.com"}"#), .requestPass(id: "8", host: "www.x.com"))
        XCTAssertEqual(try decode(#"{"type":"allowForWork","id":"9","host":"x.com"}"#), .allowForWork(id: "9", host: "x.com"))
        XCTAssertEqual(try decode(#"{"type":"requestExtraTime","id":"10","site":"reddit.com"}"#), .requestExtraTime(id: "10", site: "reddit.com"))
        XCTAssertEqual(try decode(#"{"type":"blockedVisit","host":"x.com"}"#), .blockedVisit(host: "x.com"))
        XCTAssertEqual(try decode(#"{"type":"pauseResult","rid":"r1","ok":true}"#), .pauseResult(requestId: "r1", ok: true))
        XCTAssertEqual(try decode(#"{"type":"tabAction","id":"12","action":"reopenLater","pauseId":"abc-1"}"#),
                       .tabAction(id: "12", action: "reopenLater", pauseID: "abc-1", minutes: nil))
        XCTAssertEqual(try decode(#"{"type":"somethingNew","id":"11"}"#), .unknown(type: "somethingNew", id: "11"))
    }

    func test_requestsWithoutTheirFieldsAreRejected() {
        XCTAssertThrowsError(try decode(#"{"type":"classify","url":"https://x.com"}"#))
        XCTAssertThrowsError(try decode(#"{"type":"setCategory","id":"1","url":"https://x.com"}"#))
        XCTAssertThrowsError(try decode(#"{"type":"setCategory","id":"1","url":"https://x.com","category":"boring"}"#))
        XCTAssertThrowsError(try decode(#"{"no":"type"}"#))
    }

    // MARK: - App → extension

    /// The fixture the extension's own tests read: if this encoding changes,
    /// both sides notice.
    func test_stateEncodesLikeTheSharedFixture() throws {
        let state = ExtensionState(
            app: .init(version: "1.0"),
            plan: .init(tier: "pro", pro: true, trialDaysLeft: nil, features: Self.allFeatures),
            preset: "standard",
            policy: .standard,
            today: .init(focusSeconds: 10080, goalMinutes: 240),
            phase: .focusing,
            session: .init(
                name: "Evening focus", startedAt: 1_793_034_000_000, endsAt: 1_793_037_000_000,
                plannedMinutes: 50, elapsedSeconds: 1620, asOf: 1_793_035_620_000, paused: false,
                segments: [.init(kind: "f", seconds: 720), .init(kind: "o", seconds: 60), .init(kind: "f", seconds: 660),
                           .init(kind: "d", seconds: 120), .init(kind: "f", seconds: 60)],
                focusSeconds: 1440, driftSeconds: 120, otherSeconds: 60, stoppedVisits: 4, backTo: "Xcode"
            ),
            blocking: .init(
                pauseTab: true,
                sites: ["instagram.com", "news.ycombinator.com", "reddit.com", "x.com"],
                parts: ["linkedin.com/feed", "youtube.com/shorts"],
                limits: [], passes: [.init(host: "x.com", until: 1_793_035_700_000)],
                allowed: ["github.com"], lockedUntil: nil
            )
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL("state-focusing.json"))) as? NSDictionary
        XCTAssertEqual(encoded, fixture)
    }

    func test_breakStateUsesTheBreakKey() throws {
        var state = ExtensionState(
            app: .init(version: "1.0"), plan: .init(tier: "free", pro: false, trialDaysLeft: nil, features: Self.noFeatures),
            preset: "gentle", policy: .gentle,
            today: .init(focusSeconds: 0, goalMinutes: 240), phase: .onBreak,
            blocking: .init(pauseTab: true, sites: [], parts: [], limits: [], passes: [], allowed: [], lockedUntil: nil)
        )
        state.breakInfo = .init(startedAt: 0, endsAt: 600_000, plannedSeconds: 600, after: "Deep Dive · 50 min", canEndEarly: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertEqual(json["phase"] as? String, "break")
        XCTAssertEqual((json["break"] as? [String: Any])?["plannedSeconds"] as? Int, 600)
        XCTAssertNil(json["session"], "nil fields are left out")
    }

    func test_repliesAndCommandsCarryTheirType() throws {
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        let reply = try object(ExtensionReply(id: "1", ok: true, result: .init(host: "x.com", category: .distracting, ruleScope: .site)))
        XCTAssertEqual(reply["type"] as? String, "reply")
        XCTAssertEqual(reply["id"] as? String, "1")
        XCTAssertEqual((reply["result"] as? [String: Any])?["category"] as? String, "distracting")

        let pause = try object(PauseTabCommand(rid: "r1", host: "x.com", tabId: 3, fragment: "id=a&host=x.com&state=paused"))
        XCTAssertEqual(pause["type"] as? String, "pauseTab")
        XCTAssertEqual(pause["tabId"] as? Int, 3)
        XCTAssertEqual(pause["fragment"] as? String, "id=a&host=x.com&state=paused")
        let redirect = try object(RedirectTabCommand(pauseId: "a", url: "https://x.com/home"))
        XCTAssertEqual(redirect["type"] as? String, "redirectTab")
        XCTAssertNil(redirect["fragment"])
        XCTAssertEqual(try object(RefreshCommand())["type"] as? String, "refresh")
    }

    func test_categoriesMapToClassifications() {
        XCTAssertEqual(BrowserCategory(.distraction), .distracting)
        XCTAssertEqual(BrowserCategory.focus.classification, .focus)
        XCTAssertEqual(BrowserCategory.neutral.classification, .neutral)
    }

    // MARK: - Host manifests

    func test_manifestPointsAtTheHelperForTheExtension() throws {
        let data = NativeHostInstaller.manifest(helperPath: "/Applications/FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "com.anar.focusguard")
        XCTAssertEqual(json["type"] as? String, "stdio")
        XCTAssertEqual(json["path"] as? String, "/Applications/FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper")
        XCTAssertEqual(json["allowed_origins"] as? [String], ["chrome-extension://\(BrowserExtensionIDs.development)/"])
    }

    func test_installWritesOnlyForInstalledBrowsersAndFollowsTheApp() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        for folder in ["Google/Chrome", "Arc/User Data", "Microsoft Edge"] {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let installer = NativeHostInstaller(applicationSupport: support, helperPath: "/A/FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper")
        XCTAssertEqual(installer.install().map(\.name), ["Google Chrome", "Arc", "Microsoft Edge"])
        let chrome = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.anar.focusguard.json")
        let arc = support.appendingPathComponent("Arc/User Data/NativeMessagingHosts/com.anar.focusguard.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chrome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: arc.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("BraveSoftware").path),
                       "a browser that isn't installed gets nothing")

        // The app moved: the manifest follows.
        let moved = NativeHostInstaller(applicationSupport: support, helperPath: "/B/FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper")
        moved.install()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: chrome)) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "/B/FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper")

        moved.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: chrome.path))
    }

    func test_helperShipsInsideTheApp() {
        XCTAssertTrue(NativeHostInstaller.bundledHelperPath().hasSuffix("FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: NativeHostInstaller.bundledHelperPath()))
    }

    // MARK: - Connected extensions

    func test_trackerUsesTheFrontProfilesTabAndFallsBackWithoutAnExtension() {
        let bridge = ExtensionBridge(socketPath: Self.temporarySocketPath())
        let work = BrowserSocketServer.ClientID(raw: 1)
        let home = BrowserSocketServer.ClientID(raw: 2)
        XCTAssertNil(bridge.tab(forBrowser: "com.google.Chrome"), "no extension: the tracker uses AppleScript")

        for id in [work, home] {
            bridge.connected(id)
            bridge.handle(.helperHello(browser: "com.google.Chrome", origin: nil), from: id)
            bridge.handle(.hello(extensionVersion: "1.0.0", siteAccess: false, incognito: false), from: id)
        }
        XCTAssertEqual(bridge.tab(forBrowser: "com.google.Chrome"), ExtensionTab(url: nil, title: nil),
                       "connected but nothing reported: no address, and no AppleScript either")

        bridge.handle(.tab(BrowserTabReport(url: "https://github.com/pulls", title: "Pull requests")), from: work)
        bridge.handle(.tab(BrowserTabReport(url: "https://x.com/home", title: "Home / X")), from: home)
        // Switching to the home profile's window: the work profile loses focus.
        bridge.handle(.tab(nil), from: work)
        XCTAssertEqual(bridge.tab(forBrowser: "com.google.Chrome"), ExtensionTab(url: "https://x.com/home", title: "Home / X"))
        XCTAssertNil(bridge.tab(forBrowser: "company.thebrowser.Browser"))
        XCTAssertEqual(bridge.connectedBrowsers, ["com.google.Chrome"])
    }

    func test_switchingBackToTheBrowserKeepsItsLastPageForAMoment() {
        let now = Date()
        let report = BrowserTabReport(url: "https://github.com/pulls", title: "Pull requests")
        // Left for another app: the extension reported nil on the way out.
        let client = ExtensionBridge.Client(browser: "com.google.Chrome", greeted: true, tab: nil, tabAt: now.addingTimeInterval(-60),
                                            lastTab: report, lastTabAt: now.addingTimeInterval(-61))
        XCTAssertEqual(ExtensionBridge.pickTab(from: [client], browser: "com.google.Chrome", now: now,
                                               activatedAt: now.addingTimeInterval(-0.2)),
                       ExtensionTab(url: "https://github.com/pulls", title: "Pull requests"))
        // Still nothing well after the switch: a window the extension can't see.
        XCTAssertEqual(ExtensionBridge.pickTab(from: [client], browser: "com.google.Chrome", now: now,
                                               activatedAt: now.addingTimeInterval(-5)),
                       ExtensionTab(url: nil, title: nil))
    }

    private func connectedBridge(_ browser: String = "com.google.Chrome") -> (ExtensionBridge, BrowserSocketServer.ClientID) {
        let bridge = ExtensionBridge(socketPath: Self.temporarySocketPath())
        let id = BrowserSocketServer.ClientID(raw: 1)
        bridge.connected(id)
        bridge.handle(.helperHello(browser: browser, origin: nil), from: id)
        bridge.handle(.hello(extensionVersion: "1.0.0", siteAccess: false, incognito: false), from: id)
        return (bridge, id)
    }

    func test_pauseWaitsForTheExtensionsAnswer() throws {
        let (bridge, id) = connectedBridge()
        bridge.handle(.tab(BrowserTabReport(url: "https://www.x.com/home", title: "Home / X", tabId: 12)), from: id)
        // The block screen came up and took focus.
        bridge.handle(.tab(nil), from: id)

        var result: Bool?
        let rid = try XCTUnwrap(bridge.pauseFrontTab(browser: "com.google.Chrome", host: "x.com", fragment: "id=a") { result = $0 })
        XCTAssertNil(result, "nothing until the extension answers")
        bridge.handle(.pauseResult(requestId: rid, ok: true), from: id)
        XCTAssertEqual(result, true)
        bridge.handle(.pauseResult(requestId: rid, ok: false), from: id)
        XCTAssertEqual(result, true, "answered once")

        var other: Bool?
        XCTAssertNil(bridge.pauseFrontTab(browser: "com.brave.Browser", host: "x.com", fragment: "id=b") { other = $0 })
        XCTAssertEqual(other, false, "no extension in that browser")
    }

    func test_extensionPauserTakesOverWhereConnected() {
        let (bridge, _) = connectedBridge()
        let pauser = ExtensionTabPauser(bridge: bridge)
        XCTAssertTrue(pauser.canPause(browser: "com.google.Chrome"))
        XCTAssertFalse(pauser.canPause(browser: "com.apple.Safari"))

        let tab = PausedTab(id: "abc-1", browser: "com.google.Chrome", host: "x.com",
                            originalURL: URL(string: "https://x.com/home?a=1")!, reason: .session,
                            endsAt: Date(timeIntervalSince1970: 2_000), backTo: "Xcode")
        let page = PausedPage.url(base: URL(fileURLWithPath: "/A/FocusGuard.app/Contents/Resources/paused.html"),
                                  for: tab, state: .paused)
        let fragment = ExtensionTabPauser.fragment(of: page)
        XCTAssertEqual(fragment, "id=abc-1&host=x.com&url=https%3A%2F%2Fx.com%2Fhome%3Fa%3D1&state=paused&ends=2000&back=Xcode")
        XCTAssertEqual(PreferringTabPauser.pauseID(in: page), "abc-1")
        XCTAssertFalse(ExtensionTabPauser.isWebPage(page))
        XCTAssertTrue(ExtensionTabPauser.isWebPage(tab.originalURL))
    }

    func test_preferringPauserUsesTheExtensionThenFallsBack() {
        let primary = StubPauser(browsers: ["com.google.Chrome"])
        let fallback = StubPauser(browsers: ["com.google.Chrome", "com.apple.Safari"])
        let pauser = PreferringTabPauser(primary: primary, fallback: fallback)
        let page = URL(string: "file:///paused.html#id=one&host=x.com&state=paused")!

        XCTAssertTrue(pauser.canPause(browser: "com.apple.Safari"))
        XCTAssertFalse(pauser.canPause(browser: "org.mozilla.firefox"))
        pauser.pauseFrontTab(in: "com.google.Chrome", showing: "x.com", with: page) { _ in }
        pauser.pauseFrontTab(in: "com.apple.Safari", showing: "x.com", with: URL(string: "file:///paused.html#id=two&host=x.com")!) { _ in }
        XCTAssertEqual(primary.paused, ["x.com"])
        XCTAssertEqual(fallback.paused, ["x.com"])

        // Even if the extension went away, a tab goes back through whoever paused it.
        primary.browsers = []
        pauser.redirectTab(showing: "one", in: "com.google.Chrome", to: URL(string: "https://x.com/")!)
        pauser.redirectTab(showing: "two", in: "com.apple.Safari", to: URL(string: "https://x.com/")!)
        XCTAssertEqual(primary.redirected, ["one"])
        XCTAssertEqual(fallback.redirected, ["two"])
    }

    func test_pausedPageButtonsUseTheAppsRoutes() {
        XCTAssertEqual(ExtensionBridge.route(action: "back", pauseID: nil, minutes: nil), .back)
        XCTAssertEqual(ExtensionBridge.route(action: "reopenLater", pauseID: "abc-1", minutes: nil), .reopenLater(pauseID: "abc-1"))
        XCTAssertEqual(ExtensionBridge.route(action: "keepPaused", pauseID: "abc-1", minutes: nil), .keepPaused(pauseID: "abc-1"))
        XCTAssertEqual(ExtensionBridge.route(action: "startBreak", pauseID: nil, minutes: 10), .startBreak(minutes: 10))
        XCTAssertEqual(ExtensionBridge.route(action: "startBreak", pauseID: nil, minutes: 500), .startBreak(minutes: 60))
        XCTAssertNil(ExtensionBridge.route(action: "reopenLater", pauseID: "../etc", minutes: nil))
        XCTAssertNil(ExtensionBridge.route(action: "deleteEverything", pauseID: nil, minutes: nil))
    }

    func test_clientsWithoutHelloDontCount() {
        let clients = [ExtensionBridge.Client(browser: "com.brave.Browser", greeted: false,
                                              tab: BrowserTabReport(url: "https://x.com"), tabAt: .now)]
        XCTAssertNil(ExtensionBridge.pickTab(from: clients, browser: "com.brave.Browser"))
    }

    func test_hostsAndPagePatterns() {
        XCTAssertEqual(ExtensionBridge.displayHost("https://www.Medium.com/@ann/a"), "medium.com")
        XCTAssertNil(ExtensionBridge.displayHost("chrome://newtab"))
        XCTAssertEqual(ExtensionBridge.pagePattern("https://medium.com/@ann/a-post/?x=1#top"), "medium.com/@ann/a-post")
        XCTAssertNil(ExtensionBridge.pagePattern("https://medium.com/"))
        XCTAssertEqual(ExtensionBridge.mainTab(for: "reports"), .reports)
        XCTAssertEqual(ExtensionBridge.mainTab(for: "blocking"), .apps)
        XCTAssertEqual(ExtensionBridge.mainTab(for: nil), .home)
    }

    func test_barRunsTheTimelineTogether() {
        let timeline = SessionTimeline.build(
            segments: [.init(classification: .focus, seconds: 600), .init(classification: .distraction, seconds: 120),
                       .init(classification: .focus, seconds: 300)],
            elapsed: 1020, planned: 3000, current: .focus
        )
        let bar = ExtensionBridge.barSegments(timeline)
        XCTAssertEqual(bar.map(\.kind), ["f", "d", "f"])
        XCTAssertEqual(bar.map(\.seconds).reduce(0, +), (timeline.cells.filter { $0 != .future }.count) * 60)
        XCTAssertEqual(ExtensionBridge.totals([.init(classification: .focus, seconds: 600),
                                               .init(classification: .neutral, seconds: 60)]).focus, 600)
    }

    func test_blockedListComesFromDistractingSiteRules() {
        let rules = [
            AppRule(pattern: "www.x.com", matchKind: .host, classification: .distraction),
            AppRule(pattern: "reddit.com", matchKind: .host, classification: .distraction),
            AppRule(pattern: "youtube.com/shorts", matchKind: .urlPrefix, classification: .distraction),
            AppRule(pattern: "github.com", matchKind: .host, classification: .focus),
            AppRule(pattern: "com.valvesoftware.steam", matchKind: .bundleId, classification: .distraction),
        ]
        let list = ExtensionBridge.blockList(from: rules)
        XCTAssertEqual(list.sites, ["reddit.com", "x.com"])
        XCTAssertEqual(list.parts, ["youtube.com/shorts"])
    }

    func test_onlyTheClockMovingIsNotAHardChange() {
        var state = ExtensionState(
            app: .init(version: "1.0"), plan: .init(tier: "free", pro: false, trialDaysLeft: nil, features: Self.noFeatures),
            preset: "standard", policy: .standard,
            today: .init(focusSeconds: 60, goalMinutes: 240), phase: .focusing,
            session: .init(name: "S", startedAt: 0, endsAt: 3_000_000, plannedMinutes: 50, elapsedSeconds: 10, asOf: 10_000,
                           paused: false, segments: [.init(kind: "f", seconds: 60)],
                           focusSeconds: 10, driftSeconds: 0, otherSeconds: 0, stoppedVisits: 0, backTo: nil),
            blocking: .init(pauseTab: true, sites: [], parts: [], limits: [], passes: [], allowed: [], lockedUntil: nil)
        )
        let before = ExtensionBridge.hardPart(of: state)
        state.session?.elapsedSeconds = 70
        state.session?.asOf = 70_000
        state.today.focusSeconds = 120
        XCTAssertEqual(ExtensionBridge.hardPart(of: state), before)
        state.session?.paused = true
        XCTAssertNotEqual(ExtensionBridge.hardPart(of: state), before)
    }

    // MARK: - Socket and helper

    func test_socketServerExchangesFrames() async throws {
        let path = Self.temporarySocketPath()
        let server = BrowserSocketServer(path: path)
        let received = expectation(description: "server got the frame")
        var connectedID: BrowserSocketServer.ClientID?
        server.onConnect = { connectedID = $0 }
        server.onMessage = { id, data in
            XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"type":"hello"}"#)
            server.send(Data(#"{"type":"state"}"#.utf8), to: id)
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let fd = try Self.connect(to: path)
        defer { close(fd) }
        // A read that never gets its frame fails the test instead of hanging it.
        let watchdog = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); shutdown(fd, SHUT_RDWR) }
        defer { watchdog.cancel() }
        let frame = NativeMessageFraming.frame(Data(#"{"type":"hello"}"#.utf8))
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertNotNil(connectedID)

        let reply = try await Self.readFrame(from: fd)
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), #"{"type":"state"}"#)
    }

    /// Runs the real helper from the app bundle: it relays both ways while the
    /// app's socket is up, and answers for the app once it's gone.
    func test_helperRelaysToTheAppAndAnswersWhenItsGone() async throws {
        let path = Self.temporarySocketPath()
        let server = BrowserSocketServer(path: path)
        var fromHelper: [String] = []
        let greeted = expectation(description: "helper said hello, then relayed the extension's hello")
        server.onMessage = { id, data in
            let text = String(decoding: data, as: UTF8.self)
            fromHelper.append(text)
            if text.contains(#""type":"hello""#) {
                server.send(Data(#"{"type":"state","v":1}"#.utf8), to: id)
                greeted.fulfill()
            }
        }
        try server.start()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: NativeHostInstaller.bundledHelperPath())
        helper.arguments = ["chrome-extension://\(BrowserExtensionIDs.development)/"]
        helper.environment = [BrowserSocketLocation.overrideVariable: path]
        let input = Pipe(), output = Pipe()
        helper.standardInput = input
        helper.standardOutput = output
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        // Ending the helper closes its stdout, so a stuck read fails instead of hanging.
        let watchdog = Task { try? await Task.sleep(nanoseconds: 20_000_000_000); if helper.isRunning { helper.terminate() } }
        defer { watchdog.cancel() }
        let stdout = output.fileHandleForReading.fileDescriptor

        // It connects and tells the extension the app is running.
        let status = try await Self.readJSON(from: stdout)
        XCTAssertEqual(status["type"] as? String, "appStatus")
        XCTAssertEqual(status["running"] as? Bool, true)

        input.fileHandleForWriting.write(NativeMessageFraming.frame(Data(#"{"type":"hello","extensionVersion":"1.0.0"}"#.utf8)))
        await fulfillment(of: [greeted], timeout: 5)
        let helperHello = try XCTUnwrap(fromHelper.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(helperHello["type"] as? String, "helperHello")
        XCTAssertEqual(helperHello["origin"] as? String, "chrome-extension://\(BrowserExtensionIDs.development)/")

        let state = try await Self.readJSON(from: stdout)
        XCTAssertEqual(state["type"] as? String, "state")

        // The app quits.
        server.stop()
        let gone = try await Self.readJSON(from: stdout)
        XCTAssertEqual(gone["type"] as? String, "appStatus")
        XCTAssertEqual(gone["running"] as? Bool, false)

        input.fileHandleForWriting.write(NativeMessageFraming.frame(Data(#"{"type":"classify","id":"42","url":"https://x.com"}"#.utf8)))
        let refusal = try await Self.readJSON(from: stdout)
        XCTAssertEqual(refusal["type"] as? String, "reply")
        XCTAssertEqual(refusal["id"] as? String, "42")
        XCTAssertEqual(refusal["error"] as? String, "notRunning")

        // The browser closes the port: the helper exits.
        input.fileHandleForWriting.closeFile()
        for _ in 0..<50 where helper.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(helper.isRunning)
    }

    func test_planFollowsEntitlements() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BrowserExtensionTests.\(UUID().uuidString)"))
        let now = Date()
        let entitlements = Entitlements(defaults: defaults, now: { now })
        let free = ExtensionBridge.plan(from: entitlements, now: now)
        XCTAssertEqual(free.tier, "free")
        XCTAssertFalse(free.pro)
        XCTAssertEqual(free.features, Self.noFeatures)

        entitlements.startTrialIfNeeded(for: .blockInBrowser)
        let trial = ExtensionBridge.plan(from: entitlements, now: now)
        XCTAssertEqual(trial.tier, "trial")
        // 14 calendar days; across a clock change that's a part day more.
        XCTAssertTrue((14...15).contains(trial.trialDaysLeft ?? 0))
        XCTAssertEqual(trial.features, Self.allFeatures)
    }

    func test_statePolicyEncodesThePresetsRules() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OverridePolicy.strict)) as? [String: Any])
        XCTAssertEqual(json["allowsPass"] as? Bool, false)
        XCTAssertEqual(json["forWorkWaitSeconds"] as? Int, 10)
        XCTAssertEqual((json["extraTime"] as? [String: Any])?["timesPerDay"] as? Int, 0)
    }

    func test_visitsCountRunsOnTheSite() {
        let t = Date(timeIntervalSince1970: 1_000)
        let events: [(start: Date, url: String?)] = [
            (t, "https://www.reddit.com/r/swift"),
            (t + 60, "https://old.reddit.com/r/mac"),
            (t + 120, "https://github.com/"),
            (t + 180, nil),
            (t + 240, "https://reddit.com/"),
        ]
        let visits = ExtensionBridge.visits(to: "reddit.com", in: events)
        XCTAssertEqual(visits.count, 2)
        XCTAssertEqual(visits.last, t + 240)
        XCTAssertEqual(ExtensionBridge.visits(to: "x.com", in: events).count, 0)
    }

    // MARK: - Helpers

    final class StubPauser: TabPauser {
        var browsers: Set<String>
        var paused: [String] = []
        var redirected: [String] = []
        init(browsers: Set<String>) { self.browsers = browsers }
        func canPause(browser: String) -> Bool { browsers.contains(browser) }
        func pauseFrontTab(in browser: String, showing host: String, with page: URL,
                           completion: @escaping @MainActor (Bool) -> Void) {
            paused.append(host)
            completion(true)
        }
        func redirectTab(showing pauseID: String, in browser: String, to url: URL) { redirected.append(pauseID) }
    }

    static let allFeatures = ExtensionState.Features(blockInBrowser: true, partsOfSites: true,
                                                     youtubePerVideo: true, unlimitedLimits: true)
    static let noFeatures = ExtensionState.Features(blockInBrowser: false, partsOfSites: false,
                                                    youtubePerVideo: false, unlimitedLimits: false)

    static func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("extension/chrome/test/fixtures")
            .appendingPathComponent(name)
    }

    static func temporarySocketPath() -> String {
        "/tmp/fg-test-\(UUID().uuidString.prefix(8)).sock"
    }

    static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = BrowserSocketLocation.address(for: path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return fd
    }

    /// Reads one frame off a blocking descriptor, away from the main actor.
    nonisolated static func readFrame(from fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    if let frame = try? NativeMessageFraming.takeFrames(from: &buffer).first {
                        continuation.resume(returning: frame)
                        return
                    }
                    let n = read(fd, &chunk, chunk.count)
                    guard n > 0 else {
                        continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                        return
                    }
                    buffer.append(contentsOf: chunk[0..<n])
                }
            }
        }
    }

    /// One frame at a time: the helper writes each frame in one go, so a
    /// read never needs to hold more than the frame it's after.
    nonisolated static func readJSON(from fd: Int32) async throws -> [String: Any] {
        let header = try await readExactly(4, from: fd)
        let length = header.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let body = try await readExactly(length, from: fd)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    nonisolated static func readExactly(_ count: Int, from fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var out = Data()
                var chunk = [UInt8](repeating: 0, count: count)
                while out.count < count {
                    let n = read(fd, &chunk, count - out.count)
                    guard n > 0 else {
                        continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                        return
                    }
                    out.append(contentsOf: chunk[0..<n])
                }
                continuation.resume(returning: out)
            }
        }
    }
}

/// Part-of-a-site rules ("Only this page" in the extension's popup).
@MainActor
final class URLPrefixRuleTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var classifier: Classifier!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
        classifier = Classifier(context: context)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        classifier = nil
        try await super.tearDown()
    }

    func test_prefixMatchesWholeSegmentsOnTheSiteAndItsSubdomains() {
        XCTAssertTrue(Classifier.url("https://www.youtube.com/shorts/abc", matchesPrefix: "youtube.com/shorts"))
        XCTAssertTrue(Classifier.url("https://m.youtube.com/shorts", matchesPrefix: "youtube.com/shorts/"))
        XCTAssertTrue(Classifier.url("https://youtube.com/Shorts?x=1", matchesPrefix: "youtube.com/shorts"))
        XCTAssertFalse(Classifier.url("https://youtube.com/shortsale", matchesPrefix: "youtube.com/shorts"))
        XCTAssertFalse(Classifier.url("https://notyoutube.com/shorts", matchesPrefix: "youtube.com/shorts"))
        XCTAssertTrue(Classifier.url("https://reddit.com/r/swift", matchesPrefix: "reddit.com"))
    }

    func test_pageOverrideBeatsItsSiteAndReclassifiesPastTime() throws {
        let article = ActivityEvent(startedAt: .now.addingTimeInterval(-60), endedAt: .now, bundleIdentifier: "com.google.Chrome",
                                    appName: "Chrome", windowTitle: nil, url: "https://medium.com/@ann/a-post?source=feed")
        let other = ActivityEvent(startedAt: .now.addingTimeInterval(-60), endedAt: .now, bundleIdentifier: "com.google.Chrome",
                                  appName: "Chrome", windowTitle: nil, url: "https://medium.com/@bob/other")
        context.insert(article)
        context.insert(other)
        classifier.setOverride(host: "medium.com", classification: .distraction)
        classifier.setOverride(urlPrefix: "medium.com/@ann/a-post", classification: .focus)

        XCTAssertEqual(classifier.classify(bundleId: "com.google.Chrome", windowTitle: nil,
                                           url: "https://medium.com/@ann/a-post"), .focus)
        XCTAssertEqual(classifier.classify(bundleId: "com.google.Chrome", windowTitle: nil,
                                           url: "https://medium.com/@bob/other"), .distraction)
        XCTAssertEqual(classifier.matchingRule(bundleId: "com.google.Chrome", windowTitle: nil,
                                               url: "https://medium.com/@ann/a-post")?.matchKind, .urlPrefix)
        XCTAssertEqual(article.classification, .focus)
        XCTAssertEqual(other.classification, .distraction)
    }
}
