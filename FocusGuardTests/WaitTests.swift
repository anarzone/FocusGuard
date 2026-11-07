import XCTest
@testable import FocusGuard

/// Waits on a tool: which tools and projects are recognised, when a wait
/// starts, what it turns into, and what the card says. Nothing here reaches
/// a real app.
@MainActor
final class WaitTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let terminal = "com.apple.Terminal"
    private let chrome = "com.google.Chrome"

    private func snap(_ bundleId: String, title: String? = nil, url: String? = nil,
                      _ classification: Classification = .neutral, private isPrivate: Bool = false,
                      at seconds: TimeInterval = 0) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleId, appName: bundleId.components(separatedBy: ".").last ?? bundleId,
                         windowTitle: title, url: url, classification: classification,
                         observedAt: now.addingTimeInterval(seconds), isPrivateWindow: isPrivate)
    }

    private var codex: ActivitySnapshot { snap(terminal, title: "~/Projects/curiplay — codex — 120×40") }
    private func x(at seconds: TimeInterval) -> ActivitySnapshot {
        snap(chrome, url: "https://x.com/home", .distraction, at: seconds)
    }
    private func notes(at seconds: TimeInterval) -> ActivitySnapshot {
        snap("com.apple.Notes", title: "Ideas", at: seconds)
    }

    private func look(_ watcher: inout WaitWatcher, _ front: ActivitySnapshot?, at seconds: TimeInterval,
                      usual: TimeInterval = 90, away: Bool = false) -> [WaitEvent] {
        watcher.observe(WaitMoment(now: now.addingTimeInterval(seconds), front: front, isAway: away),
                        usualWait: { _ in usual })
    }

    // MARK: - Tools

    func testAgentsInATerminalAreKnownByTheirTitle() {
        let tool = WaitTools.tool(for: codex)
        XCTAssertEqual(tool?.name, "Codex")
        XCTAssertEqual(tool?.kind, .agent)
        XCTAssertEqual(tool.flatMap { WaitTools.project(for: codex, tool: $0) }, "curiplay")
        XCTAssertEqual(WaitTools.tool(for: snap(terminal, title: "✳ Tray for the cups"))?.name, "Claude Code")
        XCTAssertEqual(WaitTools.tool(for: snap("com.googlecode.iterm2", title: "gemini (~/work/api)"))?.name, "Gemini CLI")
    }

    func testARunningCommandCountsButAShellAloneDoesNot() {
        XCTAssertNil(WaitTools.tool(for: snap(terminal, title: "curiplay — -zsh — 80×24")))
        let script = WaitTools.tool(for: snap(terminal, title: "~/Projects/curiplay — python3 — 80×24"))
        XCTAssertEqual(script?.kind, .command)
        XCTAssertNil(WaitTools.tool(for: snap(terminal, title: "Terminal")), "No process in the title: can't tell")
    }

    func testChatsAreKnownBySiteOrApp() {
        let chat = WaitTools.tool(for: snap(chrome, url: "https://openrouter.ai/chat?room=1"))
        XCTAssertEqual(chat, WaitTool(name: "OpenRouter", kind: .chat, bundleId: chrome, host: "openrouter.ai"))
        XCTAssertEqual(WaitTools.tool(for: snap(chrome, url: "https://www.chatgpt.com/c/1"))?.name, "ChatGPT")
        XCTAssertEqual(WaitTools.tool(for: snap("com.openai.chat"))?.name, "ChatGPT")
        XCTAssertNil(WaitTools.tool(for: snap(chrome, url: "https://openrouter.ai/chat", private: true)), "A private window says nothing")
        XCTAssertNil(WaitTools.tool(for: snap(chrome, url: "https://news.ycombinator.com")))
    }

    func testEditorsNameTheirProject() {
        let cursor = snap("com.todesktop.230313mzl4w4u92", title: "tray.js — curiplay")
        XCTAssertEqual(WaitTools.tool(for: cursor).flatMap { WaitTools.project(for: cursor, tool: $0) }, "curiplay")
        let xcode = snap("com.apple.dt.Xcode", title: "FocusGuard — AppState.swift")
        XCTAssertEqual(WaitTools.tool(for: xcode).flatMap { WaitTools.project(for: xcode, tool: $0) }, "FocusGuard")
        XCTAssertNil(WaitTools.tool(for: snap("com.apple.Notes", title: "Ideas")))
    }

    // MARK: - Watching

    func testReachingForADistractionMidWaitIsNoticedOnceWithItsProject() {
        var watcher = WaitWatcher()
        XCTAssertEqual(look(&watcher, codex, at: 0), [])
        let events = look(&watcher, x(at: 10), at: 10)
        guard case .reached(let reach)? = events.first else { return XCTFail("Expected a reach, got \(events)") }
        XCTAssertEqual(reach.tool.name, "Codex")
        XCTAssertEqual(reach.project, "curiplay")
        XCTAssertEqual(reach.to, "x.com")
        XCTAssertEqual(reach.since, now.addingTimeInterval(10))
        XCTAssertEqual(look(&watcher, x(at: 10), at: 20), [], "Once per wait")
        XCTAssertTrue(watcher.isWaiting)
    }

    func testComingBackEndsTheWaitWithHowLongItDrifted() {
        var watcher = WaitWatcher()
        _ = look(&watcher, codex, at: 0)
        _ = look(&watcher, x(at: 10), at: 10)
        let events = look(&watcher, codex, at: 70)
        guard case .ended(let record, let back)? = events.first else { return XCTFail("Expected an end, got \(events)") }
        XCTAssertTrue(back)
        XCTAssertEqual(record.tool, "Codex")
        XCTAssertEqual(record.project, "curiplay")
        XCTAssertEqual(record.seconds, 60, accuracy: 0.5)
        XCTAssertEqual(record.drift, 60, accuracy: 0.5)
        XCTAssertEqual(record.to, "x.com")
        XCTAssertFalse(watcher.isWaiting)
    }

    func testAWaitSpentElsewhereIsAStayedWait() {
        var watcher = WaitWatcher()
        _ = look(&watcher, codex, at: 0)
        XCTAssertEqual(look(&watcher, notes(at: 10), at: 10), [], "Not a distraction: no card")
        let events = look(&watcher, codex, at: 50)
        guard case .ended(let record, true)? = events.first else { return XCTFail("Expected an end, got \(events)") }
        XCTAssertEqual(record.drift, 0)
        XCTAssertFalse(record.drifted)
    }

    func testPassingThroughATool_OrAQuickLook_IsNotAWait() {
        var watcher = WaitWatcher()
        _ = look(&watcher, codex, at: 0)
        XCTAssertEqual(look(&watcher, x(at: 3), at: 3), [], "Three seconds in the tool isn't handing it work")
        XCTAssertFalse(watcher.isWaiting)

        var other = WaitWatcher()
        _ = look(&other, codex, at: 0)
        _ = look(&other, notes(at: 10), at: 10)
        XCTAssertEqual(look(&other, codex, at: 15), [], "Five seconds away is a look, not a wait")
    }

    func testStillAwayWhenTheUsualWaitIsUpSaysItsProbablyDoneOnce() {
        var watcher = WaitWatcher()
        _ = look(&watcher, codex, at: 0)
        _ = look(&watcher, x(at: 10), at: 10)
        XCTAssertEqual(look(&watcher, x(at: 10), at: 60, usual: 90), [])
        let events = look(&watcher, x(at: 10), at: 101, usual: 90)
        guard case .probablyDone(let reach, _)? = events.first else { return XCTFail("Expected done, got \(events)") }
        XCTAssertEqual(reach.tool.name, "Codex")
        XCTAssertEqual(look(&watcher, x(at: 10), at: 130, usual: 90), [])
    }

    func testADistractionLongAfterLeavingIsNoReachButStillCounts() {
        var watcher = WaitWatcher()
        _ = look(&watcher, codex, at: 0)
        _ = look(&watcher, notes(at: 10), at: 10)
        XCTAssertEqual(look(&watcher, x(at: 200), at: 200), [], "Too long after leaving to be reaching for it in the wait")
        let events = look(&watcher, codex, at: 260)
        guard case .ended(let record, true)? = events.first else { return XCTFail("Expected an end, got \(events)") }
        XCTAssertEqual(record.drift, 60, accuracy: 0.5)
    }

    func testGoingAwayEndsAWaitThatDrifted() {
        var watcher = WaitWatcher()
        _ = look(&watcher, codex, at: 0)
        _ = look(&watcher, x(at: 10), at: 10)
        let events = look(&watcher, nil, at: 300, away: true)
        guard case .ended(let record, false)? = events.first else { return XCTFail("Expected an end, got \(events)") }
        XCTAssertEqual(record.drift, 290, accuracy: 0.5)
        XCTAssertFalse(watcher.isWaiting)
    }

    func testAChatTakesTheProjectLastSeen() {
        var watcher = WaitWatcher()
        _ = look(&watcher, codex, at: 0)
        _ = look(&watcher, snap(chrome, url: "https://openrouter.ai/chat"), at: 20)
        let events = look(&watcher, x(at: 40), at: 40)
        guard case .reached(let reach)? = events.first else { return XCTFail("Expected a reach, got \(events)") }
        XCTAssertEqual(reach.tool.name, "OpenRouter")
        XCTAssertEqual(reach.project, "curiplay")
    }

    // MARK: - Log

    func testAToolsUsualWaitIsTheMedianOfWaitsStayedWith() {
        let log = WaitLog(url: nil, now: { self.now })
        XCTAssertEqual(log.usualWait(for: "Codex"), WaitRules.usualWait, "Too few of its own yet")
        for seconds in [60.0, 120, 100] {
            log.add(WaitRecord(start: now, tool: "Codex", seconds: seconds, drift: 0))
        }
        log.add(WaitRecord(start: now, tool: "Codex", seconds: 900, drift: 840, to: "x.com"))
        XCTAssertEqual(log.usualWait(for: "Codex"), 100, "A drift says how long the drift was, not the tool")
        XCTAssertEqual(log.lastDrift(for: "Codex")?.to, "x.com")
        XCTAssertEqual(log.driftShare(for: "Codex").drifted, 1)
        XCTAssertEqual(log.driftShare(for: "Codex").of, 4)
    }

    func testOldWaitsAreDropped() {
        let log = WaitLog(url: nil, now: { self.now })
        log.add(WaitRecord(start: now.addingTimeInterval(-100 * 86_400), tool: "Codex", seconds: 60, drift: 0))
        log.add(WaitRecord(start: now, tool: "Codex", seconds: 60, drift: 0))
        XCTAssertEqual(log.records.count, 1)
    }

    // MARK: - Card

    func testTheCardOffersTheProjectsNextTaskAndTheWayBack() {
        let tool = WaitTool(name: "Codex", kind: .agent, bundleId: terminal)
        let reach = WaitReach(tool: tool, project: "Curiplay", since: now, to: "x.com")
        let task = TaskItem(source: .linear, id: "1", title: "CUR-38 Waiter wipes the table", list: "Curiplay", due: nil, created: nil)
        let card = IslandMoment.waitReach(reach, usual: 90, next: task, lastDrift: nil, now: now.addingTimeInterval(30))
        XCTAssertEqual(card.kind, .wait)
        XCTAssertTrue(card.startsOpen)
        XCTAssertTrue(card.body.contains("CUR-38"))
        XCTAssertEqual(card.buttons.first?.command, .backTo(bundleId: terminal, host: nil))
        XCTAssertNil(card.buttons.last?.command, "Opening it anyway only closes the card")
        XCTAssertEqual(card.countdown?.secondsLeft(at: now.addingTimeInterval(30)), 60)

        let done = IslandMoment.waitDone(reach, now: now.addingTimeInterval(200))
        XCTAssertEqual(done.key, card.key, "The done card takes the reach card's place")
        XCTAssertTrue(done.title.contains("Codex"))
    }

    func testWithNoTaskTheCardRemindsWhatTheLastDriftCost() {
        let tool = WaitTool(name: "OpenRouter", kind: .chat, bundleId: chrome, host: "openrouter.ai")
        let reach = WaitReach(tool: tool, project: nil, since: now, to: "youtube.com")
        let last = WaitRecord(start: now, tool: "OpenRouter", seconds: 600, drift: 540, to: "youtube.com")
        let card = IslandMoment.waitReach(reach, usual: 40, next: nil, lastDrift: last, now: now)
        XCTAssertTrue(card.body.contains("9"))
        XCTAssertEqual(card.buttons.first?.command, .backTo(bundleId: chrome, host: "openrouter.ai"))
    }
}

