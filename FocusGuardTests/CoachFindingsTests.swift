import XCTest
@testable import FocusGuard

extension CoachFixture {
    /// Time in an app (not a site) outside sessions.
    mutating func app(_ start: Date, minutes: Double, _ kind: Classification, _ bundleId: String, name: String) {
        events.append(CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: kind,
                                 target: bundleId, name: name, isSite: false, session: nil))
    }

    /// Time on a site outside sessions, to the second.
    mutating func site(_ start: Date, seconds: TimeInterval, _ kind: Classification, _ host: String) {
        events.append(CoachEvent(start: start, end: start.addingTimeInterval(seconds), kind: kind,
                                 target: host, name: host, isSite: true, session: nil))
    }

    // MARK: - Weeks with one of the new patterns

    /// Two 50-minute sessions a day with one change of app each; Tuesday's
    /// afternoon sessions change app every 2 minutes.
    static func busyTuesday(everyDay: Bool = false) -> CoachFixture {
        var f = CoachFixture()
        let hopping = (0..<25).map { i -> (Classification, Int, String) in i % 2 == 0 ? (.focus, 2, "xcode") : (.neutral, 2, "slack") }
        for day in 0..<5 {
            f.session(day, 9, 0, [(.focus, 25, "xcode"), (.neutral, 25, "figma")])
            if day == 1 || everyDay {
                f.session(day, 14, 0, hopping)
                f.session(day, 15, 0, hopping)
            } else {
                f.session(day, 14, 0, [(.focus, 25, "xcode"), (.neutral, 25, "figma")])
            }
        }
        return f
    }

    /// Each week, three 25-minute sessions at 92% and two of an hour at 70%.
    static func shortSessionsWin(weeks: Int = 2, from firstWeek: Int = 0, shortDrift: Int = 2) -> CoachFixture {
        var f = CoachFixture()
        for week in firstWeek..<(firstWeek + weeks) {
            for day in 0..<3 { f.session(week * 7 + day, 9, 0, [(.focus, 25 - shortDrift, "a"), (.distraction, shortDrift, "x.com")]) }
            for day in 3..<5 { f.session(week * 7 + day, 14, 0, [(.focus, 42, "a"), (.distraction, 18, "x.com")]) }
        }
        return f
    }

    /// Monday and Tuesday with an hour of focus and then 3½ hours on Zoom;
    /// Wednesday to Friday with 4 hours of focus. Every day starts at 09:00.
    static func callHeavy(heavyFocus: Int = 60) -> CoachFixture {
        var f = CoachFixture()
        for day in 0..<5 {
            if day < 2 {
                f.session(day, 9, 0, [(.focus, heavyFocus, "a")])
                f.app(at(day, 13), minutes: 210, .neutral, "us.zoom.xos", name: "Zoom")
            } else {
                f.session(day, 9, 0, [(.focus, 120, "a")])
                f.session(day, 14, 0, [(.focus, 120, "a")])
            }
        }
        return f
    }

    /// Slack for 10 minutes, then youtube.com for 15, `times` times over the week.
    static func slackToYouTube(times: Int = 6, gap: TimeInterval = 0, from source: Classification = .neutral) -> CoachFixture {
        var f = CoachFixture()
        for i in 0..<times {
            let start = at(i % 5, i < 5 ? 10 : 16)
            f.app(start, minutes: 10, source, "com.tinyspeck.slackmacgap", name: "Slack")
            f.site(start.addingTimeInterval(600 + gap), seconds: 15 * 60, .distraction, "youtube.com")
        }
        return f
    }

    /// Monday to Thursday 4 hours of focus, Friday 1 hour (or `fridayHours`
    /// week by week), for `weeks` weeks.
    static func slowFridays(weeks: Int = 3, from firstWeek: Int = 0, fridayHours: [Int]? = nil) -> CoachFixture {
        var f = CoachFixture()
        for week in 0..<weeks {
            for day in 0..<5 {
                let hours = day == 4 ? (fridayHours?[week] ?? 1) : 4
                f.session((firstWeek + week) * 7 + day, 9, 0, [(.focus, hours * 60, "a")])
            }
        }
        return f
    }
}

