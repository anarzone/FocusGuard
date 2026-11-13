import XCTest
@testable import FocusGuard

/// The three pattern cards' numbers, and the triggers over a shorter range.
@MainActor
final class AnalyzerPatternTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar

    private func event(_ day: Int, _ h: Int, _ m: Int, _ minutes: Double, _ kind: Classification, _ target: String,
                       session: UUID? = nil, bundleId: String? = nil) -> CoachEvent {
        let start = F.at(day, h, m)
        return CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: kind, target: target, name: target,
                          isSite: target.contains(".") && !target.hasPrefix("com."), session: session, bundleId: bundleId)
    }

    func testASessionKnowsWhenItsFirstDriftCame() {
        let id = UUID()
        let session = CoachSession(id: id, start: F.at(0, 14), end: F.at(0, 15), plannedMinutes: 60)
        let day = AnalyzerDayBuilder.make(day: F.at(0, 0), events: [
            event(0, 14, 0, 32, .focus, "com.xcode", session: id),
            event(0, 14, 32, 4, .distraction, "x.com", session: id),
            event(0, 14, 36, 24, .focus, "com.xcode", session: id),
        ], sessions: [session], calendar: calendar)
        XCTAssertEqual(day.sessions.first?.brokeAt ?? 0, 32 * 60, accuracy: 1)
    }

    func testTimeIsSplitByTheHourItFallsIn() {
        let day = AnalyzerDayBuilder.make(day: F.at(0, 0), events: [
            event(0, 9, 30, 60, .focus, "com.xcode"),
            event(0, 10, 30, 30, .neutral, "com.notes"),
        ], calendar: calendar)
        XCTAssertEqual(day.hourFocus[9] ?? 0, 30 * 60, accuracy: 1)
        XCTAssertEqual(day.hourFocus[10] ?? 0, 30 * 60, accuracy: 1)
        XCTAssertEqual(day.hourTracked[10] ?? 0, 60 * 60, accuracy: 1)
    }

    func testTheWayBackAfterACallIsTimed() {
        let calls = [DateInterval(start: F.at(0, 11), end: F.at(0, 11, 30))]
        let segments = AnalyzerDayBuilder.segments([
            event(0, 11, 30, 12, .neutral, "com.notes"),
            event(0, 11, 42, 40, .focus, "com.xcode"),
        ], in: DateInterval(start: F.at(0, 0), end: F.at(1, 0)))
        XCTAssertEqual(AnalyzerDayBuilder.afterCalls(calls, segments: segments), [12 * 60])
        let twoCalls = calls + [DateInterval(start: F.at(0, 11, 35), end: F.at(0, 11, 40))]
        XCTAssertEqual(AnalyzerDayBuilder.afterCalls(twoCalls, segments: segments).count, 1, "Another call first: that one counts instead")
    }

    func testPatternsNameOnlyWhatTheyHaveEnoughFor() {
        var day = AnalyzerDay(day: F.at(0, 0))
        day.sessions = (0..<9).map { _ in AnalyzerSessionStat(hasGoal: false, longest: 0, brokeAt: 32 * 60) }
        day.hourFocus = [9: 150 * 60, 10: 135 * 60, 14: 30 * 60]
        day.hourTracked = [9: 180 * 60, 10: 180 * 60, 14: 180 * 60, 15: 60 * 60]
        day.afterCalls = [600, 720, 540, 690]
        day.returns = [300, 420, 360]
        var patterns = AnalyzerPatterns.make([day])
        XCTAssertNil(patterns.commonBreak, "Nine sessions isn't enough")
        XCTAssertNil(patterns.afterCall, "Four calls isn't enough")
        XCTAssertEqual(patterns.afterDrift, 360)
        XCTAssertEqual(patterns.bestHours?.hour, 9)
        XCTAssertNil(patterns.hourRates[15 - AnalyzerPatterns.firstHour], "An hour across four weeks says nothing")

        day.sessions.append(AnalyzerSessionStat(hasGoal: false, longest: 0, brokeAt: 33 * 60))
        day.afterCalls.append(660)
        patterns = AnalyzerPatterns.make([day])
        XCTAssertEqual(patterns.commonBreak, 6, "Minute 30 to 35")
        XCTAssertEqual(patterns.afterCall, 660)
    }

    func testABreakTimeIsNamedOnlyWhenOneStandsOut() {
        var day = AnalyzerDay(day: F.at(0, 0))
        // Spread across the hour: no slice holds a quarter, none leads by two.
        day.sessions = [5, 12, 17, 23, 28, 33, 38, 44, 49, 54, 8, 40].map {
            AnalyzerSessionStat(hasGoal: false, longest: 0, brokeAt: TimeInterval($0 * 60))
        }
        var patterns = AnalyzerPatterns.make([day])
        XCTAssertTrue(patterns.hasBreaks)
        XCTAssertNil(patterns.commonBreak, "No one time")
        day.sessions += (0..<4).map { _ in AnalyzerSessionStat(hasGoal: false, longest: 0, brokeAt: 31 * 60) }
        patterns = AnalyzerPatterns.make([day])
        XCTAssertEqual(patterns.commonBreak, 6, "Minute 30 to 35 now holds 5 of 16")
    }

    func testBestHoursAreNamedOnlyWhenTheyBeatTheDay() {
        var day = AnalyzerDay(day: F.at(0, 0))
        let hours = Array(AnalyzerPatterns.firstHour..<AnalyzerPatterns.lastHour)
        day.hourTracked = Dictionary(uniqueKeysWithValues: hours.map { ($0, 180.0 * 60) })
        day.hourFocus = Dictionary(uniqueKeysWithValues: hours.map { ($0, ($0 == 9 || $0 == 10 ? 130.0 : 120.0) * 60) })
        var patterns = AnalyzerPatterns.make([day])
        XCTAssertNil(patterns.bestHours, "A few points better is no best time")
        XCTAssertEqual(patterns.overallRate ?? 0, 0.67, accuracy: 0.01)
        day.hourFocus[9] = 175 * 60
        day.hourFocus[10] = 170 * 60
        patterns = AnalyzerPatterns.make([day])
        XCTAssertEqual(patterns.bestHours?.hour, 9)
    }

    func testAProjectsWeekCountsEachDaysWaits() {
        let now = F.at(6, 18)
        let records = [
            WaitRecord(start: F.at(6, 10), tool: "Codex", project: "Curiplay", seconds: 90, drift: 0),
            WaitRecord(start: F.at(6, 11), tool: "Codex", project: "Curiplay", seconds: 600, drift: 500, to: "x.com"),
            WaitRecord(start: F.at(4, 10), tool: "Codex", project: "Curiplay", seconds: 90, drift: 0),
            WaitRecord(start: F.at(0, 10), tool: "Codex", project: "Curiplay", seconds: 90, drift: 0),
        ]
        let summary = AnalyzerWaitsSummary.make(records, now: now, calendar: calendar)
        let week = try? XCTUnwrap(summary.projects.first?.byDay)
        XCTAssertEqual(week?.count, 7)
        XCTAssertEqual(week?.last?.stayed, 1, "Today: one stayed with")
        XCTAssertEqual(week?.last?.drifted, 1, "and one drifted")
        XCTAssertEqual(week?[4].stayed, 1, "Two days ago")
        XCTAssertEqual(week?.first?.stayed, 1, "Six days ago is the first bar")
        XCTAssertEqual(summary.firstDay, calendar.startOfDay(for: F.at(0, 12)))
    }

    func testTriggersOverAShorterRangeKeepOnlyItsMoments() {
        let now = F.at(10, 12)
        let old = AnalyzerTrigger.Moment(start: F.at(1, 10), seconds: 600)
        let recent = [F.at(7, 10), F.at(8, 10), F.at(9, 10)].map { AnalyzerTrigger.Moment(start: $0, seconds: 300) }
        let trigger = AnalyzerTrigger(id: "a", steps: [.init(label: "x.com", kind: .site)], moments: recent + [old], perDay: [])
        let week = AnalyzerTriggers.recent([trigger], days: 7, now: now, calendar: calendar)
        XCTAssertEqual(week.first?.count, 3)
        XCTAssertEqual(week.first?.perDay.count, 7)
        XCTAssertEqual(week.first?.perDay.reduce(0, +), 3)
        XCTAssertEqual(AnalyzerTriggers.recent([trigger], days: 1, now: now, calendar: calendar), [], "Once isn't a pattern")
    }
}
