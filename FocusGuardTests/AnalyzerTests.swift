import SwiftData
import XCTest
@testable import FocusGuard

/// The rules behind the Analyzer: hand-worked days, causes that don't
/// double-count, nothing named on thin evidence, and experiments that apply,
/// undo and judge by rule.
@MainActor
final class AnalyzerTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar
    private static let zoom = "us.zoom.xos"
    private static let slack = "com.tinyspeck.slackmacgap"

    /// `minutes` of one thing from `h:m` on `day`.
    private func event(_ day: Int, _ h: Int, _ m: Int, _ minutes: Double, _ kind: Classification, _ target: String,
                       session: UUID? = nil, bundleId: String? = nil) -> CoachEvent {
        let start = F.at(day, h, m)
        return CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: kind, target: target, name: target,
                          isSite: target.contains(".") && !target.hasPrefix("com.") && !target.hasPrefix("us."), session: session,
                          bundleId: bundleId)
    }

    /// The same, from a minute that may be a half: 9:30:30 is `9, 30.5`.
    private func event(_ day: Int, _ h: Int, _ m: Double, _ minutes: Double, _ kind: Classification, _ target: String) -> CoachEvent {
        let start = F.at(day, h).addingTimeInterval(m * 60)
        return CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: kind, target: target, name: target,
                          isSite: false, session: nil)
    }

    private func make(_ day: Int, _ events: [CoachEvent], busy: [DateInterval] = [], sessions: [CoachSession] = []) -> AnalyzerDay {
        AnalyzerDayBuilder.make(day: F.at(day, 0), events: events, sessions: sessions, busy: busy, calendar: calendar)
    }

    // MARK: - Measures

    func test_longestStretch_aBreakWithinTheGraceDoesntEndIt() {
        // 30 min, a 30 s glance, 9.5 min: 39.5 focused; then a real break, 15 more.
        let day = make(0, [
            event(0, 9, 0, 30, .focus, "xcode"),
            event(0, 9, 30, 0.5, .neutral, "finder"),
            event(0, 9, 30.5, 9.5, .focus, "xcode"),
            event(0, 9, 40, 5, .distraction, "x.com"),
            event(0, 9, 45, 15, .focus, "xcode"),
        ])
        XCTAssertEqual(day.longest, 39.5 * 60, accuracy: 0.5)
        XCTAssertEqual(day.deepBlocks, 1)
    }

    func test_longestStretch_aBreakOverTheGraceEndsIt() {
        let day = make(0, [
            event(0, 9, 0, 20, .focus, "xcode"),
            event(0, 9, 20, 1.5, .neutral, "finder"),
            event(0, 9, 21.5, 20, .focus, "xcode"),
        ])
        XCTAssertEqual(day.longest, 20 * 60, accuracy: 0.5)
        XCTAssertEqual(day.deepBlocks, 0)
    }

    func test_deepBlock_startsAt25Minutes() {
        XCTAssertEqual(make(0, [event(0, 9, 0, 25, .focus, "xcode")]).deepBlocks, 1)
        XCTAssertEqual(make(0, [event(0, 9, 0, 24.9, .focus, "xcode")]).deepBlocks, 0)
    }

    func test_calls_areLeftOutOfFocus_evenClassifiedAsFocus_andEndAStretch() {
        let day = make(0, [
            event(0, 9, 0, 20, .focus, "xcode"),
            event(0, 9, 20, 40, .focus, Self.zoom),
            event(0, 10, 0, 20, .focus, "xcode"),
        ])
        XCTAssertEqual(day.longest, 20 * 60)
        XCTAssertEqual(day.focused, 40 * 60)
        XCTAssertEqual(day.callSeconds, 40 * 60)
        XCTAssertTrue(day.returns.isEmpty, "a call isn't a return")
        XCTAssertTrue(day.losses.isEmpty, "a call isn't lost focus")
    }

    func test_midnight_cutsAStretch_eachDayKeepsItsOwnPart_andCarryingOverIsntAStart() {
        let events = [event(0, 23, 40, 40, .focus, "xcode")]
        let monday = make(0, events), tuesday = make(1, events)
        XCTAssertEqual(monday.longest, 20 * 60)
        XCTAssertEqual(tuesday.longest, 20 * 60)
        XCTAssertEqual(monday.tracked + tuesday.tracked, 40 * 60)
        XCTAssertEqual(monday.gettingStarted, 0)
        XCTAssertNil(tuesday.gettingStarted)
    }

    func test_clocksGoingBack_stretchIsRealTime() throws {
        // Berlin, 25 Oct 2026: 03:00 goes back to 02:00, a 25-hour day.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let day = berlin.startOfDay(for: try XCTUnwrap(berlin.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))))
        XCTAssertEqual(berlin.startOfDay(1, from: day).timeIntervalSince(day), 25 * 3600)
        let start = day.addingTimeInterval(1.5 * 3600)
        let event = CoachEvent(start: start, end: start.addingTimeInterval(2 * 3600), kind: .focus, target: "xcode",
                               name: "Xcode", isSite: false, session: nil)
        // Late that evening, in the day's 25th hour.
        let late = day.addingTimeInterval(24.5 * 3600)
        let lateEvent = CoachEvent(start: late, end: late.addingTimeInterval(30 * 60), kind: .focus, target: "xcode",
                                   name: "Xcode", isSite: false, session: nil)
        let summary = AnalyzerDayBuilder.make(day: day, events: [event, lateEvent], calendar: berlin)
        XCTAssertEqual(summary.longest, 2 * 3600)
        XCTAssertEqual(summary.tracked, 2.5 * 3600, "the 25th hour still belongs to the day")
    }

    func test_clocksGoingForward_dayIs23Hours() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let day = berlin.startOfDay(for: try XCTUnwrap(berlin.date(from: DateComponents(year: 2027, month: 3, day: 28, hour: 12))))
        XCTAssertEqual(berlin.startOfDay(1, from: day).timeIntervalSince(day), 23 * 3600)
        let late = day.addingTimeInterval(22.5 * 3600)
        let event = CoachEvent(start: late, end: late.addingTimeInterval(3600), kind: .focus, target: "xcode", name: "Xcode",
                               isSite: false, session: nil)
        XCTAssertEqual(AnalyzerDayBuilder.make(day: day, events: [event], calendar: berlin).tracked, 30 * 60, "cut at the next midnight")
    }

    func test_emptyDay_isNothing() {
        let day = make(0, [])
        XCTAssertEqual(day.tracked, 0)
        XCTAssertFalse(day.isWorking(weekendsCount: true, calendar: calendar))
        let measures = AnalyzerMeasures.make([])
        XCTAssertEqual(measures.days, 0)
        XCTAssertNil(measures.longest)
        XCTAssertNil(measures.comingBack)
        XCTAssertNil(measures.gettingStarted)
    }

    func test_comingBack_countsDriftsNotCallsOrTimeAway() {
        let drift = make(0, [
            event(0, 9, 0, 30, .focus, "xcode"),
            event(0, 9, 30, 10, .distraction, "x.com"),
            event(0, 9, 40, 30, .focus, "xcode"),
        ])
        XCTAssertEqual(drift.returns, [600])

        let call = make(0, [
            event(0, 9, 0, 30, .focus, "xcode"),
            event(0, 9, 30, 10, .neutral, Self.zoom),
            event(0, 9, 40, 30, .focus, "xcode"),
        ])
        XCTAssertTrue(call.returns.isEmpty)

        // Nothing tracked for 5 minutes or more: away from the Mac.
        let away = make(0, [
            event(0, 9, 0, 30, .focus, "xcode"),
            event(0, 9, 45, 30, .focus, "xcode"),
        ])
        XCTAssertTrue(away.returns.isEmpty)

        // Under Pick up's 2-minute drift: no return.
        let glance = make(0, [
            event(0, 9, 0, 30, .focus, "xcode"),
            event(0, 9, 30, 1.5, .distraction, "x.com"),
            event(0, 9, 31.5, 30, .focus, "xcode"),
        ])
        XCTAssertTrue(glance.returns.isEmpty)
    }

    func test_thresholds_comeFromPickUp() {
        XCTAssertEqual(AnalyzerRules.shortestLoss, PickUpRules.shortestDrift)
        XCTAssertEqual(AnalyzerRules.awayGap, PickUpRules.shortestAway)
        XCTAssertEqual(AnalyzerRules.solidStretch, PickUpRules.enoughFocus)
        XCTAssertEqual(AnalyzerRules.shortestCall, PickUpRules.shortestCall)
    }

    func test_gettingStarted_fromSittingDownToFirstFocus() {
        let plain = make(0, [
            event(0, 9, 0, 12, .neutral, "mail"),
            event(0, 9, 12, 30, .focus, "xcode"),
        ])
        XCTAssertEqual(plain.gettingStarted, 12 * 60)

        // The news at home, then a long gap: the day starts after it.
        let home = make(0, [
            event(0, 7, 0, 10, .distraction, "news.com"),
            event(0, 9, 0, 12, .neutral, "mail"),
            event(0, 9, 12, 30, .focus, "xcode"),
        ])
        XCTAssertEqual(home.gettingStarted, 12 * 60)

        // A morning call is left out.
        let call = make(0, [
            event(0, 9, 0, 5, .neutral, "mail"),
            event(0, 9, 5, 30, .neutral, Self.zoom),
            event(0, 9, 35, 5, .neutral, "mail"),
            event(0, 9, 40, 30, .focus, "xcode"),
        ])
        XCTAssertEqual(call.gettingStarted, 10 * 60)
    }

    func test_measures_areMediansPerWorkingDay() {
        let days = [20.0, 40.0, 90.0].enumerated().map { index, minutes in
            make(index, [event(index, 9, 0, minutes, .focus, "xcode")])
        }
        let measures = AnalyzerMeasures.make(days)
        XCTAssertEqual(measures.longest, 40 * 60)
        XCTAssertEqual(measures.deepBlocks, 1)
        XCTAssertEqual(measures.gettingStarted, 0)
        XCTAssertNil(measures.comingBack, "too few returns to say")
    }

    func test_measures_leaveOutDaysFullOfCalls() {
        let normal = make(0, [event(0, 9, 0, 40, .focus, "xcode")])
        let calls = make(1, [event(1, 9, 0, 10, .focus, "xcode"), event(1, 9, 10, 300, .neutral, Self.zoom)])
        XCTAssertTrue(calls.isCallHeavy)
        XCTAssertEqual(AnalyzerMeasures.make([normal, calls]).longest, 40 * 60)
    }

    // MARK: - Causes, one at a time

    /// Focus either side, so the middle is lost focus during working time.
    private func between(_ middle: [CoachEvent], busy: [DateInterval] = []) -> AnalyzerDay {
        make(0, [event(0, 8, 0, 60, .focus, "xcode")] + middle + [event(0, 14, 0, 60, .focus, "xcode")], busy: busy)
    }

    func test_meetings_aGapBetweenCallsTooShortForADeepBlock() {
        let day = between([
            event(0, 9, 0, 30, .neutral, Self.zoom),
            event(0, 9, 30, 15, .neutral, "arc"),
            event(0, 9, 45, 30, .neutral, Self.zoom),
        ])
        XCTAssertEqual(day.losses.map(\.cause), [.meetings])
        XCTAssertEqual(day.losses.first?.seconds, 15 * 60)
    }

    func test_meetings_aGapBetweenCalendarEvents_evenWithADistraction() {
        let day = between([event(0, 9, 30, 15, .distraction, "x.com")],
                          busy: [DateInterval(start: F.at(0, 9), end: F.at(0, 9, 30)),
                                 DateInterval(start: F.at(0, 9, 45), end: F.at(0, 10, 15))])
        XCTAssertEqual(day.losses.map(\.cause), [.meetings])
    }

    func test_meetings_aGapLongEnoughForADeepBlockIsnt() {
        let day = between([
            event(0, 9, 0, 30, .neutral, Self.zoom),
            event(0, 9, 30, 25, .distraction, "x.com"),
            event(0, 9, 55, 30, .neutral, Self.zoom),
        ])
        XCTAssertEqual(day.losses.map(\.cause), [.habit])
    }

    func test_chat_lossMostlyInAMessageApp_evenIfItEndsOnASite() {
        let day = between([
            event(0, 10, 0, 10, .neutral, Self.slack),
            event(0, 10, 10, 3, .distraction, "x.com"),
        ])
        XCTAssertEqual(day.losses.map(\.cause), [.chatAndMail])
        XCTAssertEqual(day.losses.first?.seconds, 13 * 60)
    }

    func test_habit_aMessageAppFirstDoesntDecideWhereTheTimeWent() {
        // Slack for a moment, then ten minutes of x.com: x.com's. What
        // pulls you away still says it began in Slack.
        let day = between([
            event(0, 10, 0, 3, .neutral, Self.slack),
            event(0, 10, 3, 10, .distraction, "x.com"),
        ])
        XCTAssertEqual(day.losses.map(\.cause), [.habit])
        XCTAssertEqual(day.losses.first?.opening?.name, Self.slack)
    }

    func test_chat_aMessageAppJustBeforeExplainsTimeNothingElseDoes() {
        // Slack right before, then time in no message app, distraction or churn.
        let day = between([
            event(0, 10, 0, 1, .neutral, Self.slack),
            event(0, 10, 1, 10, .neutral, "finder"),
        ])
        XCTAssertEqual(day.losses.map(\.cause), [.chatAndMail])
    }

    func test_chat_rightAfterFocusedSlack_onTheWeb() {
        let day = between([
            event(0, 10, 0, 5, .focus, "app.slack.com"),
            event(0, 10, 5, 10, .neutral, "arc"),
        ])
        XCTAssertEqual(day.losses.map(\.cause), [.chatAndMail])
    }

    func test_habit_needsNoMessageJustBefore() {
        let day = between([event(0, 10, 0, 12, .distraction, "x.com")])
        XCTAssertEqual(day.losses.map(\.cause), [.habit])
    }

    func test_unclearTask_rapidSwitchingAcrossThreeApps_noDistractionNoCall() {
        let apps = ["xcode", "terminal", "notion"]
        let hops = (0..<12).map { event(0, 10, $0, 1, .focus, apps[$0 % 3]) }
        let day = between(hops)
        XCTAssertEqual(day.losses.map(\.cause), [.unclearTask])
        XCTAssertEqual(day.losses.first?.switches, 11)
        XCTAssertEqual(day.losses.first?.seconds, 12 * 60)
    }

    func test_unclearTask_hoppingThatTookMostOfItWinsOverAQuickLook() {
        // Twelve minutes hopping across three apps, then two on x.com: the
        // hopping is where the time went.
        let apps = ["xcode", "terminal", "notion"]
        let hops = (0..<12).map { event(0, 10, $0, 1, .neutral, apps[$0 % 3]) }
        let day = between(hops + [event(0, 10, 12, 2, .distraction, "x.com")])
        XCTAssertEqual(day.losses.map(\.cause), [.unclearTask])
        let longer = between(hops + [event(0, 10, 12, 14, .distraction, "x.com")])
        XCTAssertEqual(longer.losses.map(\.cause), [.habit], "More on x.com than hopping: x.com's")
    }

    func test_unclearTask_twoAppsIsJustWork() {
        let hops = (0..<12).map { event(0, 10, $0, 1, .focus, $0 % 2 == 0 ? "xcode" : "terminal") }
        let day = between(hops)
        XCTAssertTrue(day.losses.allSatisfy { $0.cause != .unclearTask })
    }

    func test_unclearTask_slowSwitchingIsnt() {
        let apps = ["xcode", "terminal", "notion"]
        let hops = (0..<3).map { event(0, 10, $0 * 3, 3, .focus, apps[$0]) }
        let day = between(hops)
        XCTAssertTrue(day.losses.allSatisfy { $0.cause != .unclearTask })
    }

    func test_churn_endsAStretchSoTheTimeIsntBothFocusedAndLost() {
        let apps = ["terminal", "notion", "figma"]
        let hops = (0..<12).map { event(0, 9, $0, 1, .focus, apps[$0 % 3]) }
        let day = make(0, [event(0, 8, 0, 60, .focus, "xcode")] + hops + [event(0, 9, 12, 60, .focus, "xcode")])
        XCTAssertEqual(day.longest, 60 * 60)
        XCTAssertEqual(day.losses.first?.seconds, 12 * 60)
    }

    func test_teams_shortIsChat_longIsACall() {
        let short = between([event(0, 10, 0, 3, .neutral, "com.microsoft.teams2"), event(0, 10, 3, 5, .neutral, "arc")])
        XCTAssertEqual(short.losses.map(\.cause), [.chatAndMail])
        XCTAssertEqual(short.callSeconds, 0)

        let long = between([event(0, 10, 0, 30, .neutral, "com.microsoft.teams2")])
        XCTAssertTrue(long.losses.isEmpty)
        XCTAssertEqual(long.callSeconds, 30 * 60)
    }

    func test_eveningBrowsingAfterTheLastFocus_isntLostFocus() {
        let day = make(0, [
            event(0, 9, 0, 60, .focus, "xcode"),
            event(0, 21, 0, 90, .distraction, "youtube.com"),
        ])
        XCTAssertTrue(day.losses.isEmpty)
    }

    func test_timeAway_splitsLostTime_andIsntCounted() {
        let day = between([
            event(0, 10, 0, 5, .distraction, "x.com"),
            event(0, 11, 0, 5, .distraction, "x.com"),
        ])
        XCTAssertEqual(day.losses.count, 2)
        XCTAssertEqual(day.losses.reduce(0) { $0 + $1.seconds }, 10 * 60)
    }

    func test_mixedDay_everySecondCountedOnce() {
        let apps = ["xcode", "terminal", "notion"]
        var events = [event(0, 8, 0, 60, .focus, "xcode")]                       // focus 60
        events += [event(0, 9, 0, 30, .neutral, Self.zoom)]                      // call 30
        events += [event(0, 9, 30, 10, .neutral, "arc")]                         // meetings 10
        events += [event(0, 9, 40, 30, .neutral, Self.zoom)]                     // call 30
        events += [event(0, 10, 10, 40, .focus, "xcode")]                        // focus 40
        events += [event(0, 10, 50, 6, .neutral, Self.slack), event(0, 10, 56, 4, .distraction, "x.com")] // chat 10
        events += [event(0, 11, 0, 30, .focus, "xcode")]                         // focus 30
        events += [event(0, 11, 30, 15, .distraction, "x.com")]                  // habit 15
        events += [event(0, 11, 45, 30, .focus, "xcode")]                        // focus 30
        events += (0..<12).map { event(0, 12, 15 + $0, 1, .neutral, apps[$0 % 3]) } // unclear 12
        events += [event(0, 12, 27, 30, .focus, "xcode")]                        // focus 30
        events += [event(0, 12, 57, 20, .neutral, "finder")]                     // nothing explains it: 20
        events += [event(0, 13, 17, 30, .focus, "xcode")]                        // focus 30
        let day = make(0, events)

        let byCause = Dictionary(grouping: day.losses, by: \.cause).mapValues { $0.reduce(0) { $0 + $1.seconds } / 60 }
        XCTAssertEqual(byCause[.meetings], 10)
        XCTAssertEqual(byCause[.chatAndMail], 10)
        XCTAssertEqual(byCause[.habit], 15)
        XCTAssertEqual(byCause[.unclearTask], 12)
        XCTAssertEqual(byCause[nil], 20)

        // Nothing overlaps, and focus + calls + lost is everything tracked.
        let spans = day.losses.map { DateInterval(start: $0.start, end: $0.end) }
        XCTAssertEqual(CoachData.covered(spans), spans.reduce(0) { $0 + $1.duration })
        let lost = day.losses.reduce(0) { $0 + $1.seconds }
        XCTAssertEqual(lost + day.callSeconds + (60 + 40 + 30 + 30 + 30 + 30) * 60, day.tracked)
    }

    // MARK: - Late-day dip

    /// A morning of focus and an afternoon of slow, unexplained time.
    private func fadingDay(_ day: Int) -> AnalyzerDay {
        make(day, [
            event(day, 9, 0, 120, .focus, "xcode"),
            event(day, 11, 0, 5, .neutral, "finder"),
            event(day, 11, 5, 55, .focus, "xcode"),
            event(day, 12, 0, 30, .neutral, "finder"),
            event(day, 12, 30, 30, .focus, "xcode"),
            event(day, 13, 0, 60, .neutral, "finder"),
            event(day, 14, 0, 10, .focus, "xcode"),
        ])
    }

    func test_lateDayDip_onlyWhereThePatternHolds_andOnlyWhatNothingElseExplains() {
        let days = (0..<5).map(fadingDay)
        XCTAssertTrue(AnalyzerReport.hasLateDayDip(days))
        let labelled = AnalyzerReport.label(days)
        let causes = labelled[0].losses.map(\.cause)
        XCTAssertEqual(causes, [nil, nil, .tiredness], "only what starts in the day's late part")
    }

    func test_lateDayDip_notFromFourDays() {
        XCTAssertFalse(AnalyzerReport.hasLateDayDip((0..<4).map(fadingDay)))
    }

    func test_lateDayDip_notWithoutADrop() {
        let flat = (0..<6).map { day in
            make(day, [
                event(day, 9, 0, 60, .focus, "xcode"), event(day, 10, 0, 30, .neutral, "finder"),
                event(day, 10, 30, 60, .focus, "xcode"), event(day, 11, 30, 30, .neutral, "finder"),
                event(day, 12, 0, 60, .focus, "xcode"), event(day, 13, 0, 30, .neutral, "finder"),
                event(day, 13, 30, 60, .focus, "xcode"),
            ])
        }
        XCTAssertFalse(AnalyzerReport.hasLateDayDip(flat))
        XCTAssertTrue(AnalyzerReport.label(flat).allSatisfy { $0.losses.allSatisfy { $0.cause == nil } })
    }

    // MARK: - Naming

    /// A working day with `lost` minutes of a cause's kind.
    private func workDay(_ day: Int, habit: Double = 0, chat: Double = 0, unclear: Bool = false) -> AnalyzerDay {
        var events = [event(day, 8, 0, 60, .focus, "xcode")]
        var cursor = 9 * 60
        func add(_ minutes: Double, _ kind: Classification, _ target: String) {
            events.append(event(day, cursor / 60, cursor % 60, minutes, kind, target))
            cursor += Int(minutes)
        }
        if habit > 0 {
            add(habit, .distraction, "x.com")
            add(30, .focus, "xcode")
        }
        if chat > 0 {
            add(chat, .neutral, Self.slack)
            add(30, .focus, "xcode")
        }
        if unclear {
            let apps = ["xcode", "terminal", "notion"]
            for index in 0..<30 { add(1, .neutral, apps[index % 3]) }
            add(30, .focus, "xcode")
        }
        return make(day, events)
    }

    private func report(_ days: [AnalyzerDay], before: [AnalyzerDay] = [], muted: Set<AnalyzerCause> = []) -> AnalyzerReport {
        AnalyzerReport.make(period: DateInterval(start: F.at(0, 0), end: F.at(28, 0)), days: days, before: before, muted: muted,
                            weekendsCount: true, calendar: calendar)
    }

    private let weekdays = [0, 1, 2, 3, 4, 7, 8, 9, 10, 11, 14, 15, 16, 17, 18, 21, 22, 23, 24, 25]

    func test_firstWeek_namesNothing_atSixDays_namesAtSeven() {
        let six = report(weekdays.prefix(6).map { workDay($0, habit: 40) })
        XCTAssertEqual(six.finding, .learning(daysLeft: 1))
        XCTAssertTrue(six.rows.isEmpty, "nothing named, so no reasons either")
        XCTAssertTrue(six.details.isEmpty)

        let seven = report(weekdays.prefix(7).map { workDay($0, habit: 40) })
        XCTAssertEqual(seven.finding, .named(.habit))
        XCTAssertEqual(seven.rows.first?.perDay, 40 * 60)
    }

    func test_tooCloseToName_saysSoInsteadOfPicking() {
        let days = weekdays.prefix(10).map { workDay($0, habit: 40, chat: 34) }
        XCTAssertEqual(report(days).finding, .tooClose(.habit, .chatAndMail))
    }

    func test_aTieIsntAWorst() {
        let days = weekdays.prefix(10).map { workDay($0, habit: 40, chat: 40) }
        guard case .tooClose = report(days).finding else {
            return XCTFail("a tie names nothing")
        }
    }

    func test_clearlyAhead_needsBothTheRatioAndTheMargin() {
        func rows(_ top: Double, _ next: Double) -> [AnalyzerCauseRow] {
            [AnalyzerCauseRow(cause: .habit, perDay: top * 60, isSteady: true),
             AnalyzerCauseRow(cause: .chatAndMail, perDay: next * 60, isSteady: true)]
        }
        XCTAssertEqual(AnalyzerReport.finding(rows(60, 30), workingDays: 10), .named(.habit))
        XCTAssertEqual(AnalyzerReport.finding(rows(60, 45), workingDays: 10), .tooClose(.habit, .chatAndMail), "not 1.5 times")
        XCTAssertEqual(AnalyzerReport.finding(rows(18, 6), workingDays: 10), .named(.habit))
        XCTAssertEqual(AnalyzerReport.finding(rows(21, 12), workingDays: 10), .tooClose(.habit, .chatAndMail), "under 10 min a day apart")
    }

    func test_neverNamedWhenMoreIsUnexplained() {
        let rows = [AnalyzerCauseRow(cause: .habit, perDay: 30 * 60, isSteady: true),
                    AnalyzerCauseRow(cause: nil, perDay: 40 * 60)]
        XCTAssertEqual(AnalyzerReport.finding(rows, workingDays: 10), .nothingClear)
    }

    func test_tooLittleTime_namesNothing() {
        let days = weekdays.prefix(10).map { workDay($0, habit: 10) }
        XCTAssertEqual(report(days).finding, .nothingClear)
    }

    func test_aFewBadDays_namesNothing() {
        let days = weekdays.prefix(10).enumerated().map { index, day in
            workDay(day, habit: index < 3 ? 120 : 0, chat: 0)
        }
        XCTAssertEqual(report(days).finding, .nothingClear, "3 days of 10 isn't steady")
    }

    func test_aWeekOfCalls_nameNoFalseCause() {
        // Five days nearly all calls, with a little chat and a late drop
        // between them, on top of two normal days.
        let calls = weekdays.prefix(5).map { day in
            make(day, [
                event(day, 8, 0, 30, .focus, "xcode"),
                event(day, 8, 30, 20, .distraction, "x.com"),
                event(day, 8, 50, 30, .focus, "xcode"),
                event(day, 9, 20, 400, .neutral, Self.zoom),
            ])
        }
        XCTAssertTrue(calls.allSatisfy(\.isCallHeavy))
        let normal = weekdays.dropFirst(5).prefix(2).map { workDay($0) }
        XCTAssertEqual(report(calls + normal).finding, .nothingClear, "too few clear days to name a habit")
    }

    func test_oneHeavyWeekInAMonth_doesntNameMeetings() {
        let gaps = weekdays.prefix(5).map { day in
            make(day, [
                event(day, 8, 0, 30, .focus, "xcode"),
                event(day, 8, 30, 30, .neutral, Self.zoom),
                event(day, 9, 0, 20, .neutral, "arc"),
                event(day, 9, 20, 30, .neutral, Self.zoom),
                event(day, 9, 50, 30, .focus, "xcode"),
            ])
        }
        let quiet = weekdays.dropFirst(5).map { workDay($0) }
        let found = report(gaps + quiet)
        XCTAssertEqual(found.rows.first { $0.cause == .meetings }?.daysSeen, 5)
        XCTAssertEqual(found.finding, .nothingClear)
    }

    func test_daysOff_arentWorkingDays() {
        // A weekend, a weekday of browsing, and a short day.
        let browsing = make(2, [event(2, 10, 0, 180, .distraction, "youtube.com")])
        let short = make(3, [event(3, 10, 0, 20, .focus, "xcode")])
        XCTAssertFalse(browsing.isWorking(weekendsCount: true, calendar: calendar))
        XCTAssertFalse(short.isWorking(weekendsCount: true, calendar: calendar))
        let saturday = make(5, [event(5, 10, 0, 180, .focus, "xcode")])
        XCTAssertTrue(CoachFixture.calendar.isDateInWeekend(saturday.day))
        XCTAssertFalse(saturday.isWorking(weekendsCount: false, calendar: calendar))
        XCTAssertTrue(saturday.isWorking(weekendsCount: true, calendar: calendar))
        XCTAssertEqual(report([browsing, short]).workingDays, 0)
    }

    func test_previousPeriod_onlyWithEnoughDaysInBoth() {
        let now = weekdays.prefix(7).map { workDay($0) }
        XCTAssertNil(report(now, before: (0..<6).map { workDay($0 - 28) }).previous)
        XCTAssertNotNil(report(now, before: (0..<7).map { workDay($0 - 28) }).previous)
        XCTAssertNil(report(Array(now.prefix(6)), before: (0..<7).map { workDay($0 - 28) }).previous)
    }

    // MARK: - Corrections

    func test_correction_isRemembered_andThatCauseIsntRepeated() {
        let defaults = freshDefaults()
        let analyzer = FocusAnalyzer(defaults: defaults, calendar: calendar)
        analyzer.correct(.habit, actual: .meetings, note: "  It was research.  ")

        let reopened = FocusAnalyzer(defaults: defaults, calendar: calendar)
        XCTAssertEqual(reopened.muted, [.habit])
        XCTAssertEqual(reopened.state.corrections.first?.actual, .meetings)
        XCTAssertEqual(reopened.state.corrections.first?.note, "It was research.")

        let days = weekdays.prefix(10).map { workDay($0, habit: 60, chat: 30) }
        XCTAssertEqual(report(days).finding, .named(.habit))
        let corrected = report(days, muted: reopened.muted)
        XCTAssertEqual(corrected.finding, .named(.chatAndMail), "next in line, on its own evidence")
        XCTAssertEqual(corrected.rows.first { $0.cause == .habit }?.perDay, 60 * 60, "no time moves: the numbers stay what was tracked")
        XCTAssertEqual(corrected.rows.first { $0.cause == .meetings }?.seconds, 0, "what they said happened changes no numbers")

        reopened.restore(.habit)
        XCTAssertEqual(FocusAnalyzer(defaults: defaults, calendar: calendar).muted, [])
    }

    func test_correction_withNothingElseSteady_namesNothing() {
        let days = weekdays.prefix(10).map { workDay($0, habit: 60) }
        XCTAssertEqual(report(days, muted: [.habit]).finding, .nothingClear)
    }

    // MARK: - Fixes the data supports

    private func detail(_ cause: AnalyzerCause, steady: Bool = true, muted: Bool = false) -> AnalyzerCauseDetail {
        AnalyzerCauseDetail(row: AnalyzerCauseRow(cause: cause, perDay: 30 * 60, isSteady: steady, isMuted: muted))
    }

    func test_noFix_forWhatIsntSteadyOrWasRuledOut() {
        XCTAssertNil(AnalyzerFixes.fix(for: .chatAndMail, detail: detail(.chatAndMail, steady: false), context: .init()))
        var muted = detail(.chatAndMail, muted: true)
        muted.sessions = 20
        XCTAssertNil(AnalyzerFixes.fix(for: .chatAndMail, detail: muted, context: .init()))
    }

    func test_unclearTask_fixNeedsSessionsWithoutAGoal_andNoEvidenceAgainstIt() {
        var d = detail(.unclearTask)
        XCTAssertNil(AnalyzerFixes.fix(for: .unclearTask, detail: d, context: .init()), "no sessions to ask in")
        d.sessions = 20
        d.goallessSessions = 1
        XCTAssertNil(AnalyzerFixes.fix(for: .unclearTask, detail: d, context: .init()), "already writes goals")
        d.goallessSessions = 10
        XCTAssertEqual(AnalyzerFixes.fix(for: .unclearTask, detail: d, context: .init())?.change, .askForGoal)
        d.withGoal = AnalyzerGoalSide(longest: 20 * 60, count: 10)
        d.withoutGoal = AnalyzerGoalSide(longest: 20 * 60, count: 10)
        XCTAssertNil(AnalyzerFixes.fix(for: .unclearTask, detail: d, context: .init()), "goals don't go with longer stretches here")
        d.withGoal = AnalyzerGoalSide(longest: 40 * 60, count: 10)
        XCTAssertNotNil(AnalyzerFixes.fix(for: .unclearTask, detail: d, context: .init()))
    }

    func test_goalComparison_onlyFromEnoughSessions() {
        func day(_ number: Int, goal: Int, without: Int) -> AnalyzerDay {
            var out = workDay(number, habit: 40)
            out.sessions = Array(repeating: AnalyzerSessionStat(hasGoal: true, longest: 40 * 60), count: goal)
                + Array(repeating: AnalyzerSessionStat(hasGoal: false, longest: 20 * 60), count: without)
            return out
        }
        let few = report(weekdays.prefix(7).map { day($0, goal: 0, without: 1) }).details[.habit]
        XCTAssertNil(few?.withGoal, "no sessions with a goal")
        let enough = report(weekdays.prefix(7).map { day($0, goal: 1, without: 1) }).details[.habit]
        XCTAssertEqual(enough?.withGoal, AnalyzerGoalSide(longest: 40 * 60, count: 7))
        XCTAssertEqual(enough?.withoutGoal, AnalyzerGoalSide(longest: 20 * 60, count: 7))
    }

    func test_habit_fixNeedsAtLeast15MinutesAndNoLimitYet() {
        var d = detail(.habit)
        d.topDistraction = AnalyzerPlace(name: "x.com", target: "x.com", isSite: true, bundleId: nil, isDistraction: true, seconds: 0)
        d.topDistractionPerDay = 10 * 60
        XCTAssertNil(AnalyzerFixes.fix(for: .habit, detail: d, context: .init()))
        d.topDistractionPerDay = 40 * 60
        XCTAssertEqual(AnalyzerFixes.fix(for: .habit, detail: d, context: .init())?.change,
                       .dailyLimit(target: "x.com", isSite: true, name: "x.com", minutes: 25))
        XCTAssertNil(AnalyzerFixes.fix(for: .habit, detail: d, context: .init(limited: ["x.com"])))
    }

    func test_meetings_fixNeedsTheCalendar() {
        XCTAssertNil(AnalyzerFixes.fix(for: .meetings, detail: detail(.meetings), context: .init()))
        let fix = AnalyzerFixes.fix(for: .meetings, detail: detail(.meetings), context: .init(canUseCalendar: true))
        XCTAssertEqual(fix?.change, .protectBlock(minutes: 50))
        XCTAssertEqual(fix?.measure, .deepBlocks)
    }

    func test_tiredness_morningPlanEarlierOnlyWhereItCan() {
        var d = detail(.tiredness)
        d.sessions = 10
        XCTAssertEqual(AnalyzerFixes.fix(for: .tiredness, detail: d, context: .init(morningPlanHour: 9))?.change, .hardestFirst(morningHour: 8))
        XCTAssertEqual(AnalyzerFixes.fix(for: .tiredness, detail: d, context: .init(morningPlanHour: 7))?.change, .hardestFirst(morningHour: nil))
        XCTAssertEqual(AnalyzerFixes.fix(for: .tiredness, detail: d, context: .init(morningPlanHour: 9, morningPlanTaken: true))?.change,
                       .hardestFirst(morningHour: nil))
    }

    func test_copy_neverClaimsCertaintyOrAFeeling() {
        for cause in AnalyzerCause.allCases {
            XCTAssertFalse(cause.explanation.lowercased().contains("because"), cause.rawValue)
        }
        XCTAssertFalse(AnalyzerCause.tiredness.name.lowercased().contains("tired"))
        XCTAssertTrue(AnalyzerCause.tiredness.explanation.contains("not a claim about how you feel"))
    }

    func test_freeSlot_firstQuarterHourWithRoom() {
        let busy = [DateInterval(start: F.at(0, 9), end: F.at(0, 11, 5))]
        XCTAssertEqual(AnalyzerFixes.freeSlot(on: F.at(0, 0), busy: busy, minutes: 50, now: F.at(0, 8), calendar: calendar), F.at(0, 11, 15))
        XCTAssertEqual(AnalyzerFixes.freeSlot(on: F.at(0, 0), busy: [], minutes: 50, now: F.at(0, 13, 1), calendar: calendar), F.at(0, 13, 15))
        let full = [DateInterval(start: F.at(0, 9), end: F.at(0, 17))]
        XCTAssertNil(AnalyzerFixes.freeSlot(on: F.at(0, 0), busy: full, minutes: 50, now: F.at(0, 8), calendar: calendar))
    }

    // MARK: - Opt-out

    func test_rows_haveNoTitles_andOptedOutSitesArentNamed() {
        let browser = "com.private.browser"
        let day = between([event(0, 10, 0, 12, .distraction, "bank.com", bundleId: browser),
                           event(0, 10, 12, 3, .distraction, "x.com", bundleId: "com.other")])
        let loss = day.losses[0]
        XCTAssertEqual(loss.placeNames(optedOut: []), ["bank.com", "x.com"])
        XCTAssertEqual(loss.placeNames(optedOut: [browser]), ["x.com"])
        XCTAssertEqual(loss.placeNames(optedOut: [browser, "com.other"]), [])
    }

    func test_store_readsRealEvents_andNoTitleReachesTheReport() async throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        // Fridays to Tuesdays past the fixture's Monday: 7 working days with
        // 40 minutes of x.com, its window title private.
        for day in weekdays.prefix(7) {
            let blocks: [(Int, Int, String?, String, String, Classification)] = [
                (0, 60, nil, "Xcode", "com.apple.dt.Xcode", .focus),
                (60, 40, "https://x.com/home", "Safari", "com.apple.Safari", .distraction),
                (100, 60, nil, "Xcode", "com.apple.dt.Xcode", .focus),
            ]
            for (offset, minutes, url, name, bundle, kind) in blocks {
                let start = F.at(day, 9).addingTimeInterval(TimeInterval(offset * 60))
                let event = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                          bundleIdentifier: bundle, appName: name, windowTitle: "SECRET TITLE", url: url)
                event.classification = kind
                context.insert(event)
            }
        }
        try context.save()
        let stats = StatsStore(container: container)
        let found = await stats.analyzerReport(now: F.at(28, 10), weekendsCount: false, muted: [], busy: [], calendar: calendar)
        XCTAssertEqual(found.workingDays, 7)
        XCTAssertEqual(found.finding, .named(.habit))
        XCTAssertEqual(found.measures.longest, 60 * 60)
        let detail = try XCTUnwrap(found.details[.habit])
        XCTAssertEqual(detail.examples.count, 3)
        XCTAssertEqual(detail.examples[0].places.first?.name, "x.com")
        XCTAssertEqual(detail.topDistraction?.target, "x.com")
        XCTAssertFalse(String(describing: found).contains("SECRET"))

        // A second read comes from what's kept.
        let again = await stats.analyzerReport(now: F.at(28, 11), weekendsCount: false, muted: [.habit], busy: [], calendar: calendar)
        XCTAssertEqual(again.finding, .nothingClear)
    }

    // MARK: - Scheduling

    /// Tuesday 20 Oct 2026, 10:00, so the test starts Wednesday.
    private let startClock = CoachFixture.at(1, 10)

    func test_schedule_tenWorkingDays_halfOnHalfOff_balancedAcrossWeekdays() {
        for seed in 0..<UInt64(50) {
            let slots = AnalyzerExperiment.schedule(after: startClock, seed: seed, weekendsCount: false, calendar: calendar)
            XCTAssertEqual(slots.count, 10)
            XCTAssertEqual(slots.first?.day, F.at(2, 0), "starts the next day")
            XCTAssertFalse(slots.contains { calendar.isDateInWeekend($0.day) })
            XCTAssertEqual(slots.filter { $0.arm == .on }.count, 5)
            for group in Dictionary(grouping: slots, by: { calendar.component(.weekday, from: $0.day) }).values {
                XCTAssertEqual(group.count, 2)
                XCTAssertEqual(Set(group.map(\.arm)), [.on, .off], "each weekday falls on both sides")
            }
            XCTAssertTrue(AnalyzerExperiment.isFair(slots.map(\.arm)))
        }
    }

    func test_schedule_startingOnFriday_skipsTheWeekend() {
        let slots = AnalyzerExperiment.schedule(after: F.at(3, 10), seed: 1, weekendsCount: false, calendar: calendar)
        XCTAssertEqual(slots.first?.day, F.at(4, 0))
        XCTAssertEqual(slots[1].day, F.at(7, 0))
    }

    func test_schedule_withWeekendsCounting_stillHalfAndHalf() {
        for seed in 0..<UInt64(20) {
            let slots = AnalyzerExperiment.schedule(after: startClock, seed: seed, weekendsCount: true, calendar: calendar)
            XCTAssertEqual(slots.map(\.day), (2..<12).map { F.at($0, 0) })
            XCTAssertEqual(slots.filter { $0.arm == .on }.count, 5)
        }
    }

    func test_schedule_sameSeedSameShuffle_differentSeedsDiffer() {
        let days = AnalyzerExperiment.workingDays(after: startClock, count: 10, weekendsCount: false, calendar: calendar)
        let first = AnalyzerExperiment.arms(for: days, seed: 42, calendar: calendar)
        XCTAssertEqual(first, AnalyzerExperiment.arms(for: days, seed: 42, calendar: calendar))
        XCTAssertGreaterThan(Set((0..<UInt64(40)).map { AnalyzerExperiment.arms(for: days, seed: $0, calendar: calendar).map(\.rawValue).joined() }).count, 4)
    }

    func test_random_isThePublishedSplitMix64() {
        // First outputs of SplitMix64 for seed 0, so a stored seed can't change meaning.
        var random = AnalyzerRandom(seed: 0)
        XCTAssertEqual(random.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(random.next(), 0x6E78_9E6A_A1B9_65F4)
    }

    private func experiment(slots: [AnalyzerExperiment.Slot]? = nil) -> AnalyzerExperiment {
        AnalyzerExperiment(fix: AnalyzerFix(cause: .unclearTask, change: .askForGoal, measure: .longestStretch),
                           plan: "plan", seed: 7, startedAt: startClock,
                           slots: slots ?? AnalyzerExperiment.schedule(after: startClock, seed: 7, weekendsCount: false, calendar: calendar))
    }

    func test_skippedDay_isMadeUp_sameArm_sameWeekday_afterThePlan() throws {
        var test = experiment()
        let first = try XCTUnwrap(test.slots.first)
        let weekday = calendar.component(.weekday, from: first.day)
        let last = try XCTUnwrap(test.slots.last?.day)
        test.resolve(day: first.day, value: nil, today: F.at(3, 0), calendar: calendar)

        XCTAssertEqual(test.slots.first?.state, .skipped)
        XCTAssertEqual(test.slots.count, 11)
        XCTAssertEqual(test.visibleSlots.count, 10)
        let made = try XCTUnwrap(test.slots.last)
        XCTAssertEqual(made.arm, first.arm)
        XCTAssertEqual(calendar.component(.weekday, from: made.day), weekday)
        XCTAssertGreaterThan(made.day, last)
        XCTAssertEqual(test.visibleSlots.filter { $0.arm == .on }.count, 5)
        XCTAssertFalse(test.isFinished)
    }

    func test_twoSkippedOnDifferentWeekdays_keepTheirWeekdays_noGapOfAWeek() throws {
        var test = experiment()
        let a = test.slots[0], b = test.slots[1]
        test.resolve(day: a.day, value: nil, today: F.at(4, 0), calendar: calendar)
        test.resolve(day: b.day, value: nil, today: F.at(4, 0), calendar: calendar)
        let made = test.slots.suffix(2).map(\.day)
        XCTAssertEqual(Set(made.map { calendar.component(.weekday, from: $0) }),
                       [calendar.component(.weekday, from: a.day), calendar.component(.weekday, from: b.day)])
        XCTAssertLessThanOrEqual(try XCTUnwrap(made.max()).timeIntervalSince(test.lastPlanned), 7 * 86_400)
    }

    func test_longAbsence_makesUpOnlyFromToday_andIsCapped() {
        var test = experiment()
        let days = test.slots.map(\.day)
        let today = F.at(40, 0)
        for day in days { test.resolve(day: day, value: nil, today: today, calendar: calendar) }
        XCTAssertTrue(test.slots.filter { $0.state == .pending }.allSatisfy { $0.day > today })
        XCTAssertEqual(test.makeUps, 10)
        var cursor = test
        for slot in cursor.slots where slot.state == .pending {
            cursor.resolve(day: slot.day, value: nil, today: F.at(70, 0), calendar: calendar)
        }
        XCTAssertTrue(cursor.isFinished, "the cap ends it rather than extending for ever")
        XCTAssertEqual(cursor.outcome.verdict, .notEnoughDays)
    }

    func test_onDayTheChangeWasntOn_doesntCount() {
        var test = experiment()
        let on = test.slots.first { $0.arm == .on }!
        test.resolve(day: on.day, value: 40, today: F.at(20, 0), calendar: calendar)
        XCTAssertEqual(test.slots.first { $0.day == on.day }?.state, .skipped)
    }

    // MARK: - Verdicts, worked by hand

    private func judge(_ on: [Double], _ off: [Double]) -> AnalyzerOutcome {
        AnalyzerOutcome.judge(on: on, off: off, measure: .longestStretch)
    }

    func test_verdict_itWorked_theDesignsExample() {
        let result = judge([44, 38, 47, 36, 41], [24, 29, 21, 27, 18])
        XCTAssertEqual(result.verdict, .worked)
        XCTAssertEqual(result.onMedian, 41)
        XCTAssertEqual(result.offMedian, 24)
        XCTAssertEqual(result.winShare, 1)
    }

    func test_verdict_noDifference_theDesignsExample() {
        let result = judge([31, 24, 28, 35, 27], [26, 33, 22, 27, 30])
        XCTAssertEqual(result.verdict, .noDifference)
        XCTAssertEqual(result.onMedian, 28)
        XCTAssertEqual(result.offMedian, 27)
    }

    func test_verdict_tooFewDays() {
        XCTAssertEqual(judge([44, 38, 47], [24, 29, 21, 27, 18]).verdict, .notEnoughDays)
        XCTAssertEqual(judge([44, 38, 47, 36, 41], [24, 29, 21]).verdict, .notEnoughDays)
        XCTAssertEqual(judge([], []).verdict, .notEnoughDays)
        XCTAssertEqual(judge([44, 38, 47, 36], [24, 29, 21, 27]).verdict, .worked, "4 and 4 is just enough")
    }

    func test_verdict_needsLittleOverlap_atSevenInEight() {
        // 22 of 25 pairs: 40 beats 2 of the 5 Off days, the rest beat all 5.
        XCTAssertEqual(AnalyzerOutcome.winShare(on: [50, 51, 52, 53, 40], off: [20, 21, 41, 42, 43]), 22.0 / 25)
        XCTAssertEqual(judge([50, 51, 52, 53, 40], [20, 21, 41, 42, 43]).verdict, .worked)
        // 21 of 25: 9 minutes between the medians is still enough, the overlap isn't.
        XCTAssertEqual(AnalyzerOutcome.winShare(on: [50, 51, 52, 53, 30], off: [20, 41, 42, 43, 44]), 21.0 / 25)
        XCTAssertEqual(judge([50, 51, 52, 53, 30], [20, 41, 42, 43, 44]).verdict, .noDifference)
    }

    func test_verdict_tiesCountHalf() {
        XCTAssertEqual(AnalyzerOutcome.winShare(on: [30, 30], off: [30, 30]), 0.5)
        XCTAssertEqual(judge([30, 30, 30, 30, 30], [30, 30, 30, 30, 30]).verdict, .noDifference)
    }

    func test_verdict_noOverlapButATinyGapIsNoDifference() {
        // All On above all Off. 6 minutes on 28 is over a fifth; 3.5 isn't.
        XCTAssertEqual(judge([32, 33, 34, 35, 36], [26, 27, 28, 29, 30]).verdict, .worked)
        XCTAssertEqual(judge([30.5, 31, 31.5, 32, 32.5], [26, 27, 28, 29, 30]).verdict, .noDifference)
        // A fifth of a long Off median is more than 5 minutes.
        XCTAssertEqual(judge([107, 108, 109, 110, 111], [96, 97, 98, 99, 100]).verdict, .noDifference)
    }

    func test_verdict_theWrongDirectionNeverWorks() {
        XCTAssertEqual(judge([24, 29, 21, 27, 18], [44, 38, 47, 36, 41]).verdict, .noDifference)
    }

    func test_verdict_deepBlocks_haveTheirOwnGap() {
        let on = [2.0, 2, 2, 3, 2], off = [1.0, 1, 2, 1, 1]
        XCTAssertEqual(AnalyzerOutcome.judge(on: on, off: off, measure: .deepBlocks).verdict, .worked)
        XCTAssertEqual(AnalyzerOutcome.judge(on: [1, 1, 1, 1, 1], off: [1, 1, 1, 1, 1], measure: .deepBlocks).verdict, .noDifference)
    }

    // MARK: - Applying and undoing

    private final class FakeApplier: AnalyzerApplying {
        var applied: [(AnalyzerChange, Date)] = []
        var undone: [AnalyzerUndo] = []
        var refuse = false
        var reminders: [String] = []
        var goalAsks = 0
        var finished = 0
        var nextUndo = AnalyzerUndo.nothing

        func apply(_ change: AnalyzerChange, on day: Date) async -> AnalyzerUndo? {
            guard !refuse else { return nil }
            applied.append((change, day))
            return nextUndo
        }
        func undo(_ undo: AnalyzerUndo) async { undone.append(undo) }
        func context() -> AnalyzerFixes.Context { .init() }
        func remind(_ plan: String) { reminders.append(plan) }
        func askForGoal() { goalAsks += 1 }
        func experimentFinished() { finished += 1 }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "AnalyzerTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private var clock = CoachFixture.at(1, 10)
    private var unlocked = true
    private var values: [Date: AnalyzerDay] = [:]
    private var applier: FakeApplier!

    override func setUp() async throws {
        try await super.setUp()
        clock = F.at(1, 10)
        unlocked = true
        values = [:]
        applier = FakeApplier()
    }

    private func makeAnalyzer(_ defaults: UserDefaults) -> FocusAnalyzer {
        let analyzer = FocusAnalyzer(defaults: defaults, calendar: calendar)
        analyzer.applier = applier
        analyzer.now = { [unowned self] in self.clock }
        analyzer.isUnlocked = { [unowned self] in self.unlocked }
        analyzer.startTrial = { }
        analyzer.weekendsCount = { false }
        analyzer.days = { [unowned self] days in days.compactMap { self.values[$0] } }
        return analyzer
    }

    private let goalFix = AnalyzerFix(cause: .unclearTask, change: .askForGoal, measure: .longestStretch)

    /// A day that counts, with a longest stretch this long.
    private func countedDay(_ day: Date, minutes: Double) -> AnalyzerDay {
        let start = day.addingTimeInterval(9 * 3600)
        let focus = CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: .focus, target: "xcode", name: "Xcode",
                               isSite: false, session: nil)
        let other = CoachEvent(start: start.addingTimeInterval(minutes * 60), end: start.addingTimeInterval((minutes + 90) * 60),
                               kind: .neutral, target: "finder", name: "Finder", isSite: false, session: nil)
        return AnalyzerDayBuilder.make(day: day, events: [focus, other], calendar: calendar)
    }

    func test_onDayOn_offDayOff_andARelaunchNeitherDoublesNorForgets() async throws {
        let defaults = freshDefaults()
        var analyzer = makeAnalyzer(defaults)
        XCTAssertTrue(analyzer.start(goalFix, plan: "  my plan ", seed: 7, calendarOK: false))
        let test = try XCTUnwrap(analyzer.state.experiment)
        XCTAssertEqual(test.plan, "my plan")
        XCTAssertEqual(test.seed, 7)
        await analyzer.refresh()
        XCTAssertTrue(applier.applied.isEmpty, "the test starts tomorrow, so nothing changes today")

        let firstOn = try XCTUnwrap(test.slots.first { $0.arm == .on })
        clock = firstOn.day.addingTimeInterval(9 * 3600)
        await analyzer.refresh()
        XCTAssertEqual(applier.applied.count, 1)
        XCTAssertEqual(analyzer.state.applied?.day, firstOn.day)

        // Relaunch the same day: same state, not applied again.
        analyzer = makeAnalyzer(defaults)
        await analyzer.refresh()
        XCTAssertEqual(applier.applied.count, 1)
        XCTAssertEqual(analyzer.state.experiment?.seed, 7)
        XCTAssertEqual(analyzer.state.experiment?.slots.map(\.arm), test.slots.map(\.arm), "the stored shuffle survives")

        // The next day with an Off: it comes off; on the next On it's back.
        let firstOff = try XCTUnwrap(test.slots.first { $0.arm == .off && $0.day > firstOn.day })
        clock = firstOff.day.addingTimeInterval(9 * 3600)
        await analyzer.refresh()
        XCTAssertEqual(applier.undone.count, 1)
        XCTAssertNil(analyzer.state.applied)
    }

    func test_aChangeThatCantBeApplied_isntCountedAsOn() async throws {
        let defaults = freshDefaults()
        let analyzer = makeAnalyzer(defaults)
        analyzer.start(goalFix, plan: "", seed: 7, calendarOK: false)
        let test = try XCTUnwrap(analyzer.state.experiment)
        XCTAssertEqual(test.plan, goalFix.change.plan, "an empty plan falls back to the template")
        let firstOn = try XCTUnwrap(test.slots.first { $0.arm == .on })
        applier.refuse = true
        clock = firstOn.day.addingTimeInterval(9 * 3600)
        await analyzer.refresh()
        XCTAssertNil(analyzer.state.applied)
        applier.refuse = false
        values[firstOn.day] = countedDay(firstOn.day, minutes: 60)
        clock = firstOn.day.addingTimeInterval(32 * 3600)
        applier.refuse = true
        await analyzer.refresh()
        XCTAssertEqual(analyzer.state.experiment?.slot(on: firstOn.day)?.state, .skipped)
        XCTAssertGreaterThanOrEqual(analyzer.state.experiment?.makeUps ?? 0, 1)
    }

    /// Runs a whole test: On days at `on` minutes, Off days at `off`.
    private func run(_ analyzer: FocusAnalyzer, on: Double, off: Double) async throws {
        var guardCount = 0
        while let slot = analyzer.state.experiment?.slots.first(where: { $0.state == .pending }), guardCount < 40 {
            guardCount += 1
            clock = slot.day.addingTimeInterval(9 * 3600)
            await analyzer.refresh()
            values[slot.day] = countedDay(slot.day, minutes: slot.arm == .on ? on : off)
            clock = slot.day.addingTimeInterval(33 * 3600)
            await analyzer.refresh()
        }
    }

    func test_wholeTest_finishes_undoes_judges_andKeepIt_staysOn_untilStopped() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        applier.nextUndo = .coach(.morningPlan(hour: nil, enabled: nil))
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        try await run(analyzer, on: 45, off: 20)

        XCTAssertNil(analyzer.state.experiment)
        XCTAssertNil(analyzer.state.applied)
        let finished = try XCTUnwrap(analyzer.state.finished)
        XCTAssertEqual(finished.outcome.verdict, .worked)
        XCTAssertEqual(finished.outcome.onDays, 5)
        XCTAssertEqual(finished.outcome.offDays, 5)
        XCTAssertEqual(applier.finished, 1)
        XCTAssertEqual(applier.applied.count, 5, "exactly the On days")
        XCTAssertEqual(applier.undone.count, 5, "and each came off again")

        await analyzer.keep()
        XCTAssertNil(analyzer.state.finished)
        XCTAssertEqual(analyzer.state.kept.count, 1)
        XCTAssertEqual(applier.applied.count, 6)
        await analyzer.refresh()
        XCTAssertEqual(applier.undone.count, 5, "kept: nothing takes it back")
        clock = clock.addingTimeInterval(5 * 86_400)
        await analyzer.refresh()
        XCTAssertEqual(applier.applied.count, 6, "and it isn't applied again each day")

        await analyzer.stopKept(try XCTUnwrap(analyzer.state.kept.first))
        XCTAssertEqual(applier.undone.count, 6)
        XCTAssertEqual(applier.undone.last, .coach(.morningPlan(hour: nil, enabled: nil)), "back to exactly what was there")
        XCTAssertTrue(analyzer.state.kept.isEmpty)
    }

    func test_noDifference_tryElseRemembersIt_testAgainReshuffles() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        try await run(analyzer, on: 30, off: 30)
        XCTAssertEqual(analyzer.state.finished?.outcome.verdict, .noDifference)

        XCTAssertTrue(analyzer.testAgain(seed: 9))
        XCTAssertEqual(analyzer.state.experiment?.seed, 9)
        XCTAssertNil(analyzer.state.finished)
        await analyzer.stop()

        analyzer.start(goalFix, plan: "plan", seed: 8, calendarOK: false)
        try await run(analyzer, on: 30, off: 30)
        analyzer.dismissResult()
        XCTAssertEqual(analyzer.state.tested, [.unclearTask])
        XCTAssertNil(analyzer.state.finished)
    }

    func test_stopIt_undoesAtOnce_andLeavesNoResult() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        let firstOn = try XCTUnwrap(analyzer.state.experiment?.slots.first { $0.arm == .on })
        clock = firstOn.day.addingTimeInterval(9 * 3600)
        await analyzer.refresh()
        await analyzer.stop()
        XCTAssertEqual(applier.undone.count, 1)
        XCTAssertNil(analyzer.state.experiment)
        XCTAssertNil(analyzer.state.finished)
    }

    func test_callHeavyAndEmptyDays_dontCount_soTheyExtendIt() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        let slots = try XCTUnwrap(analyzer.state.experiment?.slots)
        let start = slots[0].day.addingTimeInterval(9 * 3600)
        values[slots[0].day] = AnalyzerDayBuilder.make(day: slots[0].day, events: [
            CoachEvent(start: start, end: start.addingTimeInterval(30 * 60), kind: .focus, target: "xcode", name: "Xcode", isSite: false, session: nil),
            CoachEvent(start: start.addingTimeInterval(30 * 60), end: start.addingTimeInterval(6 * 3600), kind: .neutral, target: Self.zoom, name: "Zoom", isSite: false, session: nil),
        ], calendar: calendar)
        clock = slots[1].day.addingTimeInterval(33 * 3600)
        await analyzer.refresh()
        let after = try XCTUnwrap(analyzer.state.experiment)
        XCTAssertEqual(after.slot(on: slots[0].day)?.state, .skipped, "a day of calls")
        XCTAssertEqual(after.slot(on: slots[1].day)?.state, .skipped, "a day with nothing tracked")
        XCTAssertEqual(after.makeUps, 2)
    }

    func test_sessionStart_onAnOnDayOnly_andAGoalMeansNoQuestion() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        let test = try XCTUnwrap(analyzer.state.experiment)
        let on = try XCTUnwrap(test.slots.first { $0.arm == .on })
        let off = try XCTUnwrap(test.slots.first { $0.arm == .off })
        clock = off.day.addingTimeInterval(9 * 3600)
        analyzer.sessionStarted(hasGoal: false)
        XCTAssertEqual(applier.goalAsks, 0, "an Off day asks nothing")
        clock = on.day.addingTimeInterval(9 * 3600)
        analyzer.sessionStarted(hasGoal: true)
        XCTAssertEqual(applier.goalAsks, 0, "a goal was typed already")
        analyzer.sessionStarted(hasGoal: false)
        XCTAssertEqual(applier.goalAsks, 1)
    }

    func test_reminders_goWithTheirFix() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        let fix = AnalyzerFix(cause: .tiredness, change: .hardestFirst(morningHour: nil), measure: .longestStretch)
        analyzer.start(fix, plan: "hard first", seed: 7, calendarOK: false)
        let on = try XCTUnwrap(analyzer.state.experiment?.slots.first { $0.arm == .on })
        clock = on.day.addingTimeInterval(9 * 3600)
        analyzer.sessionStarted(hasGoal: true)
        analyzer.sessionStarted(hasGoal: true)
        XCTAssertEqual(applier.reminders, ["hard first"], "first session of the day only")
    }

    func test_calendarFix_needsTheOK() throws {
        let analyzer = makeAnalyzer(freshDefaults())
        let fix = AnalyzerFix(cause: .meetings, change: .protectBlock(minutes: 50), measure: .deepBlocks)
        XCTAssertFalse(analyzer.start(fix, plan: "plan", seed: 7, calendarOK: false))
        XCTAssertNotNil(analyzer.problem)
        XCTAssertNil(analyzer.state.experiment)
        XCTAssertTrue(analyzer.start(fix, plan: "plan", seed: 7, calendarOK: true))
    }

    func test_erase_undoesARunningTest_keepsKeptFixes() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        let firstOn = try XCTUnwrap(analyzer.state.experiment?.slots.first { $0.arm == .on })
        clock = firstOn.day.addingTimeInterval(9 * 3600)
        await analyzer.refresh()
        analyzer.correct(.habit)
        await analyzer.erase()
        XCTAssertEqual(applier.undone.count, 1)
        XCTAssertNil(analyzer.state.experiment)
        XCTAssertTrue(analyzer.state.corrections.isEmpty)
    }

    // MARK: - Undoing restores what was there

    func test_liveMorningPlan_restoresExactlyWhatWasThere_evenNothing() throws {
        let defaults = freshDefaults()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let limits = DailyLimitsEngine(context: container.mainContext, notifier: DailyLimitsEngineTests.RecordingNotifier(),
                                       overlay: EscalationEngineTests.StubOverlay(), policy: { .standard }, calendar: calendar, now: F.at(0, 9))
        let coach = LiveCoachApplier(limits: limits, preset: { .standard }, defaults: defaults, canReadCalendar: { false })

        let unset = try XCTUnwrap(coach.apply(.earlierMorningPlan(hour: 8), until: nil))
        XCTAssertEqual(defaults.integer(forKey: HabitSettings.morningPlanHour), 8)
        coach.undo(unset, weekOver: true)
        XCTAssertNil(defaults.object(forKey: HabitSettings.morningPlanHour))
        XCTAssertNil(defaults.object(forKey: HabitSettings.morningPlan))

        defaults.set(10, forKey: HabitSettings.morningPlanHour)
        defaults.set(false, forKey: HabitSettings.morningPlan)
        let set = try XCTUnwrap(coach.apply(.earlierMorningPlan(hour: 9), until: nil))
        coach.undo(set, weekOver: true)
        XCTAssertEqual(defaults.integer(forKey: HabitSettings.morningPlanHour), 10)
        XCTAssertEqual(defaults.object(forKey: HabitSettings.morningPlan) as? Bool, false)

        let limit = try XCTUnwrap(coach.apply(.siteLimit(host: "x.com", minutes: 20), until: nil))
        XCTAssertEqual(limits.statuses.map(\.target), ["x.com"])
        coach.undo(limit, weekOver: true)
        XCTAssertTrue(limits.statuses.isEmpty, "even on Strict, a test's end takes it off")
    }

    // MARK: - Plan gating

    func test_gating() {
        XCTAssertTrue(ProFeature.allCases.contains(.analyzer))
        XCTAssertFalse(AnalyzerAccess.isOpen(shipped: true, unlocked: false))
        XCTAssertFalse(AnalyzerAccess.isOpen(shipped: false, unlocked: true))
        XCTAssertTrue(AnalyzerAccess.isOpen(shipped: true, unlocked: true))
        XCTAssertEqual(MainTab.shown.firstIndex(of: .analyzer), MainTab.shown.firstIndex(of: .reports).map { $0 + 1 })
    }

    func test_locked_noTestStarts_andARunningOneComesOff() async throws {
        let analyzer = makeAnalyzer(freshDefaults())
        unlocked = false
        XCTAssertFalse(analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false))
        XCTAssertNil(analyzer.state.experiment)

        unlocked = true
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        let firstOn = try XCTUnwrap(analyzer.state.experiment?.slots.first { $0.arm == .on })
        clock = firstOn.day.addingTimeInterval(9 * 3600)
        await analyzer.refresh()
        XCTAssertNotNil(analyzer.state.applied)
        unlocked = false
        await analyzer.refresh()
        XCTAssertNil(analyzer.state.applied, "the trial ended: nothing stays changed")
        analyzer.sessionStarted(hasGoal: false)
        XCTAssertEqual(applier.goalAsks, 0)
    }

    // MARK: - One experiment at a time, with the coach

    private func runningTrial() -> CoachTrial {
        CoachTrial(experiment: .sessionLength(minutes: 25), week: DateInterval(start: F.at(0, 0), end: F.at(7, 0)),
                   appliedAt: F.at(0, 1), kept: false, undo: .rule(UUID()))
    }

    func test_analyzerWontStart_whileTheCoachRuns() throws {
        let defaults = freshDefaults()
        let analyzer = makeAnalyzer(defaults)
        var coach = CoachState()
        coach.running = runningTrial()
        defaults.set(try JSONEncoder().encode(coach), forKey: WeeklyCoach.stateKey)
        XCTAssertFalse(analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false))
        XCTAssertNotNil(analyzer.problem)

        coach.running = nil
        coach.monthTrials = [runningTrial()]
        defaults.set(try JSONEncoder().encode(coach), forKey: WeeklyCoach.stateKey)
        XCTAssertFalse(analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false), "the month review's too")

        coach.monthTrials = nil
        coach.kept = [runningTrial()]
        defaults.set(try JSONEncoder().encode(coach), forKey: WeeklyCoach.stateKey)
        XCTAssertTrue(analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false), "a kept change isn't running")
    }

    func test_coachWontStart_whileTheAnalyzerRuns() throws {
        let defaults = freshDefaults()
        let analyzer = makeAnalyzer(defaults)
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        XCTAssertTrue(AnalyzerGate.analyzerRunning(defaults))

        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let limits = DailyLimitsEngine(context: container.mainContext, notifier: DailyLimitsEngineTests.RecordingNotifier(),
                                       overlay: EscalationEngineTests.StubOverlay(), policy: { .standard }, calendar: calendar, now: F.at(0, 9))
        let coach = WeeklyCoach(defaults: defaults, calendar: calendar)
        coach.applier = LiveCoachApplier(limits: limits, preset: { .standard }, defaults: defaults, canReadCalendar: { false })
        coach.isUnlocked = { true }
        coach.now = { F.at(0, 10) }

        XCTAssertFalse(coach.tryForMonth(.siteLimit(host: "x.com", minutes: 20), baseline: nil,
                                         until: DateInterval(start: F.at(0, 0), end: F.at(28, 0))))
        XCTAssertNotNil(coach.monthProblem)
        XCTAssertTrue(limits.statuses.isEmpty)
    }

    func test_coachStartsAgain_onceTheAnalyzerStopped() async throws {
        let defaults = freshDefaults()
        let analyzer = makeAnalyzer(defaults)
        analyzer.start(goalFix, plan: "plan", seed: 7, calendarOK: false)
        await analyzer.stop()
        XCTAssertFalse(AnalyzerGate.analyzerRunning(defaults))
        XCTAssertFalse(AnalyzerGate.coachRunning(defaults))
    }
}