/// The five newer weekly-coach patterns: switching a lot, best session
/// length, call-heavy days, one app leading to another, the weekly rhythm.
final class CoachFindingsTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar
    let locale = CoachFixture.locale

    // MARK: - Switching a lot

    func test_switching_findsTheDayThatHoppedBetweenApps() throws {
        guard case .switching(let f)? = CoachPatternFinder.switching(F.busyTuesday().data(), calendar: calendar) else {
            return XCTFail("expected a switching finding")
        }
        XCTAssertEqual(f.day, F.at(1, 0))
        XCTAssertEqual(f.switches, 49)
        XCTAssertEqual(f.minutesPerSwitch, 150.0 / 49, accuracy: 0.01)
        XCTAssertEqual(f.usualMinutesPerSwitch, 50, accuracy: 0.01)
        XCTAssertEqual(f.hours, .afternoon)
        XCTAssertEqual(CoachDraft.headline(for: .switching(f), locale: locale, calendar: calendar),
                       "Tuesday's sessions switched apps every 3 minutes.")
        XCTAssertEqual(CoachPlanner.experiment(for: .switching(f), settings: CoachSettings(preset: .standard)),
                       .stricterPreset(.afternoon, .strict))
        XCTAssertNil(CoachPlanner.experiment(for: .switching(f), settings: CoachSettings(preset: .strict)))
    }

    func test_switching_needsADayWellAboveUsual() {
        XCTAssertNil(CoachPatternFinder.switching(F.busyTuesday(everyDay: true).data(), calendar: calendar))
    }

    func test_switching_needsOtherDaysToCompareWith() {
        var f = F.busyTuesday()
        f.sessions.removeAll { $0.start >= F.at(2, 0) }
        f.events.removeAll { $0.start >= F.at(2, 0) }
        XCTAssertNil(CoachPatternFinder.switching(f.data(), calendar: calendar))
    }

    // MARK: - Best session length

    func test_sessionLength_findsTheLengthThatBeatsLongerOnes() throws {
        guard case .sessionLength(let f)? = CoachPatternFinder.sessionLength(F.shortSessionsWin().data(to: 14), calendar: calendar) else {
            return XCTFail("expected a session-length finding")
        }
        XCTAssertEqual(f.minutes, 25)
        XCTAssertEqual(f.rate, 0.92, accuracy: 0.001)
        XCTAssertEqual(f.sessions, 6)
        XCTAssertEqual(f.longerRate, 0.7, accuracy: 0.001)
        XCTAssertEqual(f.longerSessions, 4)
        XCTAssertEqual(f.weeks, 2)
        XCTAssertEqual(CoachDraft.headline(for: .sessionLength(f), locale: locale, calendar: calendar),
                       "Your 25-minute sessions went best: 92%, against 70% for longer ones.")
        XCTAssertEqual(CoachPlanner.experiment(for: .sessionLength(f), settings: CoachSettings(sessionMinutes: 50)),
                       .sessionLength(minutes: 25))
        XCTAssertNil(CoachPlanner.experiment(for: .sessionLength(f), settings: CoachSettings(sessionMinutes: 25)))
    }

    func test_sessionLength_needsTwoWeeks() {
        XCTAssertNil(CoachPatternFinder.sessionLength(F.shortSessionsWin(weeks: 1).data(), calendar: calendar))
        // `find` looks at the longer history for it, not just the week.
        let history = F.shortSessionsWin().data(to: 14)
        let lastWeek = history.clipped(to: DateInterval(start: F.at(7, 0), end: F.at(14, 0)))
        let isLength = { (finding: CoachFinding) -> Bool in
            if case .sessionLength = finding { return true } else { return false }
        }
        XCTAssertFalse(CoachPatternFinder.find(in: lastWeek, calendar: calendar).contains(where: isLength))
        XCTAssertTrue(CoachPatternFinder.find(in: lastWeek, history: history, calendar: calendar).contains(where: isLength))
    }

    func test_sessionLength_needsAClearGap() {
        // 25-minute sessions at 80% against hour-long ones at 70%.
        XCTAssertNil(CoachPatternFinder.sessionLength(F.shortSessionsWin(shortDrift: 5).data(to: 14), calendar: calendar))
    }

    // MARK: - Meeting-heavy days

    func test_meetingDays_comparesCallHeavyDaysWithTheRest() throws {
        guard case .meetingDays(let f)? = CoachPatternFinder.meetingDays(F.callHeavy().data(), calendar: calendar) else {
            return XCTFail("expected a meeting-days finding")
        }
        XCTAssertEqual(f.heavyDays, 2)
        XCTAssertEqual(f.otherDays, 3)
        XCTAssertEqual(f.heavyFocus, 3600, accuracy: 1)
        XCTAssertEqual(f.otherFocus, 4 * 3600, accuracy: 1)
        XCTAssertEqual(CoachDraft.headline(for: .meetingDays(f), locale: locale, calendar: calendar),
                       "Days with 3 hours of calls kept 25% of your usual focus.")
        XCTAssertEqual(CoachPlanner.experiment(for: .meetingDays(f), settings: CoachSettings(canReadCalendar: true)),
                       .sessionBeforeFirstCall(minutes: 25))
        // The morning plan needs the calendar to know when the first call is, and has to be on.
        XCTAssertNil(CoachPlanner.experiment(for: .meetingDays(f), settings: CoachSettings(canReadCalendar: false)))
        XCTAssertNil(CoachPlanner.experiment(for: .meetingDays(f), settings: CoachSettings(canReadCalendar: true, morningPlanOn: false)))
    }

    func test_meetingDays_countsTheCalendarsBusyTimes() {
        var f = CoachFixture()
        for day in 0..<5 {
            f.session(day, day < 2 ? 15 : 9, 0, [(.focus, day < 2 ? 60 : 240, "a")])
        }
        var data = f.data()
        data.busy = [DateInterval(start: F.at(0, 9), end: F.at(0, 12, 30)), DateInterval(start: F.at(1, 9), end: F.at(1, 13))]
        guard case .meetingDays(let finding)? = CoachPatternFinder.meetingDays(data, calendar: calendar) else {
            return XCTFail("expected a meeting-days finding")
        }
        XCTAssertEqual(finding.heavyDays, 2)
    }

    func test_callTime_countsOverlapsOnce() {
        var f = CoachFixture()
        f.app(F.at(0, 10), minutes: 120, .neutral, "us.zoom.xos", name: "Zoom")
        f.site(F.at(0, 14), seconds: 1800, .neutral, "meet.google.com")
        f.loose(F.at(0, 16), minutes: 60, .focus, "a")
        var data = f.data()
        data.busy = [DateInterval(start: F.at(0, 11), end: F.at(0, 13))]
        XCTAssertEqual(data.callSecondsByDay(calendar: calendar)[F.at(0, 0)] ?? 0, 3.5 * 3600, accuracy: 1)
    }

    func test_meetingDays_needsTheGapToBeClear() {
        XCTAssertNil(CoachPatternFinder.meetingDays(F.callHeavy(heavyFocus: 220).data(), calendar: calendar))
    }

    // MARK: - One app leads to another

    func test_appChain_findsTheAppThatOpensTheDistraction() throws {
        guard case .appChain(let f)? = CoachPatternFinder.appChain(F.slackToYouTube().data(), calendar: calendar) else {
            return XCTFail("expected an app-chain finding")
        }
        XCTAssertEqual(f.source, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(f.sourceName, "Slack")
        XCTAssertEqual(f.target, "youtube.com")
        XCTAssertEqual(f.count, 6)
        XCTAssertEqual(f.dailySeconds, 18 * 60, accuracy: 1)
        XCTAssertEqual(CoachDraft.headline(for: .appChain(f), locale: locale, calendar: calendar),
                       "Slack led straight to youtube.com 6 times.")
        XCTAssertEqual(CoachPlanner.experiment(for: .appChain(f), settings: CoachSettings()),
                       .siteLimit(host: "youtube.com", minutes: 10))
    }

    func test_appChain_looksPastAQuickRedirect() throws {
        var f = CoachFixture()
        for i in 0..<5 {
            let start = F.at(i, 10)
            f.app(start, minutes: 10, .neutral, "com.tinyspeck.slackmacgap", name: "Slack")
            f.site(start.addingTimeInterval(600), seconds: 4, .neutral, "slack-redir.net")
            f.site(start.addingTimeInterval(604), seconds: 900, .distraction, "youtube.com")
        }
        guard case .appChain(let chain)? = CoachPatternFinder.appChain(f.data(), calendar: calendar) else {
            return XCTFail("expected an app-chain finding")
        }
        XCTAssertEqual(chain.count, 5)
    }

    func test_appChain_needsFiveTimes_rightAway_fromANeutralApp() {
        XCTAssertNil(CoachPatternFinder.appChain(F.slackToYouTube(times: 4).data(), calendar: calendar))
        XCTAssertNil(CoachPatternFinder.appChain(F.slackToYouTube(gap: 120).data(), calendar: calendar))
        // A focus app drifting is the time-of-day pattern's business.
        XCTAssertNil(CoachPatternFinder.appChain(F.slackToYouTube(from: .focus).data(), calendar: calendar))
    }

    func test_appChain_toAnApp_hasNoExperiment() {
        let finding = CoachFinding.appChain(.init(source: "com.tinyspeck.slackmacgap", sourceName: "Slack",
                                                  target: "com.valvesoftware.steam", name: "Steam", isSite: false,
                                                  count: 6, dailySeconds: 3600))
        XCTAssertNil(CoachPlanner.experiment(for: finding, settings: CoachSettings()))
    }

    // MARK: - Weekly rhythm

    func test_weeklyRhythm_findsTheWeekdayThatKeepsComingInLow() throws {
        guard case .weeklyRhythm(let f)? = CoachPatternFinder.weeklyRhythm(F.slowFridays().data(to: 21), calendar: calendar) else {
            return XCTFail("expected a weekly-rhythm finding")
        }
        XCTAssertEqual(f.weekday, 6)
        XCTAssertEqual(f.weeks, 3)
        XCTAssertEqual(f.focus, 3600, accuracy: 1)
        XCTAssertEqual(f.othersFocus, 4 * 3600, accuracy: 1)
        XCTAssertEqual(CoachDraft.headline(for: .weeklyRhythm(f), locale: locale, calendar: calendar),
                       "Fridays have been your weakest day three weeks running.")
        XCTAssertEqual(CoachPlanner.experiment(for: .weeklyRhythm(f), settings: CoachSettings(dailyGoal: 240)),
                       .weekdayGoal(weekday: 6, minutes: 60))
        // Already that low: nothing to try.
        XCTAssertNil(CoachPlanner.experiment(for: .weeklyRhythm(f), settings: CoachSettings(dailyGoal: 240, weekdayGoals: [6: 60])))
    }

    func test_weeklyRhythm_needsThreeWeeksRunning() {
        XCTAssertNil(CoachPatternFinder.weeklyRhythm(F.slowFridays(weeks: 2).data(to: 14), calendar: calendar))
        XCTAssertNil(CoachPatternFinder.weeklyRhythm(F.slowFridays(fridayHours: [1, 1, 4]).data(to: 21), calendar: calendar))
    }

    func test_weekdayGoal_isAboutWhatTheDayManages() {
        XCTAssertEqual(CoachPlanner.weekdayGoal(focus: 100 * 60), 105)
        XCTAssertEqual(CoachPlanner.weekdayGoal(focus: 10 * 60), 30)
    }

    // MARK: - Ranking and history

    func test_findLooksAtTheLongerHistoryForRhythm() {
        let history = F.slowFridays().data(to: 21)
        let lastWeek = history.clipped(to: DateInterval(start: F.at(14, 0), end: F.at(21, 0)))
        let findings = CoachPatternFinder.find(in: lastWeek, history: history, calendar: calendar)
        XCTAssertTrue(findings.contains { if case .weeklyRhythm = $0 { return true } else { return false } })
        XCTAssertTrue(findings.allSatisfy { (0...1).contains($0.strength) })
    }

    // MARK: - Experiments

    func test_newExperimentsWords() {
        XCTAssertEqual(CoachExperiment.sessionLength(minutes: 40).title(), "40 minutes as your session length")
        XCTAssertEqual(CoachExperiment.sessionBeforeFirstCall(minutes: 25).title(), "A 25-minute session before your first call")
        XCTAssertEqual(CoachExperiment.weekdayGoal(weekday: 6, minutes: 120).title(locale: locale, calendar: calendar),
                       "A 2-hour goal on Fridays")
        XCTAssertEqual(CoachExperiment.weekdayGoal(weekday: 6, minutes: 90).title(locale: locale, calendar: calendar),
                       "A 1h 30m goal on Fridays")
        XCTAssertEqual(CoachExperiment.weekdayGoal(weekday: 6, minutes: 90).effect(locale: locale, calendar: calendar),
                       "The goal on Fridays is 1h 30m.")
        XCTAssertEqual(CoachExperiment.sessionLength(minutes: 40).shortName(), "40-minute sessions")
        for experiment in [CoachExperiment.sessionLength(minutes: 40), .sessionBeforeFirstCall(minutes: 25),
                           .weekdayGoal(weekday: 6, minutes: 120)] {
            XCTAssertFalse(CoachDraft.why(for: experiment, finding: nil, locale: locale, calendar: calendar).isEmpty)
        }
    }

    func test_newExperimentsOverlap() {
        XCTAssertTrue(CoachExperiment.sessionLength(minutes: 40).overlaps(.shorterSessions(.evening, minutes: 25)))
        XCTAssertTrue(CoachExperiment.shorterSessions(.evening, minutes: 25).overlaps(.sessionLength(minutes: 40)))
        XCTAssertTrue(CoachExperiment.weekdayGoal(weekday: 6, minutes: 60).overlaps(.weekdayGoal(weekday: 6, minutes: 90)))
        XCTAssertFalse(CoachExperiment.weekdayGoal(weekday: 6, minutes: 60).overlaps(.weekdayGoal(weekday: 2, minutes: 60)))
        XCTAssertFalse(CoachExperiment.sessionBeforeFirstCall(minutes: 25).overlaps(.earlierMorningPlan(hour: 8)))
    }

    func test_newMetrics() {
        XCTAssertEqual(CoachMetric.callDayFocus.measure(F.callHeavy().data(), calendar: calendar) ?? 0, 3600, accuracy: 1)
        XCTAssertNil(CoachMetric.callDayFocus.measure(F.slowFridays(weeks: 1).data(), calendar: calendar))
        XCTAssertEqual(CoachMetric.weekdayFocus(6).measure(F.slowFridays().data(to: 21), calendar: calendar) ?? 0, 3600, accuracy: 1)
        // 153 focused minutes and 42 drifted, over five sessions.
        let allDay: Double = 153.0 / 195.0
        XCTAssertEqual(CoachMetric.sessionRate(.allDay).measure(F.shortSessionsWin(weeks: 1).data(), calendar: calendar) ?? 0,
                       allDay, accuracy: 0.001)
        XCTAssertEqual(CoachMetric.callDayFocus.change(from: 3600, to: 5400), "1h → 1h 30m focused on call-heavy days")
        XCTAssertTrue(CoachMetric.weekdayFocus(6).change(from: 3600, to: 7200).hasPrefix("1h → 2h focused on "))
        XCTAssertTrue(CoachMetric.callDayFocus.improved(from: 3600, to: 5400))
        XCTAssertFalse(CoachMetric.weekdayFocus(6).improved(from: 3600, to: 1800))
    }

    func test_newDraftsSayOnlyWhatTheNumbersSay() throws {
        let rhythm = try XCTUnwrap(CoachPatternFinder.weeklyRhythm(F.slowFridays().data(to: 21), calendar: calendar))
        let draft = CoachDraft.make(rhythm, experiment: .weekdayGoal(weekday: 6, minutes: 60), locale: locale, calendar: calendar)
        XCTAssertEqual(draft.points.map(\.sentence), [
            "Fridays: 1h focused on average, the lowest of each of the last 3 weeks.",
            "Your other days: 4h on average.",
        ])
        XCTAssertTrue(draft.facts.last?.hasPrefix("Suggested experiment: A 1-hour goal on Fridays.") == true)

        let chain = try XCTUnwrap(CoachPatternFinder.appChain(F.slackToYouTube().data(), calendar: calendar))
        XCTAssertEqual(CoachDraft.points(for: chain, locale: locale, calendar: calendar).map(\.sentence), [
            "From Slack to youtube.com within seconds, 6 times last week.",
            "About 18 min a day on youtube.com last week.",
        ])
    }
}
