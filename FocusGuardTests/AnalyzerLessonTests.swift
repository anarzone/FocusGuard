import XCTest
@testable import FocusGuard

/// What the user's corrections teach: a pattern that's fine stops counting,
/// here and on the wait card; the question is asked once; "It's for work"
/// said on two days offers to sort the site. Nothing here reaches a real app.
@MainActor
final class AnalyzerLessonTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar

    private func event(_ day: Int, _ h: Int, _ m: Int, _ minutes: Double, _ kind: Classification, _ target: String) -> CoachEvent {
        let start = F.at(day, h, m)
        return CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: kind, target: target, name: target,
                          isSite: target.contains(".") && !target.hasPrefix("com."), session: nil, bundleId: nil)
    }

    /// Work, a drift from the terminal to `to`, then work again.
    private func day(_ day: Int, to: String = "x.com") -> AnalyzerDay {
        let events = [event(day, 9, 0, 60, .focus, "com.xcode"), event(day, 10, 0, 3, .focus, "com.terminal"),
                      event(day, 10, 3, 9, .distraction, to), event(day, 10, 12, 60, .focus, "com.xcode")]
        return AnalyzerDayBuilder.make(day: F.at(day, 0), events: events, calendar: calendar)
    }

    private func marked(_ trigger: AnalyzerTrigger, _ count: Int) -> Set<String> {
        Set(trigger.moments.prefix(count).map(\.id))
    }

    // MARK: - The question

    func testItAsksAfterTwoMomentsOfOnePatternAreRuledOut() {
        let days = (0..<4).map { day($0) }
        let lessons = AnalyzerLessons()
        guard let plain = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [], calendar: calendar).first else { return XCTFail("Expected a trigger") }
        XCTAssertFalse(lessons.asks(about: plain))
        let one = AnalyzerTriggers.make(days: days, waits: [], ruledOut: marked(plain, 1), calendar: calendar).first
        XCTAssertEqual(one.map { lessons.asks(about: $0) }, false, "One could be a one-off")
        let two = AnalyzerTriggers.make(days: days, waits: [], ruledOut: marked(plain, 2), calendar: calendar).first
        XCTAssertEqual(two.map { lessons.asks(about: $0) }, true)
    }

    func testItNeverAsksTwiceAboutOnePattern() {
        let days = (0..<4).map { day($0) }
        guard let plain = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [], calendar: calendar).first,
              let two = AnalyzerTriggers.make(days: days, waits: [], ruledOut: marked(plain, 2), calendar: calendar).first
        else { return XCTFail("Expected a trigger") }
        var lessons = AnalyzerLessons()
        lessons.decline(two.id)
        XCTAssertFalse(lessons.asks(about: two), "“Just those times” is an answer")
        var all = two
        all.moments = all.moments.map { AnalyzerTrigger.Moment(start: $0.start, seconds: $0.seconds, isRuledOut: true) }
        XCTAssertFalse(lessons.asks(about: all), "However many more are ruled out")
        lessons.teach(two.id)
        XCTAssertFalse(lessons.asks(about: two))
        XCTAssertEqual(lessons.declined, [], "Teaching it replaces the earlier answer")
    }

    func testAPatternStaysListedUntilTheQuestionIsAnswered() {
        let days = (0..<3).map { day($0) }
        guard let plain = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [], calendar: calendar).first else { return XCTFail("Expected a trigger") }
        // Two of three ruled out: one left, which alone is no pattern.
        let asking = AnalyzerTriggers.make(days: days, waits: [], ruledOut: marked(plain, 2), calendar: calendar)
        XCTAssertEqual(asking.first?.count, 1)
        XCTAssertEqual(asking.first?.isAsking, true, "Still there, so it can ask")
        XCTAssertEqual(AnalyzerTriggers.recent(asking, days: 28, now: F.at(27, 9), calendar: calendar).count, 1)
        let answered = AnalyzerTriggers.make(days: days, waits: [], ruledOut: marked(plain, 2),
                                             lessons: AnalyzerLessons(declined: [plain.id]), calendar: calendar)
        XCTAssertEqual(answered, [], "Answered: it goes like any pattern seen once")
    }

    func testPuttingItBackLetsItBeAskedAgain() {
        var lessons = AnalyzerLessons()
        lessons.teach("com.terminal>x.com")
        lessons.forget("com.terminal>x.com")
        XCTAssertTrue(lessons.isEmpty)
        let defaults = UserDefaults(suiteName: "AnalyzerLessonTests.\(UUID().uuidString)")!
        let moments = [AnalyzerTrigger.Moment(start: F.at(0, 10, 3), seconds: 60), AnalyzerTrigger.Moment(start: F.at(1, 10, 3), seconds: 60)]
        moments.forEach { AnalyzerRuledOut.toggle($0, defaults) }
        AnalyzerRuledOut.toggle(AnalyzerTrigger.Moment(start: F.at(2, 9), seconds: 60), defaults)
        AnalyzerRuledOut.clear(moments, defaults)
        XCTAssertEqual(AnalyzerRuledOut.load(defaults), [AnalyzerTriggers.key(F.at(2, 9))], "Only that pattern's marks go")
    }

    // MARK: - A pattern that's fine

    func testAFinePatternLeavesTheListAndShowsWhatItTookOut() {
        let days = (0..<3).map { day($0) } + (3..<6).map { day($0, to: "youtube.com") }
        let all = AnalyzerTriggers.build(days: days, waits: [], ruledOut: [], calendar: calendar)
        XCTAssertEqual(all.shown.map(\.id), ["com.terminal>x.com", "com.terminal>youtube.com"])
        XCTAssertEqual(all.taught, [])

        let built = AnalyzerTriggers.build(days: days, waits: [], ruledOut: [], lessons: AnalyzerLessons(fine: ["com.terminal>x.com"]), calendar: calendar)
        XCTAssertEqual(built.shown.map(\.id), ["com.terminal>youtube.com"])
        XCTAssertEqual(built.taught.map(\.id), ["com.terminal>x.com"])
        XCTAssertEqual(built.taught.first?.count, 3)
        XCTAssertEqual(built.taught.first?.seconds, 3 * 9 * 60)
    }

    func testAFinePatternCountsEveryMomentEvenTheOnesRuledOutBefore() {
        let days = (0..<3).map { day($0) }
        guard let plain = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [], calendar: calendar).first else { return XCTFail("Expected a trigger") }
        let taught = AnalyzerTriggers.build(days: days, waits: [], ruledOut: marked(plain, 2), lessons: AnalyzerLessons(fine: [plain.id]), calendar: calendar).taught.first
        XCTAssertEqual(taught?.count, 3, "What it took out is all of it")
    }

    func testAFinePatternSeenOnceIsStillListedAsTaught() {
        let built = AnalyzerTriggers.build(days: [day(0)], waits: [], ruledOut: [], lessons: AnalyzerLessons(fine: ["com.terminal>x.com"]), calendar: calendar)
        XCTAssertEqual(built.shown, [])
        XCTAssertEqual(built.taught.first?.count, 1)
    }

    func testItsLostFocusComesOutOfTheDaysToo() {
        let days = (0..<2).map { day($0) } + [day(2, to: "youtube.com")]
        XCTAssertEqual(days.map(\.losses.count), [1, 1, 1])
        let without = AnalyzerTriggers.without(fine: ["com.terminal>x.com"], days: days, waits: [])
        XCTAssertEqual(without.map(\.losses.count), [0, 0, 1], "Only that pattern's")
        XCTAssertEqual(without.map(\.tracked), days.map(\.tracked), "The time was still spent")
        XCTAssertEqual(AnalyzerTriggers.without(fine: [], days: days, waits: []), days)
    }

    func testAFineWaitTakesItsDriftsAndTheirLostFocusOut() {
        let days = (0..<3).map { day($0) }
        let waits = (0..<3).map { WaitRecord(start: F.at($0, 10, 3), tool: "Codex", project: "curiplay", seconds: 540, drift: 540, to: "x.com") }
        let id = AnalyzerLessonRules.waitID(tool: "Codex", site: "x.com")
        XCTAssertEqual(AnalyzerTriggers.make(days: days, waits: waits, ruledOut: [], calendar: calendar).map(\.id), [id])
        let built = AnalyzerTriggers.build(days: days, waits: waits, ruledOut: [], lessons: AnalyzerLessons(fine: [id]), calendar: calendar)
        XCTAssertEqual(built.shown, [])
        XCTAssertEqual(built.taught.map(\.id), [id])
        XCTAssertEqual(AnalyzerTriggers.without(fine: [id], days: days, waits: waits).map(\.losses.count), [0, 0, 0])
        XCTAssertEqual(AnalyzerTriggers.without(fine: ["wait:Codex>youtube.com"], days: days, waits: waits).map(\.losses.count), [1, 1, 1],
                       "Another site while it works is still a drift")
    }

    func testAWaitOnAFineSiteReadsAsStayedWithTheWork() {
        var drifted = WaitRecord(start: F.at(0, 10), tool: "Codex", project: "curiplay", seconds: 600, drift: 400, to: "x.com")
        drifted.exact = true
        drifted.worked = 300
        drifted.ran = F.at(0, 9, 55)
        drifted.late = 200
        let other = WaitRecord(start: F.at(0, 11), tool: "Codex", project: "curiplay", seconds: 600, drift: 400, to: "youtube.com")
        XCTAssertEqual(AnalyzerLessons().settled([drifted, other]), [drifted, other])
        let settled = AnalyzerLessons(fine: ["wait:Codex>x.com"]).settled([drifted, other])
        XCTAssertEqual(settled.map(\.drifted), [false, true])
        XCTAssertNil(settled[0].to)
        XCTAssertNil(settled[0].late, "Its answer didn't sit: they weren't on a distraction")
        XCTAssertEqual(settled[0].ran, drifted.ran, "Still that run's wait")
        XCTAssertEqual(settled[0].worked, 300)
        XCTAssertEqual(settled[0].seconds, 600)
    }

    func testTheReportLeavesAFinePatternOutOfItsNumbers() {
        let days = (0..<8).map { day($0) }
        let period = DateInterval(start: F.at(0, 0), end: F.at(8, 0))
        let plain = AnalyzerReport.make(period: period, days: days, before: [], muted: [], weekendsCount: true, calendar: calendar)
        let taught = AnalyzerReport.make(period: period, days: days, before: [], muted: [], weekendsCount: true,
                                         lessons: AnalyzerLessons(fine: ["com.terminal>x.com"]), calendar: calendar)
        XCTAssertEqual(plain.triggers.count, 1)
        XCTAssertEqual(plain.taught, [])
        XCTAssertEqual(taught.triggers, [])
        XCTAssertEqual(taught.taught.first?.count, 8)
        XCTAssertEqual(taught.workingDays, plain.workingDays, "It's still a working day")
        XCTAssertEqual(taught.rows.reduce(0) { $0 + $1.perDay }, 0, "Nothing lost is left to explain")
        XCTAssertGreaterThan(plain.rows.reduce(0) { $0 + $1.perDay }, 0)
    }

    func testAPatternsStepsReadBackFromItsId() {
        XCTAssertEqual(AnalyzerTriggers.steps(of: "wait:Claude Code>x.com"),
                       [.init(label: "Claude Code", kind: .wait), .init(label: "x.com", kind: .site)])
        XCTAssertEqual(AnalyzerTriggers.steps(of: "Xcode>youtube.com"),
                       [.init(label: "Xcode", kind: .app), .init(label: "youtube.com", kind: .site)])
        XCTAssertEqual(AnalyzerTriggers.steps(of: "x.com"), [.init(label: "x.com", kind: .site)])
        XCTAssertEqual(AnalyzerLessons(fine: ["a>b", "wait:Codex>x.com"]).fineWaits, ["wait:Codex>x.com"])
    }

    // MARK: - On the wait card

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private func snap(_ bundleId: String, url: String? = nil, _ kind: Classification = .neutral, at seconds: TimeInterval = 0) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleId, appName: bundleId, windowTitle: "Some window", url: url,
                         classification: kind, observedAt: at(seconds))
    }
    private var term: ActivitySnapshot { snap("com.apple.Terminal") }
    private func site(_ host: String, at seconds: TimeInterval) -> ActivitySnapshot {
        snap("com.google.Chrome", url: "https://\(host)/home", .distraction, at: seconds)
    }

    func testASiteThatsFineWhileTheToolWorksIsNoDrift() {
        var watcher = WaitWatcher()
        watcher.fine = [AnalyzerLessonRules.waitID(tool: "Claude Code", site: "x.com")]
        watcher.started(tool: "Claude Code", project: "curiplay", session: "a", front: term, at: now)
        XCTAssertEqual(watcher.observe(WaitMoment(now: at(30), front: site("x.com", at: 30))), [], "No card")
        let back = watcher.observe(WaitMoment(now: at(200), front: term))
        guard case .ended(let record, true)? = back.first else { return XCTFail("Expected the wait to end") }
        XCTAssertFalse(record.drifted)
        XCTAssertEqual(record.drift, 0)
    }

    func testAnotherSiteWhileItWorksIsStillADrift() {
        var watcher = WaitWatcher()
        watcher.fine = [AnalyzerLessonRules.waitID(tool: "Claude Code", site: "x.com")]
        watcher.started(tool: "Claude Code", project: "curiplay", session: "a", front: term, at: now)
        let events = watcher.observe(WaitMoment(now: at(30), front: site("youtube.com", at: 30)))
        guard case .reached(let reach)? = events.first else { return XCTFail("Expected a reach") }
        XCTAssertEqual(reach.to, "youtube.com")

        var other = WaitWatcher()
        other.fine = [AnalyzerLessonRules.waitID(tool: "Codex", site: "x.com")]
        other.started(tool: "Claude Code", project: "curiplay", session: "a", front: term, at: now)
        XCTAssertFalse(other.observe(WaitMoment(now: at(30), front: site("x.com", at: 30))).isEmpty, "Fine for Codex only")
    }

    func testTheToolsFinishStillReachesThemOnAFineSite() {
        var watcher = WaitWatcher()
        watcher.fine = [AnalyzerLessonRules.waitID(tool: "Claude Code", site: "x.com")]
        watcher.started(tool: "Claude Code", project: "curiplay", session: "a", front: term, at: now)
        _ = watcher.observe(WaitMoment(now: at(30), front: site("x.com", at: 30)))
        let events = watcher.finished(tool: "Claude Code", project: "curiplay", session: "a", needsInput: false, at: at(120))
        XCTAssertTrue(events.contains { if case .done = $0 { return true } else { return false } }, "They want to know it's done")
    }

    // MARK: - "It's for work"

    func testForWorkSaidOnTwoDaysOffersToSortTheSite() {
        var lessons = AnalyzerLessons()
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(1, 10), calendar: calendar)
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(1, 15), calendar: calendar)
        XCTAssertNil(lessons.workSuggestion(), "Twice in one day is one day")
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(3, 9), calendar: calendar)
        XCTAssertEqual(lessons.workSuggestion()?.key, "docs.rs")
        XCTAssertEqual(lessons.workSuggestion()?.days, [F.at(1, 0), F.at(3, 0)])
        XCTAssertNil(lessons.workSuggestion { _ in false }, "Already sorted as something else: nothing to offer")
    }

    func testTheOfferIsMadeOnceAndForTheLatestOne() {
        var lessons = AnalyzerLessons()
        for day in [0, 1] { lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(day, 10), calendar: calendar) }
        for day in [2, 3] { lessons.saidForWork(key: "com.figma", name: "Figma", isSite: false, at: F.at(day, 10), calendar: calendar) }
        XCTAssertEqual(lessons.workSuggestion()?.name, "Figma")
        lessons.settleWork("com.figma")
        XCTAssertEqual(lessons.workSuggestion()?.key, "docs.rs")
        XCTAssertEqual(lessons.countedAsWork, [], "“Keep asking” sorts nothing")
        lessons.settleWork("docs.rs", countedAsWork: true)
        XCTAssertNil(lessons.workSuggestion())
        XCTAssertEqual(lessons.countedAsWork.map(\.key), ["docs.rs"])
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(4, 10), calendar: calendar)
        XCTAssertNil(lessons.workSuggestion(), "Answered: never offered again")
        lessons.saidForWork(key: "", name: "", isSite: false, at: F.at(4, 10), calendar: calendar)
        XCTAssertEqual(lessons.work.count, 2, "Nothing to name: nothing kept")
    }

    func testSaidForWorkOnASecondDayItsDueToCountAsWork() {
        var lessons = AnalyzerLessons()
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(1, 10), calendar: calendar)
        XCTAssertNil(lessons.dueAsWork("docs.rs"), "Once is a one-off")
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(1, 16), calendar: calendar)
        XCTAssertNil(lessons.dueAsWork("docs.rs"), "Twice in a day is still one day")
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(2, 9), calendar: calendar)
        XCTAssertEqual(lessons.dueAsWork("docs.rs")?.days.count, 2)
        XCTAssertNil(lessons.dueAsWork("x.com"))
        lessons.settleWork("docs.rs", countedAsWork: true)
        XCTAssertNil(lessons.dueAsWork("docs.rs"), "Done once")
        XCTAssertEqual(lessons.countedAsWork.map(\.key), ["docs.rs"])
        lessons.uncountWork("docs.rs")
        XCTAssertEqual(lessons.countedAsWork, [])
        lessons.saidForWork(key: "docs.rs", name: "docs.rs", isSite: true, at: F.at(3, 9), calendar: calendar)
        XCTAssertNil(lessons.dueAsWork("docs.rs"), "Put back: never counted on its own again")
    }

    func testLessonsSurviveBeingSavedAndAnOlderStateStillLoads() throws {
        var state = AnalyzerState()
        state.lessons = AnalyzerLessons(fine: ["a>b"], declined: ["c>d"])
        let back = try JSONDecoder().decode(AnalyzerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.lessons, state.lessons)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AnalyzerState())) as? [String: Any])
        older["lessons"] = nil
        let loaded = try JSONDecoder().decode(AnalyzerState.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(loaded.lessons)
    }

    // MARK: - The words

    private func trigger(_ id: String, moments: Int = 0, ruledOut: Int = 0) -> AnalyzerTrigger {
        let list = (0..<moments).map { AnalyzerTrigger.Moment(start: F.at($0, 10), seconds: 300, isRuledOut: $0 < ruledOut) }
        return AnalyzerTrigger(id: id, steps: AnalyzerTriggers.steps(of: id), moments: list, perDay: [], cause: nil)
    }

    func testTheQuestionNamesThePattern() {
        let wait = trigger("wait:Claude Code>x.com", moments: 4, ruledOut: 2)
        XCTAssertEqual(AnalyzerLessonCopy.question(wait), "Is x.com while Claude Code works fine for you?")
        XCTAssertEqual(AnalyzerLessonCopy.yes(wait), "Yes, it’s fine while Claude Code works")
        XCTAssertEqual(AnalyzerLessonCopy.why(wait),
                       "You marked 2 of these as not a distraction. If that’s how you work, say so once and it stops counting here. The card won’t call it a drift while Claude Code works either.")
        let after = trigger("Xcode>youtube.com", moments: 4, ruledOut: 3)
        XCTAssertEqual(AnalyzerLessonCopy.question(after), "Is youtube.com after Xcode fine for you?")
        XCTAssertEqual(AnalyzerLessonCopy.yes(after), "Yes, it’s fine after Xcode")
        XCTAssertTrue(AnalyzerLessonCopy.why(after).hasSuffix("A focus session still catches it: answer “It’s for work” there."))
        let alone = trigger("x.com", moments: 2, ruledOut: 2)
        XCTAssertEqual(AnalyzerLessonCopy.question(alone), "Is x.com fine for you?")
        XCTAssertEqual(AnalyzerLessonCopy.yes(alone), "Yes, it’s fine")
    }

    func testWhatWasTaughtSaysWhatItTookOut() {
        XCTAssertEqual(AnalyzerLessonCopy.taught(trigger("wait:Claude Code>x.com")), "x.com while Claude Code works is fine")
        XCTAssertEqual(AnalyzerLessonCopy.taught(trigger("Xcode>youtube.com")), "youtube.com after Xcode is fine")
        XCTAssertEqual(AnalyzerLessonCopy.taught(trigger("x.com")), "x.com is fine")
        XCTAssertEqual(AnalyzerLessonCopy.took(trigger("wait:Claude Code>x.com", moments: 3)), "Taken out: 3 times, 15m. No drift card for it either.")
        XCTAssertEqual(AnalyzerLessonCopy.took(trigger("Xcode>youtube.com", moments: 1)), "Taken out: once, 5m. A focus session still catches it.")
        XCTAssertEqual(AnalyzerLessonCopy.took(trigger("Xcode>youtube.com")), "It hasn’t come up in the last 4 weeks. A focus session still catches it.")
    }

    func testTheWorkOfferNamesTheDays() {
        let two = AnalyzerLessons.WorkAnswer(key: "docs.rs", name: "docs.rs", isSite: true, days: [F.at(1, 0), F.at(3, 0)])
        XCTAssertEqual(AnalyzerLessonCopy.work(two, calendar: calendar, locale: F.locale),
                       "You said docs.rs was for work on Tuesday and Thursday. Count it as work from now on? It stops being caught, in sessions and here.")
        let weekApart = AnalyzerLessons.WorkAnswer(key: "docs.rs", name: "docs.rs", isSite: true, days: [F.at(1, 0), F.at(8, 0)])
        XCTAssertTrue(AnalyzerLessonCopy.work(weekApart, calendar: calendar, locale: F.locale).hasPrefix("You said docs.rs was for work on 2 days."))
        let three = AnalyzerLessons.WorkAnswer(key: "docs.rs", name: "docs.rs", isSite: true, days: [F.at(0, 0), F.at(1, 0), F.at(3, 0)])
        XCTAssertTrue(AnalyzerLessonCopy.work(three, calendar: calendar, locale: F.locale).hasPrefix("You said docs.rs was for work on 3 days."))
    }

    func testTheCardListsWhatsFineEvenWhenItDidntComeUp() {
        let seen = trigger("Xcode>youtube.com", moments: 2)
        var actions = AnalyzerLessonActions(lessons: AnalyzerLessons(fine: ["Xcode>youtube.com", "wait:Codex>x.com"]))
        XCTAssertEqual(AnalyzerLessonsCard(taught: [seen], actions: actions).rows.map(\.id), ["Xcode>youtube.com", "wait:Codex>x.com"])
        XCTAssertTrue(AnalyzerLessonsCard.isWorthShowing(taught: [], actions: actions))
        actions.lessons = AnalyzerLessons(declined: ["a>b"])
        XCTAssertFalse(AnalyzerLessonsCard.isWorthShowing(taught: [], actions: actions), "Nothing taught, nothing to offer")
        actions.suggestion = .init(key: "docs.rs", name: "docs.rs", isSite: true, days: [])
        XCTAssertTrue(AnalyzerLessonsCard.isWorthShowing(taught: [], actions: actions))
        actions.suggestion = nil
        actions.counted = [.init(key: "docs.rs", name: "docs.rs", isSite: true, days: [], settled: true, countedAsWork: true)]
        XCTAssertTrue(AnalyzerLessonsCard.isWorthShowing(taught: [], actions: actions))
    }
}