/// Tools that say when they start and finish: the links, the watcher, and the
/// connectors' changes to the tools' settings, in a folder made for the test.
@MainActor
final class WaitConnectorTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wait-connectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var files: WaitConnectorFiles { WaitConnectorFiles(home: home) }

    // MARK: - Links

    func testWaitLinksCarryTheToolAndTheFolderOnly() {
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://wait/start?tool=Claude%20Code&project=curiplay")!),
                       .wait(started: true, tool: "Claude Code", project: "curiplay"))
        XCTAssertEqual(FocusGuardURL(URL(string: "focusguard://wait/done?tool=Codex&project=")!),
                       .wait(started: false, tool: "Codex", project: nil))
        XCTAssertNil(FocusGuardURL(URL(string: "focusguard://wait/start")!), "No tool, no wait")
        let route = FocusGuardURL.wait(started: false, tool: "Codex", project: "my app")
        XCTAssertEqual(FocusGuardURL(route.url), route)
    }

    // MARK: - Watcher

    private let terminal = "com.apple.Terminal"

    private func front(_ title: String) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: terminal, appName: "Terminal", windowTitle: title, url: nil,
                         classification: .neutral, observedAt: now)
    }

    private func x(at seconds: TimeInterval) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: "com.google.Chrome", appName: "Chrome", windowTitle: nil, url: "https://x.com",
                         classification: .distraction, observedAt: now.addingTimeInterval(seconds))
    }

    private func look(_ watcher: inout WaitWatcher, _ front: ActivitySnapshot, at seconds: TimeInterval) -> [WaitEvent] {
        watcher.observe(WaitMoment(now: now.addingTimeInterval(seconds), front: front), usualWait: { _ in 90 })
    }

    func testAStartFromTheToolMakesAnyTerminalItsHome() {
        var watcher = WaitWatcher()
        let plain = front("Some window")
        XCTAssertNil(WaitTools.tool(for: plain), "Nothing in the title says what runs there")
        watcher.started(tool: "Claude Code", project: "curiplay", front: plain, at: now)
        _ = look(&watcher, plain, at: 1)
        let events = look(&watcher, x(at: 2), at: 2)
        guard case .reached(let reach)? = events.first else { return XCTFail("Expected a reach, got \(events)") }
        XCTAssertEqual(reach.tool.name, "Claude Code")
        XCTAssertEqual(reach.project, "curiplay")
    }

    func testAToolThatSaysWhenItsDoneIsNeverGuessedAt() {
        var watcher = WaitWatcher()
        let plain = front("Some window")
        watcher.started(tool: "Claude Code", project: nil, front: plain, at: now)
        _ = look(&watcher, x(at: 2), at: 2)
        XCTAssertEqual(look(&watcher, x(at: 2), at: 200), [], "No guess past the usual wait")
        let events = watcher.finished(tool: "Claude Code", at: now.addingTimeInterval(210))
        guard case .probablyDone(_, let exact)? = events.first else { return XCTFail("Expected done, got \(events)") }
        XCTAssertTrue(exact)
        let back = look(&watcher, plain, at: 260)
        guard case .ended(let record, true)? = back.first else { return XCTFail("Expected an end, got \(back)") }
        XCTAssertTrue(record.exact)
        XCTAssertEqual(record.worked ?? 0, 210, accuracy: 0.5)
    }

    func testAFinishWhileStillAtTheToolSaysNothing() {
        var watcher = WaitWatcher()
        let codex = front("~/Projects/curiplay — codex")
        _ = look(&watcher, codex, at: 0)
        XCTAssertEqual(watcher.finished(tool: "Codex", at: now.addingTimeInterval(30)), [])
    }

    // MARK: - Claude Code

    func testClaudeCodeGetsTwoHooksBesideTheUsersOwnAndLosesOnlyThose() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8).write(to: settings)
        XCTAssertEqual(files.state(.claudeCode), .notConnected)

        try files.connect(.claudeCode)
        XCTAssertEqual(files.state(.claudeCode), .connected)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "opus")
        let hooks = json?["hooks"] as? [String: Any]
        XCTAssertEqual((hooks?["Stop"] as? [Any])?.count, 2, "The user's own hook stays")
        let start = ((hooks?["UserPromptSubmit"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertTrue(start?.contains("focusguard://wait/start?tool=Claude%20Code") ?? false)
        XCTAssertTrue(start?.contains("$CLAUDE_PROJECT_DIR") ?? false)

        try files.connect(.claudeCode)
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        XCTAssertEqual(((json?["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 2, "Connecting twice adds nothing")

        try files.disconnect(.claudeCode)
        XCTAssertEqual(files.state(.claudeCode), .notConnected)
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        let left = json?["hooks"] as? [String: Any]
        XCTAssertNil(left?["UserPromptSubmit"])
        XCTAssertEqual((left?["Stop"] as? [Any])?.count, 1)
    }

    func testClaudeCodesSettingsThatArentJSONAreLeftAlone() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: settings)
        XCTAssertThrowsError(try files.connect(.claudeCode))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ not json")
    }

    func testAToolThatIsntHereCantBeConnected() {
        XCTAssertEqual(files.state(.claudeCode), .notInstalled)
        XCTAssertEqual(files.state(.codex), .notInstalled)
    }

    // MARK: - Codex

    func testCodexGetsANotifyLineAtTheTopAndLosesIt() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "model = \"gpt-5\"\n\n[profiles.fast]\nmodel = \"mini\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)

        try files.connect(.codex)
        XCTAssertEqual(files.state(.codex), .connected)
        let text = try String(contentsOf: config, encoding: .utf8)
        let notify = text.components(separatedBy: "\n").first { $0.hasPrefix("notify") }
        XCTAssertNotNil(notify)
        XCTAssertLessThan(text.range(of: "notify")!.lowerBound, text.range(of: "[profiles")!.lowerBound, "Before the first table")
        XCTAssertEqual(notify?.filter { $0 == "'" }.count, 2, "The command fits in one literal TOML string")

        try files.disconnect(.codex)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    func testCodexsOwnNotifyIsNeverReplaced() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "notify = [\"python3\", \"mine.py\"]\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(files.state(.codex), .hasOwnNotify)
        XCTAssertThrowsError(try files.connect(.codex))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "notify = [\"python3\", \"mine.py\"]\n")
    }

    func testANotifyInsideATableIsntCodexsOwn() {
        XCTAssertFalse(WaitConnectorFiles.topLevelNotify(in: "[tui]\nnotify = true\n"))
        XCTAssertTrue(WaitConnectorFiles.topLevelNotify(in: "model = \"x\"\nnotify=[\"a\"]\n"))
    }
}
