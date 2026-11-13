import XCTest
@testable import FocusGuard

/// Cards that learn: a kind let go by 4 times in a row shows at most once a
/// day, after 8 it pauses for two weeks, and using it once puts it back.
/// A fake clock and surface: nothing here puts anything on screen.
@MainActor
final class IslandLearningTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
    /// 10:00 UTC, Wednesday 4 Nov 2026.
    private lazy var start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10)) ?? .now

    private func day(_ offset: Int, hour: Int = 10) -> Date {
        calendar.date(byAdding: .hour, value: offset * 24 + hour - 10, to: start) ?? start
    }

    // MARK: - The rules

    func testFourInARowSlowsItToOnceADay() {
        var learning = IslandLearning()
        for index in 0..<3 {
            learning.shown(.autoStart, now: day(index))
            XCTAssertNil(learning.passed(.autoStart, now: day(index), calendar: calendar))
        }
        XCTAssertEqual(learning.state(.autoStart, now: day(3)), .on)
        learning.shown(.autoStart, now: day(3))
        XCTAssertEqual(learning.passed(.autoStart, now: day(3), calendar: calendar), .resting(streak: 4))
        XCTAssertEqual(learning.holds(.autoStart, now: day(3, hour: 15), calendar: calendar), .resting(streak: 4), "Shown today already")
        XCTAssertNil(learning.holds(.autoStart, now: day(4), calendar: calendar), "A new day: once more")
    }

    func testEightInARowPausesItForTwoWeeks() {
        var learning = IslandLearning()
        var changes: [IslandLearning.State?] = []
        for index in 0..<8 {
            learning.shown(.driftPrompt, now: day(index))
            changes.append(learning.passed(.driftPrompt, now: day(index), calendar: calendar))
        }
        let until = calendar.startOfDay(for: day(7 + IslandLearning.pauseDays))
        XCTAssertEqual(changes.compactMap { $0 }, [.resting(streak: 4), .paused(until: until)], "Said once each")
        XCTAssertEqual(learning.holds(.driftPrompt, now: day(10), calendar: calendar), .paused(until: until))
        XCTAssertNil(learning.holds(.driftPrompt, now: until, calendar: calendar), "The pause runs out")
    }

    func testBackFromAPauseTwoMoreMissesPauseItForAMonth() {
        var learning = IslandLearning()
        for index in 0..<8 {
            learning.shown(.pickUp, now: day(index))
            learning.passed(.pickUp, now: day(index), calendar: calendar)
        }
        let back = day(7 + IslandLearning.pauseDays)
        learning.shown(.pickUp, now: back)
        XCTAssertEqual(learning.state(.pickUp, now: back), .on, "A fresh chance")
        learning.passed(.pickUp, now: back, calendar: calendar)
        XCTAssertEqual(learning.state(.pickUp, now: back), .resting(streak: 1), "On probation: once a day straight away")
        let next = calendar.date(byAdding: .day, value: 1, to: back) ?? back
        learning.shown(.pickUp, now: next)
        let state = learning.passed(.pickUp, now: next, calendar: calendar)
        XCTAssertEqual(state, .paused(until: calendar.startOfDay(for: calendar.date(byAdding: .day, value: IslandLearning.longPauseDays, to: next) ?? next)))
        XCTAssertEqual(learning.entries["pickUp"]?.pauses, 2)
    }

    func testUsingItOnceBringsItBack() {
        var learning = IslandLearning()
        for index in 0..<6 {
            learning.shown(.autoStart, now: day(index))
            learning.passed(.autoStart, now: day(index), calendar: calendar)
        }
        learning.used(.autoStart)
        XCTAssertEqual(learning.state(.autoStart, now: day(6)), .on)
        XCTAssertTrue(learning.entries.isEmpty)
        for index in 0..<8 {
            learning.shown(.morningPlan, now: day(index))
            learning.passed(.morningPlan, now: day(index), calendar: calendar)
        }
        learning.bringBack(.morningPlan)
        XCTAssertEqual(learning.state(.morningPlan, now: day(9)), .on, "Bring it back")
    }

    func testCardsThatAlwaysShowNeverLearn() {
        var learning = IslandLearning()
        for kind in [IslandKind.drift, .wait, .limit, .sessionFinished, .breakOver, .reminder, .trial, .sample] {
            XCTAssertFalse(IslandLearning.learns(kind), "\(kind)")
            for index in 0..<10 {
                learning.shown(kind, now: day(index))
                XCTAssertNil(learning.passed(kind, now: day(index), calendar: calendar))
            }
            XCTAssertEqual(learning.state(kind, now: day(11)), .on)
        }
        XCTAssertTrue(learning.entries.isEmpty)
    }

    func testOneKindsMissesDontHoldAnother() {
        var learning = IslandLearning()
        for index in 0..<8 {
            learning.shown(.autoStart, now: day(index))
            learning.passed(.autoStart, now: day(index), calendar: calendar)
        }
        XCTAssertEqual(learning.state(.driftPrompt, now: day(9)), .on)
        XCTAssertEqual(learning.heldBack(now: day(9)).map(\.kind), [.autoStart])
    }

    func testItsKeptAndAnOldInstallHasNone() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "IslandLearningTests.\(UUID().uuidString)"))
        XCTAssertEqual(IslandLearning.load(defaults), IslandLearning())
        var learning = IslandLearning()
        learning.shown(.wrapUp, now: day(0))
        learning.passed(.wrapUp, now: day(0), calendar: calendar)
        learning.save(defaults)
        XCTAssertEqual(IslandLearning.load(defaults), learning)
        learning.used(.wrapUp)
        learning.save(defaults)
        XCTAssertNil(defaults.data(forKey: IslandLearning.key), "Nothing to keep: nothing kept")
    }

    // MARK: - What came before

    private func entry(_ outcome: String, _ kind: IslandKind, day offset: Int) -> DecisionLog.Entry {
        DecisionLog.Entry(at: day(offset), kind: .island, outcome: outcome, detail: kind.rawValue)
    }

    func testItCatchesUpOnTheLogFromBeforeItLearned() {
        var log: [DecisionLog.Entry] = []
        for index in 0..<10 { log.append(entry("shown", .pickUp, day: index)) }
        for index in 0..<6 { log.append(entry("shown", .autoStart, day: index)) }
        log.append(entry("pressed", .autoStart, day: 6))
        for index in 7..<9 { log.append(entry("shown", .autoStart, day: index)) }
        for index in 0..<5 { log.append(entry("shown", .driftPrompt, day: index)) }
        for index in 0..<20 { log.append(entry("shown", .wait, day: index % 5)) }
        var learning = IslandLearning()
        learning.catchUp(from: log, now: day(10), calendar: calendar)
        XCTAssertEqual(learning.state(.pickUp, now: day(10)),
                       .paused(until: calendar.startOfDay(for: day(10 + IslandLearning.pauseDays))), "Never used in 10")
        XCTAssertEqual(learning.state(.autoStart, now: day(10)), .on, "Used on day 6: two since")
        XCTAssertEqual(learning.entries["autoStart"]?.streak, 2)
        XCTAssertEqual(learning.state(.driftPrompt, now: day(10)), .resting(streak: 5))
        XCTAssertNil(learning.entries["wait"], "The tool's own word doesn't learn")
    }

    func testCatchingUpNeverLowersWhatsAlreadyLearned() {
        var learning = IslandLearning()
        for index in 0..<6 {
            learning.shown(.autoStart, now: day(index))
            learning.passed(.autoStart, now: day(index), calendar: calendar)
        }
        learning.catchUp(from: [entry("shown", .autoStart, day: 1)], now: day(7), calendar: calendar)
        XCTAssertEqual(learning.entries["autoStart"]?.streak, 6)
    }

    // MARK: - The words

    func testSettingsSaysWhyAndForHowLong() {
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(HeldCardsCopy.note(.resting(streak: 5), entry: .init(streak: 5), calendar: calendar, locale: locale),
                       "Once a day for now. You let the last 5 go by. 3 more pause it for two weeks.")
        XCTAssertEqual(HeldCardsCopy.note(.resting(streak: 7), entry: .init(streak: 7), calendar: calendar, locale: locale),
                       "Once a day for now. You let the last 7 go by. One more pauses it for two weeks.")
        XCTAssertEqual(HeldCardsCopy.note(.resting(streak: 1), entry: .init(streak: 1, onProbation: true), calendar: calendar, locale: locale),
                       "Once a day for now: it came back from a pause and you let it go by again.")
        let until = day(14)
        XCTAssertEqual(HeldCardsCopy.note(.paused(until: until), entry: .init(pauses: 1), calendar: calendar, locale: locale),
                       "Paused until Wed 18 Nov. You let the last 8 go by.")
        XCTAssertEqual(HeldCardsCopy.note(.paused(until: until), entry: .init(pauses: 2), calendar: calendar, locale: locale),
                       "Paused until Wed 18 Nov. It came back once and went by unused again.")
        for kind in IslandKind.allCases where IslandLearning.learns(kind) {
            XCTAssertNotEqual(HeldCardsCopy.name(kind), kind.rawValue, "\(kind) has a name")
        }
    }
}

