import XCTest
@testable import FocusGuard

/// The rules behind the coach, the month review, the evening tip, session
/// names and the timesheet: nothing claimed from trivial data, ties aren't
/// "weakest", and advice that fits why the numbers look as they do.
final class CoachFairnessTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar
    let locale = CoachFixture.locale

    // MARK: - Minimum evidence

    func test_timeOfDay_notFromFourShortSessions() {
        var f = CoachFixture()
        for day in [0, 1] {
            f.session(day, 9, 0, [(.focus, 15, "xcode")])
            f.session(day, 18, 0, [(.focus, 9, "xcode"), (.distraction, 6, "x.com")])
        }
        XCTAssertNil(CoachPatternFinder.timeOfDay(f.data(), calendar: calendar))
    }

    func test_afterSessions_aGlanceIsntReachingForIt() {
        var f = CoachFixture()
        for day in 0..<5 {
            let s = f.session(day, 10, 0, [(.focus, 50, "xcode")])
            f.events.append(CoachEvent(start: s.end.addingTimeInterval(30), end: s.end.addingTimeInterval(45), kind: .distraction,
                                       target: "x.com", name: "x.com", isSite: true, session: nil))
        }
        XCTAssertNil(CoachPatternFinder.afterSessions(f.data(), calendar: calendar))
    }

    func test_switching_betweenTwoFocusAppsIsJustWork() {
        var f = CoachFixture()
        let hopping = (0..<30).map { i -> (Classification, Int, String) in (.focus, 2, i % 2 == 0 ? "xcode" : "terminal") }
        for day in [0, 1, 3, 4] { f.session(day, 9, 0, [(.focus, 60, "xcode"), (.focus, 60, "terminal")]) }
        f.session(2, 9, 0, hopping)
        XCTAssertNil(CoachPatternFinder.switching(f.data(), calendar: calendar))
    }

    func test_switching_withNoChangesElsewhereSaysSoRatherThanARate() throws {
        var f = CoachFixture()
        let hopping = (0..<30).map { i -> (Classification, Int, String) in i % 2 == 0 ? (.focus, 2, "xcode") : (.distraction, 2, "x.com") }
        for day in [0, 1, 3, 4] { f.session(day, 9, 0, [(.focus, 120, "xcode")]) }
        f.session(2, 9, 0, hopping)
        guard case .switching(let finding)? = CoachPatternFinder.switching(f.data(), calendar: calendar) else {
            return XCTFail("expected a switching finding")
        }
        XCTAssertTrue(finding.noneOnOtherDays)
        let points = CoachDraft.points(for: .switching(finding), locale: locale, calendar: calendar).map(\.sentence)
        XCTAssertTrue(points.contains("Other days: no changes like these."), "\(points)")
    }

    // MARK: - Ties

    func test_weeklyRhythm_aTieIsntTheWeakest() {
        var f = CoachFixture()
        for week in 0..<3 {
            for day in 0..<5 {
                let low = day < 3
                f.session(week * 7 + day, 9, 0, [(.focus, low ? 55 : 300, "xcode")])
            }
        }
        XCTAssertNil(CoachPatternFinder.weeklyRhythm(f.data(from: 0, to: 21), calendar: calendar))
    }

    // MARK: - The best length

    func test_sessionLength_theBestLengthReallyIsBest() {
        var f = CoachFixture()
        for day in [0, 1, 2, 7, 8] {
            f.session(day, 8, 0, [(.focus, 20, "xcode"), (.distraction, 5, "x.com")])
            f.session(day, 9, 0, [(.focus, 32, "xcode"), (.distraction, 3, "x.com")])
            f.session(day, 10, 0, [(.focus, 18, "xcode"), (.distraction, 27, "x.com")])
            f.session(day, 11, 0, [(.focus, 51, "xcode"), (.distraction, 9, "x.com")])
        }
        // 35 minutes went best (91%), and nothing that much longer did worse.
        XCTAssertNil(CoachPatternFinder.sessionLength(f.data(from: 0, to: 14), calendar: calendar))
    }

    // MARK: - Calls

    func test_lateStarts_aMorningOfCallsIsntALateStart() {
        var f = CoachFixture()
        for day in [0, 1, 2] {
            f.events.append(CoachEvent(start: F.at(day, 10), end: F.at(day, 14), kind: .neutral, target: "us.zoom.xos", name: "zoom.us",
                                       isSite: false, session: nil))
            f.session(day, 14, 0, [(.focus, 55, "xcode")])
        }
        for day in [3, 4] {
            f.session(day, 9, 0, [(.focus, 300, "xcode")])
        }
        XCTAssertNil(CoachPatternFinder.lateStarts(f.data(), calendar: calendar))
    }

    func test_lateStarts_stillFindsARealLateStart() {
        XCTAssertNotNil(CoachPatternFinder.lateStarts(F.lateStarts().data(), calendar: calendar))
    }

    // MARK: - No pattern

    private func headline(focus: Double, drift: Double) -> String {
        CoachDraft.make(nil, experiment: nil, week: (focus * 3600, drift * 3600), locale: locale, calendar: calendar).headline
    }

    func test_steadyIsOnlyForAWeekThatWentWell() {
        XCTAssertEqual(headline(focus: 30, drift: 1), "A steady week, with nothing that stood out.")
        XCTAssertEqual(headline(focus: 5, drift: 20), "No one pattern stood out, but your focus rate was only 20%.")
        XCTAssertEqual(headline(focus: 7, drift: 3), "No pattern stood out last week.")
        XCTAssertEqual(headline(focus: 0.2, drift: 0), "Too little tracked last week to see a pattern.")
    }

    // MARK: - The guard on the model's words

    func test_accept_turnsDownWordsThatChangeTheMeaning() {
        let facts = ["October: 82h 30m focused at a 75% focus rate, 5 points up on September.", "Afternoons slipped."]
        for reply in ["Focus rose, afternoons declined slightly.", "Focused for eighty-two hours at a good rate.",
                      "Other days average two meters of drift.", "On Tuesdays your focus rate was 75%.", "Because of calls, your rate was 75%."] {
            XCTAssertNil(CoachWriter.accept(reply, allowed: facts, maxLength: 200), reply)
        }
        XCTAssertNotNil(CoachWriter.accept("Your October ran at a 75% focus rate.", allowed: facts, maxLength: 200))
    }

    func test_accept_aHeadlineKeepsItsFigures() {
        let facts = ["October: 82h 30m focused at a 75% focus rate."]
        let keep: Set<String> = ["82", "30", "75"]
        XCTAssertNil(CoachWriter.accept("Your October went fine overall.", allowed: facts, maxLength: 200, mustKeep: keep))
        XCTAssertNotNil(CoachWriter.accept("Your October: 82h 30m at a 75% focus rate.", allowed: facts, maxLength: 200, mustKeep: keep))
    }

    // MARK: - Months

    /// `count` working days from `start`, each 240 focused and 60 drifted.
    private func month(_ interval: DateInterval, days count: Int) -> CoachData {
        var events: [CoachEvent] = []
        var sessions: [CoachSession] = []
        for index in 0..<count {
            let day = interval.start.addingTimeInterval(TimeInterval(index) * 86_400)
            let id = UUID()
            let start = day.addingTimeInterval(9 * 3600), mid = start.addingTimeInterval(240 * 60), end = mid.addingTimeInterval(60 * 60)
            events.append(CoachEvent(start: start, end: mid, kind: .focus, target: "xcode", name: "Xcode", isSite: false, session: id))
            events.append(CoachEvent(start: mid, end: end, kind: .distraction, target: "youtube.com", name: "youtube.com", isSite: true, session: id))
            sessions.append(CoachSession(id: id, start: start, end: end, plannedMinutes: 300))
        }
        return CoachData(interval: interval, events: events, sessions: sessions)
    }

    private let october = DateInterval(start: EvalDate.utc(2026, 10, 1), end: EvalDate.utc(2026, 11, 1))
    private let september = DateInterval(start: EvalDate.utc(2026, 9, 1), end: EvalDate.utc(2026, 10, 1))

    func test_month_twoDaysDontStandForAMonth() throws {
        let facts = try XCTUnwrap(MonthFacts.make(month(october, days: 22), before: month(september, days: 2), locale: locale, calendar: calendar))
        XCTAssertEqual(facts.headline, "October: 88h focused at an 80% focus rate.")
        XCTAssertFalse(facts.changes.map(\.sentence).contains { $0.contains("September") }, "\(facts.changes)")
    }

    func test_month_aShorterMonthWithTheSameDaysIsntLessFocus() throws {
        let facts = try XCTUnwrap(MonthFacts.make(month(october, days: 20), before: month(september, days: 22), locale: locale, calendar: calendar))
        XCTAssertEqual(facts.headline, "October: 80h focused at an 80% focus rate, level with September.")
        XCTAssertFalse(facts.changes.map(\.sentence).contains { $0.contains("Less focus") }, "\(facts.changes)")
    }

    func test_month_moreFocusEachDayIsMoreFocus() throws {
        var fuller = month(october, days: 22)
        let extra = fuller.events.filter { $0.kind == .focus }.map {
            CoachEvent(start: $0.start.addingTimeInterval(8 * 3600), end: $0.end.addingTimeInterval(8 * 3600), kind: .focus,
                       target: "xcode", name: "Xcode", isSite: false, session: nil)
        }
        fuller = CoachData(interval: fuller.interval, events: fuller.events + extra, sessions: fuller.sessions)
        let facts = try XCTUnwrap(MonthFacts.make(fuller, before: month(september, days: 22), locale: locale, calendar: calendar))
        XCTAssertTrue(facts.changes.map(\.sentence).contains { $0.hasPrefix("More focus overall.") }, "\(facts.changes)")
    }

    // MARK: - The evening tip

    private func tip(today: CoachData, gap: Int, now: Date = F.at(0, 21), weekendsCount: Bool = false, shown: Set<String> = [],
                     tomorrowStart: Date? = nil) -> EveningTip? {
        EveningTip.choose(today: today, recent: today, gapMinutes: gap, tomorrowStart: tomorrowStart, sessionMinutes: 50, morningHour: 9,
                          now: now, weekendsCount: weekendsCount, shown: shown, locale: locale, calendar: calendar)
    }

    func test_tip_namesTheHourTheDriftWasIn() {
        var f = CoachFixture()
        f.session(0, 10, 0, [(.focus, 120, "xcode")])
        f.loose(F.at(0, 9), minutes: 15, .distraction, "x.com")
        f.loose(F.at(0, 12), minutes: 14, .distraction, "reddit.com")
        f.loose(F.at(0, 16), minutes: 14, .distraction, "reddit.com")
        XCTAssertNil(tip(today: f.data(from: 0, to: 1), gap: 40), "reddit.com wasn't at 09:00, and no two hours hold enough of anything")
    }

    func test_tip_mostMeansMore_thanHalf() throws {
        var f = CoachFixture()
        f.session(0, 9, 0, [(.focus, 100, "xcode")])
        f.loose(F.at(0, 15), minutes: 40, .distraction, "youtube.com")
        let exactlyHalf = try XCTUnwrap(tip(today: f.data(from: 0, to: 1), gap: 80))
        XCTAssertTrue(exactlyHalf.text.hasPrefix("youtube.com took 40 minutes"), exactlyHalf.text)
        let most = try XCTUnwrap(tip(today: f.data(from: 0, to: 1), gap: 60))
        XCTAssertTrue(most.text.hasPrefix("Most of the gap"), most.text)
    }

    func test_tip_notForTheEveningAfterWorkEnded() {
        var f = CoachFixture()
        f.session(0, 9, 0, [(.focus, 210, "xcode")])
        f.loose(F.at(0, 18), minutes: 60, .distraction, "youtube.com")
        XCTAssertNil(tip(today: f.data(from: 0, to: 1), gap: 30))
    }

    func test_tip_noPlanForAWeekend() {
        var f = CoachFixture()
        f.session(4, 9, 0, [(.focus, 100, "xcode")])
        f.loose(F.at(4, 15), minutes: 40, .distraction, "youtube.com")
        let friday = f.data(from: 4, to: 5)
        XCTAssertNil(tip(today: friday, gap: 60, now: F.at(4, 21)))
        XCTAssertNotNil(tip(today: friday, gap: 60, now: F.at(4, 21), weekendsCount: true))
    }

    func test_tip_notTheSameEveryEvening() throws {
        var f = CoachFixture()
        f.session(0, 9, 0, [(.focus, 100, "xcode")])
        f.loose(F.at(0, 15), minutes: 40, .distraction, "youtube.com")
        let today = f.data(from: 0, to: 1)
        let first = try XCTUnwrap(tip(today: today, gap: 60, tomorrowStart: F.at(1, 10)))
        XCTAssertEqual(first.kind, .driftHour)
        let next = try XCTUnwrap(tip(today: today, gap: 60, shown: [first.topic], tomorrowStart: F.at(1, 10)))
        XCTAssertEqual(next.kind, .bestStart)
        XCTAssertNil(tip(today: today, gap: 60, shown: [first.topic, next.topic], tomorrowStart: F.at(1, 10)))
    }

    func test_tipMemory_forgetsAfterAFewEvenings() throws {
        let suite = "CoachFairnessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tip = EveningTip(kind: .bestStart, text: "x", slot: F.at(1, 10), button: "y", topic: "start|10")
        EveningTipMemory.remember(tip, defaults, now: F.at(0, 21))
        XCTAssertEqual(EveningTipMemory.recent(defaults, now: F.at(2, 21)), ["start|10"])
        XCTAssertEqual(EveningTipMemory.recent(defaults, now: F.at(4, 21)), [])
    }

    // MARK: - Session names

    private typealias S = SessionTimeline.Segment

    private func name(focus: Double, drift: Double = 0, neutral: Double = 0, running: Double? = nil) -> String {
        let segments = [S(classification: .focus, seconds: focus * 60), S(classification: .distraction, seconds: drift * 60),
                        S(classification: .neutral, seconds: neutral * 60)]
        return SessionNamer.name(segments: segments, runningSeconds: (running ?? focus + drift + neutral) * 60)
    }

    func test_names_lockedInTakesFocus() {
        XCTAssertEqual(name(focus: 1, neutral: 59), "Quiet Deep Dive")
        XCTAssertEqual(name(focus: 5, neutral: 115), "Quiet Marathon")
        XCTAssertEqual(name(focus: 3, drift: 1, neutral: 56), "Quiet Deep Dive")
        XCTAssertEqual(name(focus: 1, running: 120), "Quiet Marathon")
        XCTAssertEqual(name(focus: 50), "Locked-in Deep Dive")
        XCTAssertEqual(name(focus: 30, neutral: 20), "Locked-in Deep Dive", "a real stretch of focus beside some neutral time")
    }

    // MARK: - The timesheet

    func test_timesheet_aSessionAcrossMidnightCountsOnBothDays() {
        let monday = F.at(0, 0)
        let week = DateInterval(start: monday, duration: 7 * 86_400)
        let start = F.at(1, 23), end = F.at(2, 1)
        let facts = DebriefFacts.make(goal: "Night push", start: start, end: end, events: [
            DebriefFacts.Event(start: start, end: end.addingTimeInterval(-1), bundleId: "x", appName: "Xcode", title: nil, url: nil, classification: .focus),
        ], isOptedOut: { _ in false })
        let input = WorkLogBuilder.Input(id: UUID(), start: start, end: end, name: "S", goal: "Night push", verdict: nil, project: "Alpha", stored: nil, facts: facts)
        let sheet = WorkLogBuilder.build([input], interval: week, now: F.at(2, 20), calendar: calendar).timesheet
        let row = sheet.rows.first { $0.project == "Alpha" }
        XCTAssertEqual(row?.seconds[1] ?? 0, 3600, accuracy: 2)
        XCTAssertEqual(row?.seconds[2] ?? 0, 3600, accuracy: 2)
        XCTAssertEqual(sheet.total, 7200, accuracy: 2)
    }
}

private enum EvalDate {
    static func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        CoachFixture.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }
}
