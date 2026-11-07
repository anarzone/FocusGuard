import XCTest
@testable import FocusGuard

/// The decision log: what counts as a picked goal, how outcomes add up, and
/// that it keeps no content and not forever.
@MainActor
final class DecisionLogTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private lazy var log = DecisionLog(url: nil, now: { [unowned self] in clock })

    func testAPickedSuggestionCountsOnlyIfTheGoalIsStillIt() {
        log.noteOffered(["lastGoal", "task.linear"])
        log.notePicked(kind: "task.linear", position: 1, text: "ENG-142 Fix login")
        log.sessionStarted(UUID(), goal: "ENG-142 Fix login")
        XCTAssertEqual(log.entries.last?.outcome, "suggestion")
        XCTAssertEqual(log.entries.last?.detail, "offered:lastGoal,task.linear picked:task.linear#2")

        log.noteOffered(["lastGoal"])
        log.notePicked(kind: "lastGoal", position: 0, text: "Write the docs")
        log.sessionStarted(UUID(), goal: "Write the docs, then the tests")
        XCTAssertEqual(log.entries.last?.outcome, "typed", "Edited after picking: the user's own")

        log.sessionStarted(UUID(), goal: nil)
        XCTAssertEqual(log.entries.last?.outcome, "none")
        XCTAssertEqual(log.entries.last?.detail, "offered:none", "What was offered goes with the session that used it")
    }

    func testTheSummaryAddsUp() {
        let picked = UUID(), typed = UUID()
        log.noteOffered(["task.github"])
        log.notePicked(kind: "task.github", position: 0, text: "Ship it")
        log.sessionStarted(picked, goal: "Ship it")
        log.sessionStarted(typed, goal: "Mine")
        log.record(.verdict, GoalVerdict.partly.rawValue, session: picked)
        log.record(.verdict, GoalVerdict.done.rawValue, session: picked)
        log.record(.verdict, GoalVerdict.notYet.rawValue, session: typed)
        log.record(.island, "shown", detail: "drift")
        log.record(.island, "shown", detail: "pickUp")
        log.record(.island, "pressed", detail: "drift")
        log.record(.browserBlock, "shown")
        log.record(.block, "shown")
        log.record(.block, "backToWork")
        log.record(.browserBlock, "letThrough")
        log.noteTick(0.002)
        log.noteTick(0.004)

        let summary = log.summary()
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.withGoal, 2)
        XCTAssertEqual(summary.fromSuggestion, 1)
        XCTAssertEqual(summary.offeredSuggestions, 1)
        XCTAssertEqual(summary.verdicts, 2, "The last word on each session")
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(summary.doneFromSuggestion, 1)
        XCTAssertEqual(summary.cardsShown, 2)
        XCTAssertEqual(summary.cardsAnswered, 1)
        XCTAssertEqual(summary.blocksShown, 2)
        XCTAssertEqual(summary.backToWork, 1)
        XCTAssertEqual(summary.letThrough, 1)
        XCTAssertEqual(summary.timing.count, 2)
        XCTAssertEqual(summary.timing.average, 0.003, accuracy: 1e-9)
        XCTAssertEqual(summary.timing.longest, 0.004, accuracy: 1e-9)
    }

    func testOnlyTheLastWeekCounts() {
        log.record(.island, "shown")
        clock = clock.addingTimeInterval(8 * 86_400)
        log.record(.island, "shown")
        XCTAssertEqual(log.summary().cardsShown, 1)
    }

    func testItKeepsNinetyDaysOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decisions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = DecisionLog(url: url, now: { [unowned self] in clock })
        disk.record(.island, "shown")
        disk.save()
        clock = clock.addingTimeInterval(Double(DecisionLog.keptDays + 1) * 86_400)
        disk.record(.island, "pressed")
        disk.save()
        let reread = DecisionLog(url: url, now: { [unowned self] in clock })
        XCTAssertEqual(reread.entries.map(\.outcome), ["pressed"])
        reread.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTheLogHoldsNoContent() throws {
        log.noteOffered(["task.reminders"])
        log.notePicked(kind: "task.reminders", position: 0, text: "Call the bank about the mortgage")
        log.sessionStarted(UUID(), goal: "Call the bank about the mortgage")
        let exported = String(decoding: log.exportData(), as: UTF8.self)
        XCTAssertFalse(exported.contains("bank"), exported)
    }

    func testSuggestionKindsNameTheSourceNotTheText() {
        XCTAssertEqual(GoalSuggestion(text: "x", source: .task(.linear, id: "1", list: "ENG")).logKind, "task.linear")
        XCTAssertEqual(GoalSuggestion(text: "x", source: .lastGoal).logKind, "lastGoal")
        XCTAssertEqual(GoalSuggestion(text: "x", source: .git(repo: "app")).logKind, "git")
    }
}