/// The controller counts each card once: used, let go by, or neither.
@MainActor
final class IslandLearningControllerTests: XCTestCase {
    private final class FakeSurface: IslandSurface {
        var shown: [IslandMoment] = []
        func attach(_ island: IslandController) {}
        func show(_ moment: IslandMoment, open: Bool, now: Date) { shown.append(moment) }
        func update(_ moment: IslandMoment, open: Bool, now: Date) {}
        func hide() {}
        func announce(_ text: String, urgent: Bool) {}
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
    private var now = Date()
    private var surface = FakeSurface()
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var island: IslandController!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "IslandLearningControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10)) ?? now
        surface = FakeSurface()
        island = IslandController(surface: surface, clock: { [unowned self] in self.now }, defaults: defaults,
                                  calendar: calendar, runsTimer: false)
        // A pause, so a card that waits for one shows at once.
        island.conditions = { [unowned self] in IslandConditions(now: self.now, frontApp: "com.example.code", idleSeconds: 10) }
        island.perform = { _ in }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        island = nil
        try await super.tearDown()
    }

    private func offer(_ kind: IslandKind = .autoStart, requested: Bool = false) -> IslandMoment {
        IslandMoment(kind: kind, key: "\(kind)", pillName: "p", kicker: "k", title: "t", body: "b",
                     buttons: [IslandButton(title: "Start", command: .startSession(minutes: 25)), IslandButton(title: "Not now")],
                     requested: requested)
    }

