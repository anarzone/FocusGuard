import XCTest
@testable import FocusGuard

/// Holding a site while a tool works: on the test's On days only, what the
/// card and the paused tab say, and the plan's words.
@MainActor
final class WaitHoldTests: XCTestCase {
    typealias F = CoachFixture
    private var clock = F.at(1, 10)

    private let fix = AnalyzerFix(cause: .habit, change: .holdInWait(tool: "Claude Code", site: "x.com", seconds: 120),
                                  measure: .longestStretch)

    private func analyzer() -> FocusAnalyzer {
        let analyzer = FocusAnalyzer(defaults: UserDefaults(suiteName: "wait-hold-\(UUID().uuidString)")!, calendar: CoachFixture.calendar)
        analyzer.now = { [unowned self] in self.clock }
        analyzer.isUnlocked = { true }
        analyzer.startTrial = { }
        analyzer.weekendsCount = { false }
        return analyzer
    }

    func testTheSiteIsHeldOnOnDaysOnly() throws {
        let analyzer = analyzer()
        XCTAssertNil(analyzer.holdSeconds(tool: "Claude Code", site: "x.com"), "No test, no hold")
        XCTAssertTrue(analyzer.start(fix, plan: "", seed: 3, calendarOK: false))
        let slots = try XCTUnwrap(analyzer.state.experiment?.slots)
        let on = try XCTUnwrap(slots.first { $0.arm == .on })
        let off = try XCTUnwrap(slots.first { $0.arm == .off })

        clock = on.day.addingTimeInterval(10 * 3600)
        XCTAssertEqual(analyzer.holdSeconds(tool: "Claude Code", site: "x.com"), 120)
        XCTAssertEqual(analyzer.holdSeconds(tool: "Claude Code", site: "mobile.x.com"), 120, "Its subdomains too")
        XCTAssertNil(analyzer.holdSeconds(tool: "Codex", site: "x.com"), "Another tool's wait isn't part of it")
        XCTAssertNil(analyzer.holdSeconds(tool: "Claude Code", site: "youtube.com"))

        clock = off.day.addingTimeInterval(10 * 3600)
        XCTAssertNil(analyzer.holdSeconds(tool: "Claude Code", site: "x.com"), "Off days stay as they were, to compare")
    }

    func testThePlanSaysWhatHappens() {
        XCTAssertEqual(fix.change.plan, "If Claude Code is working, then I'll wait 2 minutes before x.com.")
        XCTAssertEqual(fix.change.onDays, "x.com waits 2 minutes when you leave Claude Code for it")
    }

    func testAHeldCardSaysSoAndCountsDownToTheHold() {
        let now = F.at(1, 10)
        let tool = WaitTool(name: "Claude Code", kind: .agent, bundleId: "com.apple.Terminal")
        let reach = WaitReach(tool: tool, project: "Curiplay", since: now, to: "x.com")
        let held = now.addingTimeInterval(120)
        let card = IslandMoment.waitReach(reach, usual: 60, next: nil, lastDrift: nil, heldUntil: held, now: now.addingTimeInterval(10))
        XCTAssertEqual(card.title, "x.com is on hold for 2 min.")
        XCTAssertEqual(card.countdown?.ends, held, "The ring runs to the end of the hold, not the usual wait")
        XCTAssertEqual(card.buttons.last?.title, "OK", "Nothing to open anyway: the tab does that itself")
        XCTAssertNil(card.buttons.last?.command)
    }

    func testTheHoldPageGetsTheToolAndItsEnd() throws {
        let base = URL(fileURLWithPath: "/paused.html")
        let tab = PausedTab(id: "abc", browser: "com.google.Chrome", host: "x.com", originalURL: URL(string: "https://x.com/home")!,
                            reason: .hold(tool: "Claude Code"), endsAt: F.at(1, 10, 2), backTo: "Curiplay", startedAt: F.at(1, 10))
        let url = PausedPage.url(base: base, for: tab, state: .hold)
        let fragment = try XCTUnwrap(url.fragment)
        XCTAssertTrue(fragment.contains("state=hold"))
        XCTAssertTrue(fragment.contains("tool=Claude%20Code"))
        XCTAssertTrue(fragment.contains("ends="))
        XCTAssertTrue(fragment.contains("back=Curiplay"))
    }
}
