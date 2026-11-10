import XCTest
@testable import FocusGuard

/// How long each tool really works: every run it starts and finishes by its
/// own word is timed, per project and per session, and the card's "how much
/// longer" comes from those times. Nothing here reaches a real app.
@MainActor
final class WaitRunTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let terminal = "com.apple.Terminal"
    private let chrome = "com.google.Chrome"
    private let claudeCode = "Claude Code"

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    private func snap(_ bundleId: String, title: String? = nil, url: String? = nil,
                      _ classification: Classification = .neutral, at seconds: TimeInterval = 0) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleId, appName: bundleId.components(separatedBy: ".").last ?? bundleId,
                         windowTitle: title, url: url, classification: classification, observedAt: at(seconds))
    }

    private var term: ActivitySnapshot { snap(terminal, title: "Some window") }
    private func x(at seconds: TimeInterval) -> ActivitySnapshot {
        snap(chrome, url: "https://x.com/home", .distraction, at: seconds)
    }

    private func look(_ watcher: inout WaitWatcher, _ front: ActivitySnapshot, at seconds: TimeInterval) -> [WaitEvent] {
        watcher.observe(WaitMoment(now: at(seconds), front: front))
    }

    private func runs(in events: [WaitEvent]) -> [RunRecord] {
        events.compactMap { if case .ran(let run) = $0 { return run } else { return nil } }
    }

    private func reach(in events: [WaitEvent]) -> WaitReach? {
        for case .reached(let reach) in events { return reach }
        return nil
    }

    private func done(in events: [WaitEvent]) -> (project: String?, needsInput: Bool)? {
        for case .done(_, let project, let needsInput) in events { return (project, needsInput) }
        return nil
    }

    // MARK: - Timing runs

    func testEveryRunIsTimedWaitedOnOrNot() {
        var watcher = WaitWatcher()
        XCTAssertTrue(watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now))
        // The user never leaves the terminal: no wait, and still a time.
        let events = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(140))
        XCTAssertEqual(events, [.ran(RunRecord(start: now, tool: claudeCode, project: "curiplay", seconds: 140))])
        XCTAssertEqual(watcher.runCount, 0)
        XCTAssertEqual(watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(150)), [],
                       "Said twice: nothing new")
    }

    func testARunThatStopsToAskIsTimedUpToTheQuestion() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        let asked = runs(in: watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: true, at: at(50)))
        XCTAssertEqual(asked.map(\.seconds), [50])
        XCTAssertEqual(asked.map(\.asked), [true])
        // Its answer isn't a prompt: when it stops for good, there's no start to time from.
        XCTAssertEqual(watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(300)), [])
    }

    func testTwoSessionsInOneFolderAreTimedApart() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        watcher.started(tool: claudeCode, project: "curiplay", session: "b", front: term, at: at(20))
        XCTAssertEqual(watcher.runCount, 2, "The second doesn't overwrite the first")
        let first = runs(in: watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(100)))
        XCTAssertEqual(first.map(\.seconds), [100])
        let second = runs(in: watcher.finished(tool: claudeCode, project: "curiplay", session: "b", needsInput: false, at: at(300)))
        XCTAssertEqual(second.map(\.seconds), [280])
    }

    func testTheWaitIsOnTheSessionAskedLast() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        watcher.started(tool: claudeCode, project: "curiplay", session: "b", front: term, at: at(20))
        guard let reached = reach(in: look(&watcher, x(at: 30), at: 30)) else { return XCTFail("Expected a reach") }
        XCTAssertEqual(reached.runStarted, at(20), "How long it has worked is counted from its own start")
        let other = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(60))
        XCTAssertNil(done(in: other), "The other session finishing doesn't end this wait")
        XCTAssertEqual(runs(in: other).count, 1, "But it's timed")
        let mine = watcher.finished(tool: claudeCode, project: "curiplay", session: "b", needsInput: false, at: at(90))
        XCTAssertNotNil(done(in: mine))
        guard case .ended(let record, true)? = look(&watcher, term, at: 120).first else { return XCTFail("Expected an end") }
        XCTAssertEqual(record.worked ?? 0, 70, accuracy: 0.5, "From session b's start to its finish")
    }

    func testAnotherSessionAskingInTheSameAppIsWorthGoingBackFor() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "lexis-app", session: "a", front: term, at: now)
        watcher.started(tool: claudeCode, project: "curiplay", session: "b", front: term, at: at(20))
        _ = look(&watcher, x(at: 30), at: 30)
        let asks = watcher.finished(tool: claudeCode, project: "lexis-app", session: "a", needsInput: true, at: at(60))
        XCTAssertEqual(done(in: asks)?.project, "lexis-app")
        XCTAssertEqual(done(in: asks)?.needsInput, true)
        XCTAssertTrue(watcher.isWaiting, "Session b is still working")
    }

    func testALateFinishIsStillTimedButNoLongerWaitedOn() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        // Forty minutes with no word: longer than it's believed for.
        _ = look(&watcher, term, at: 40 * 60)
        XCTAssertEqual(look(&watcher, x(at: 40 * 60 + 10), at: 40 * 60 + 10), [])
        XCTAssertFalse(watcher.isWaiting)
        let late = runs(in: watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(45 * 60)))
        XCTAssertEqual(late.map(\.seconds), [45 * 60], "It did work that long, and now that's known")

        // A tool whose runs here have gone on for an hour is believed for longer.
        var patient = WaitWatcher()
        patient.started(tool: claudeCode, project: "curiplay", session: "a", front: term, believeFor: 90 * 60, at: now)
        _ = look(&patient, term, at: 40 * 60)
        XCTAssertNotNil(reach(in: look(&patient, x(at: 40 * 60 + 10), at: 40 * 60 + 10)))
    }

    // MARK: - Which run a wait was on, and how long its answer sat

    private func ended(in events: [WaitEvent]) -> WaitRecord? {
        for case .ended(let record, _) in events { return record }
        return nil
    }

    func testAWaitRemembersItsRunAndHowLongTheAnswerSat() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        _ = look(&watcher, x(at: 30), at: 30)
        _ = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(100))
        guard let record = ended(in: look(&watcher, term, at: 400)) else { return XCTFail("Expected an end") }
        XCTAssertEqual(record.ran, now, "The run it was on, by its start")
        XCTAssertEqual(record.drift, 370, accuracy: 0.5)
        XCTAssertEqual(record.late ?? -1, 300, accuracy: 0.5, "On x.com for five minutes after it had finished")
    }

    func testOnlyTimeOnADistractionAfterTheFinishIsLate() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        _ = look(&watcher, x(at: 30), at: 30)
        _ = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(100))
        // Off x.com half a minute later, and reading the docs for a while.
        _ = look(&watcher, snap(chrome, url: "https://docs.swift.org/", at: 130), at: 130)
        guard let record = ended(in: look(&watcher, term, at: 400)) else { return XCTFail("Expected an end") }
        XCTAssertEqual(record.drift, 100, accuracy: 0.5)
        XCTAssertEqual(record.late ?? -1, 30, accuracy: 0.5, "The docs aren't a distraction: that time isn't the drift's")
    }

    func testBackBeforeItFinishesLeavesNothingLate() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        _ = look(&watcher, x(at: 30), at: 30)
        guard let record = ended(in: look(&watcher, term, at: 60)) else { return XCTFail("Expected an end") }
        XCTAssertEqual(record.ran, now)
        XCTAssertNil(record.late, "It hadn't finished: nothing sat")
        XCTAssertTrue(record.drifted)
    }

    func testGoingIdleLeavesNoRunAndNothingLate() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        _ = look(&watcher, x(at: 30), at: 30)
        _ = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, quiet: true, at: at(100))
        guard let record = ended(in: look(&watcher, term, at: 400)) else { return XCTFail("Expected an end") }
        XCTAssertNil(record.ran, "When it stopped working isn't known")
        XCTAssertNil(record.late)
    }

    func testTheDoneCardComesHoweverLateTheDriftBegan() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        // The docs first, and x.com only minutes later: too late to be reaching for it in the wait.
        _ = look(&watcher, snap(chrome, url: "https://docs.swift.org/", at: 10), at: 10)
        XCTAssertNil(reach(in: look(&watcher, x(at: 200), at: 200)))
        let events = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(260))
        var told: WaitReach?
        for case .done(let reach, _, _) in events { told = reach }
        XCTAssertEqual(told?.to, "x.com", "On a distraction when it finished: said, whenever the drift began")
        XCTAssertEqual(told?.since, at(200), "Its minutes are the ones on x.com")
        XCTAssertEqual(watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(270)), [],
                       "Said once")
    }

    func testAStartIsForgottenAfterHalfADay() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        _ = look(&watcher, term, at: 13 * 3600)
        XCTAssertEqual(watcher.runCount, 0)
        XCTAssertEqual(watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(13 * 3600 + 5)), [])
    }

    func testARunTheMacSleptThroughIsntTimed() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, uptime: 1_000, at: now)
        // An hour on the clock, a hundred seconds awake.
        let slept = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, uptime: 1_100, at: at(3_700))
        XCTAssertEqual(slept, [])
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, uptime: 1_100, at: at(4_000))
        let awake = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, uptime: 1_400, at: at(4_300))
        XCTAssertEqual(runs(in: awake).map(\.seconds), [300])
    }

    func testGoingIdleEndsTheRunWithNothingTimedAndNothingSaid() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        XCTAssertNotNil(reach(in: look(&watcher, x(at: 10), at: 10)))
        // Interrupted, then idle: Claude Code says so a minute later.
        XCTAssertEqual(watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, quiet: true, at: at(100)), [])
        XCTAssertEqual(watcher.runCount, 0)
        guard case .ended(let record, true)? = look(&watcher, term, at: 130).first else { return XCTFail("Expected an end") }
        XCTAssertNil(record.worked, "When it stopped working isn't known")
        _ = look(&watcher, term, at: 140)
        XCTAssertEqual(look(&watcher, x(at: 150), at: 150), [], "Nothing's running any more: no wait")
    }

    // MARK: - Where a tool lives

    func testOnlyAPlaceAToolCanRunInBecomesItsHome() {
        XCTAssertTrue(WaitWatcher.canHost(snap(terminal, title: "zsh"), tool: claudeCode, project: nil))
        XCTAssertTrue(WaitWatcher.canHost(snap("com.jetbrains.intellij", title: "Main.kt"), tool: claudeCode, project: nil))
        XCTAssertTrue(WaitWatcher.canHost(snap("com.example.ide", title: "curiplay — main.swift"), tool: claudeCode, project: "curiplay"),
                      "Its title names the project")
        XCTAssertTrue(WaitWatcher.canHost(snap("com.example.term", title: "✳ Fix the waiter"), tool: claudeCode, project: nil),
                      "Its title is Claude Code's")
        XCTAssertFalse(WaitWatcher.canHost(snap("com.apple.finder", title: "Downloads"), tool: claudeCode, project: "curiplay"))
        XCTAssertFalse(WaitWatcher.canHost(snap(chrome, title: "curiplay", url: "https://github.com/me/curiplay"), tool: claudeCode,
                                           project: "curiplay"), "A browser is never where it runs")
        XCTAssertFalse(WaitWatcher.canHost(snap("com.example.game", title: "curiplay", .distraction), tool: claudeCode, project: "curiplay"))
    }

    func testAPromptSentWithABrowserInFrontHasNoHomeButIsStillTimed() {
        var watcher = WaitWatcher()
        // Queued earlier, or sent from a phone: x.com happens to be in front.
        XCTAssertFalse(watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: x(at: 0), at: now))
        XCTAssertTrue(watcher.hooked.isEmpty, "x.com isn't where Claude Code lives")
        XCTAssertEqual(look(&watcher, x(at: 5), at: 5), [])
        XCTAssertEqual(look(&watcher, snap("com.apple.Notes", title: "Ideas"), at: 20), [])
        XCTAssertEqual(look(&watcher, x(at: 40), at: 40), [])
        XCTAssertFalse(watcher.isWaiting, "Leaving the browser for another tab is no wait on Claude Code")
        let timed = runs(in: watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(120)))
        XCTAssertEqual(timed.map(\.seconds), [120])
    }

    func testAKnownSessionKeepsItsHomeWhateverIsInFront() {
        var watcher = WaitWatcher()
        watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: term, at: now)
        _ = watcher.finished(tool: claudeCode, project: "curiplay", session: "a", needsInput: false, at: at(30))
        // Its next prompt goes out while the user is elsewhere.
        XCTAssertTrue(watcher.started(tool: claudeCode, project: "curiplay", session: "a", front: x(at: 40), at: at(40)))
        XCTAssertEqual(watcher.hooked, [terminal])
        _ = look(&watcher, term, at: 50)
        guard let reached = reach(in: look(&watcher, x(at: 60), at: 60)) else { return XCTFail("Expected a reach") }
        XCTAssertEqual(reached.tool.bundleId, terminal, "Back is still the terminal")
    }

    // MARK: - How much longer

    func testHowMuchLongerComesFromTheRunsThatGotThisFar() {
        let log = WaitLog(url: nil, now: { self.now })
        XCTAssertEqual(log.estimate(tool: claudeCode, project: "curiplay", elapsed: 10), .unknown, "No runs: no number")
        for seconds in [60.0, 120, 180, 240, 600] {
            log.add(RunRecord(start: now, tool: claudeCode, project: "curiplay", seconds: seconds))
        }
        XCTAssertEqual(log.estimate(tool: claudeCode, project: "curiplay", elapsed: 30), .left(150), "All five got this far")
        XCTAssertEqual(log.estimate(tool: claudeCode, project: "curiplay", elapsed: 200), .left(220),
                       "Two went on past 200 s: 40 and 400 more")
        XCTAssertEqual(log.estimate(tool: claudeCode, project: "curiplay", elapsed: 300), .overdue(worked: 300),
                       "Four in five were done by now")
        XCTAssertEqual(log.estimate(tool: claudeCode, project: "curiplay", elapsed: 700), .overdue(worked: 700))
        XCTAssertEqual(log.longestRun(tool: claudeCode, project: "curiplay"), 600)
        XCTAssertNil(log.longestRun(tool: "Codex", project: nil))
    }

    func testAProjectsOwnRunsCountOnceThereAreEnough() {
        let log = WaitLog(url: nil, now: { self.now })
        for seconds in [60.0, 120, 180, 240, 600] {
            log.add(RunRecord(start: now, tool: claudeCode, project: "curiplay", seconds: seconds))
        }
        log.add(RunRecord(start: now, tool: claudeCode, project: "lexis-app", seconds: 20))
        XCTAssertEqual(log.estimate(tool: claudeCode, project: "lexis-app", elapsed: 0), .left(150),
                       "One run of its own: go by the tool's on every project")
        log.add(RunRecord(start: now, tool: claudeCode, project: "lexis-app", seconds: 20))
        log.add(RunRecord(start: now, tool: claudeCode, project: "lexis-app", seconds: 20))
        XCTAssertEqual(log.estimate(tool: claudeCode, project: "lexis-app", elapsed: 0), .left(20), "Three: its own")
        XCTAssertEqual(log.estimate(tool: "Codex", project: "lexis-app", elapsed: 0), .unknown, "Another tool's runs say nothing")
    }

    func testOnlyTheLatestRunsCount() {
        let log = WaitLog(url: nil, now: { self.now })
        for _ in 0..<5 { log.add(RunRecord(start: now, tool: claudeCode, project: "curiplay", seconds: 3_000)) }
        for _ in 0..<WaitRules.recentRuns { log.add(RunRecord(start: now, tool: claudeCode, project: "curiplay", seconds: 100)) }
        XCTAssertEqual(log.longestRun(tool: claudeCode, project: "curiplay"), 100, "How it works now, not long ago")
    }

    func testRunsAreKeptBesideTheWaitsAndErasedWithThem() throws {
        XCTAssertEqual(WaitLog.runsURL(beside: URL(fileURLWithPath: "/a/waits.json")).lastPathComponent, "runs.json")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waits-\(UUID().uuidString).json")
        let runsURL = WaitLog.runsURL(beside: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: runsURL)
        }
        let writer = WaitLog(url: url, now: { self.now })
        writer.add(RunRecord(start: now.addingTimeInterval(-100 * 86_400), tool: claudeCode, project: "curiplay", seconds: 60))
        writer.add(RunRecord(start: now, tool: claudeCode, project: "curiplay", seconds: 90, asked: true))
        XCTAssertEqual(writer.runs.count, 1, "Old runs are dropped")
        let reader = WaitLog(url: url, now: { self.now })
        XCTAssertEqual(reader.runs, [RunRecord(start: now, tool: claudeCode, project: "curiplay", seconds: 90, asked: true)])
        XCTAssertTrue(reader.records.isEmpty, "A run isn't a wait")
        reader.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runsURL.path))
        XCTAssertTrue(WaitLog(url: url, now: { self.now }).runs.isEmpty)
    }

    func testTheCoordinatorLogsEachRunAndJudgesAReachByThem() {
        let log = WaitLog(url: nil, now: { self.now })
        let coordinator = WaitCoordinator(log: log, island: nil)
        coordinator.isOn = { true }
        coordinator.currentMoment = { WaitMoment(now: self.now, front: self.term) }
        var awake: TimeInterval = 500
        coordinator.uptime = { awake }
        for index in 0..<3 {
            let start = TimeInterval(index) * 1_000
            coordinator.started(tool: claudeCode, project: "curiplay", session: "s\(index)", now: at(start))
            awake += 100
            coordinator.finished(tool: claudeCode, project: "curiplay", session: "s\(index)", now: at(start + 100))
        }
        XCTAssertEqual(log.runs.map(\.seconds), [100, 100, 100])

        var reach = WaitReach(tool: WaitTool(name: claudeCode, kind: .agent, bundleId: terminal), project: "curiplay", since: at(5_000), to: "x.com")
        reach.runStarted = at(4_980)
        XCTAssertEqual(coordinator.estimate(for: reach, now: at(5_010)), .left(70), "Thirty seconds into a run that takes a hundred")

        // A tool that never says when it starts: by how long the user stays away from it.
        let guessed = WaitReach(tool: WaitTool(name: "Codex", kind: .agent, bundleId: terminal), project: nil, since: at(5_000), to: "x.com")
        XCTAssertEqual(coordinator.estimate(for: guessed, now: at(5_010)), .unknown)
        for _ in 0..<3 { log.add(WaitRecord(start: now, tool: "Codex", seconds: 100, drift: 0)) }
        XCTAssertEqual(coordinator.estimate(for: guessed, now: at(5_010)), .left(90))
        XCTAssertEqual(coordinator.estimate(for: guessed, now: at(5_200)), .unknown, "Past its usual: no number is made up")
    }

    // MARK: - Card

    func testTheCardSaysHowMuchLongerInTheToolsOwnNumbers() {
        let reach = WaitReach(tool: WaitTool(name: claudeCode, kind: .agent, bundleId: terminal), project: "curiplay", since: now, to: "x.com")
        func card(_ estimate: WaitEstimate) -> IslandMoment {
            IslandMoment.waitReach(reach, estimate: estimate, next: nil, lastDrift: nil, now: at(30))
        }
        XCTAssertEqual(card(.left(200)).body,
                       "Claude Code usually needs about 3 more min from here. Stay close and you’ll catch it the moment it’s done.")
        XCTAssertEqual(card(.left(200)).countdown?.secondsLeft(at: at(30)), 200)
        XCTAssertEqual(card(.left(20)).body, "Claude Code is usually done within a minute from here. Stay and you’ll catch it.")
        XCTAssertEqual(card(.overdue(worked: 600)).body,
                       "Claude Code has been working for 10 min, longer than most of its runs. It could be done any moment.")
        XCTAssertNil(card(.overdue(worked: 600)).countdown, "Nothing to count down to")
        XCTAssertEqual(card(.overdue(worked: 20)).body, "Claude Code is usually done within a minute from here. Stay and you’ll catch it.")
        XCTAssertEqual(card(.unknown).body, "Stay close and you’ll catch it the moment it’s done.", "No runs yet: no number")
        XCTAssertNil(card(.unknown).countdown)
    }

    // MARK: - The hooks, in a real shell

    /// Runs what a hook would, with `open` swapped for `echo`: the link it would open.
    private func link(shell: String, script: String, input: String = "", environment: [String: String] = [:],
                      directory: URL? = nil) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script.replacingOccurrences(of: "open -g ", with: "echo ")]
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        if let directory { process.currentDirectoryURL = directory }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func testClaudeCodesHookSendsTheFolderAndTheSessionsIdAndNothingElse() throws {
        let start = WaitConnector.command(started: true, tool: claudeCode, folderVariable: "$CLAUDE_PROJECT_DIR", session: true)
        let folder = ["CLAUDE_PROJECT_DIR": "/Users/me/My Projects/curi play"]
        // As Claude Code hands it over: one line, with what was typed in it.
        let compact = #"{"session_id":"0a1b2c3d-4e5f-6789-abcd-ef0123456789","transcript_path":"/Users/me/.claude/x.jsonl","cwd":"/Users/me","hook_event_name":"UserPromptSubmit","prompt":"why is \"session_id\": \"secret\" in here?"}"#
        let pretty = "{\n  \"hook_event_name\": \"Stop\",\n  \"session_id\" : \"0a1b2c3d-4e5f-6789-abcd-ef0123456789\",\n  \"cwd\": \"/Users/me\"\n}\n"
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            for input in [compact, pretty] {
                let lines = try link(shell: shell, script: start, input: input, environment: folder)
                XCTAssertEqual(lines, ["focusguard://wait/start?tool=Claude%20Code&project=curi%20play&s=0a1b2c3d-4e5"], shell)
                XCTAssertEqual(lines.first.flatMap(URL.init(string:)).flatMap(FocusGuardURL.init),
                               .wait(started: true, tool: claudeCode, project: "curi play", session: "0a1b2c3d-4e5"), shell)
            }
            let none = try link(shell: shell, script: start, input: "", environment: folder)
            XCTAssertEqual(none.first.flatMap(URL.init(string:)).flatMap(FocusGuardURL.init),
                           .wait(started: true, tool: claudeCode, project: "curi play"), "No id handed over: none sent")
        }
        let idle = WaitConnector.command(started: false, tool: claudeCode, folderVariable: "$CLAUDE_PROJECT_DIR", quiet: true, session: true)
        XCTAssertEqual(try link(shell: "/bin/sh", script: idle, input: compact, environment: folder).first
                        .flatMap(URL.init(string:)).flatMap(FocusGuardURL.init),
                       .wait(started: false, tool: claudeCode, project: "curi play", session: "0a1b2c3d-4e5", quiet: true))
    }

    func testFgwaitNumbersEachRunAndNamesItsFolderAtBothEnds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fgwait \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for shell in ["/bin/bash", "/bin/zsh"] {
            let lines = try link(shell: shell, script: WaitConnector.shellFunction + "\nfgwait true", directory: folder)
            let routes = lines.compactMap { URL(string: $0).flatMap(FocusGuardURL.init) }
            guard routes.count == 2, case .wait(true, "true", let project, false, let session, false) = routes[0] else {
                return XCTFail("Expected a start and a done from \(shell), got \(lines)")
            }
            XCTAssertEqual(project, folder.lastPathComponent)
            XCTAssertNotNil(session)
            XCTAssertEqual(routes[1], .wait(started: false, tool: "true", project: project, session: session), shell)
        }
    }
}