    private func nextDay() { now = calendar.date(byAdding: .day, value: 1, to: now) ?? now }

    /// Posts it, then lets its time on screen run out.
    private func letPass(_ moment: IslandMoment) {
        island.post(moment)
        now = now.addingTimeInterval((IslandRules.timing(moment.kind).onScreen ?? 30) + 1)
        island.tick()
    }

    func testRunningOutNotNowAndCloseAllCountAsLetPass() {
        letPass(offer())
        XCTAssertEqual(island.learning.entries["autoStart"]?.streak, 1)
        nextDay()
        island.post(offer())
        island.press(IslandButton(title: "Not now"))
        XCTAssertEqual(island.learning.entries["autoStart"]?.streak, 2)
        nextDay()
        island.post(offer())
        island.closeCurrent()
        XCTAssertEqual(island.learning.entries["autoStart"]?.streak, 3)
        XCTAssertNotNil(IslandLearning.load(defaults).entries["autoStart"], "Kept")
    }

    func testUsingItResetsIt() {
        for _ in 0..<3 {
            letPass(offer())
            nextDay()
        }
        island.post(offer())
        island.press(IslandButton(title: "Start", command: .startSession(minutes: 25)))
        XCTAssertNil(island.learning.entries["autoStart"])
    }

    func testOnceItRestsASecondCardThatDayIsHeld() {
        for _ in 0..<4 {
            letPass(offer())
            nextDay()
        }
        letPass(offer())
        let shown = surface.shown.count
        now = now.addingTimeInterval(3600)
        island.post(offer())
        XCTAssertEqual(surface.shown.count, shown, "Held: it showed today already")
        XCTAssertNil(island.queue.current)
        island.post(offer(requested: true))
        XCTAssertEqual(surface.shown.count, shown + 1, "What the user asked for always shows")
    }

    func testTakenAwayByWhatItWasAboutCountsForNothing() {
        island.post(offer())
        island.remove(key: "autoStart")
        now = now.addingTimeInterval(60)
        island.tick()
        XCTAssertEqual(island.learning.entries["autoStart"]?.streak, 0, "The offer stopped being true; the user said nothing")
    }

    func testPickUpLearnsFromItsOwnButtons() {
        island.noteAnswer(.pickUp, used: false)
        island.noteAnswer(.pickUp, used: false)
        XCTAssertEqual(island.learning.entries["pickUp"]?.streak, 2)
        island.noteAnswer(.pickUp, used: true)
        XCTAssertNil(island.learning.entries["pickUp"])
    }

    func testBringingItBackShowsItAgain() {
        for _ in 0..<8 {
            letPass(offer())
            nextDay()
        }
        XCTAssertEqual(island.learning.heldBack(now: now).map(\.kind), [.autoStart])
        island.bringBack(.autoStart)
        XCTAssertEqual(island.learning.heldBack(now: now).count, 0)
        let shown = surface.shown.count
        island.post(offer())
        XCTAssertEqual(surface.shown.count, shown + 1)
    }
}
