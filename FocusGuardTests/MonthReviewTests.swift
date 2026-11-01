import XCTest
@testable import FocusGuard

extension CoachFixture {
    /// 1–10 September and 1–10 October, two sessions a day. October's
    /// mornings rose from 70% to 90%; its afternoons fell from 80% to 70%,
    /// the drift on youtube.com; sessions went from 40 to 50 minutes.
    static func septemberAndOctober() -> CoachFixture {
        var f = CoachFixture()
        for date in 1...10 {
            let september = date - 49, october = date - 19
            f.session(september, 9, 0, [(.focus, 28, "xcode"), (.distraction, 12, "x.com")])
            f.session(september, 14, 0, [(.focus, 32, "xcode"), (.distraction, 8, "x.com")])
            f.session(october, 9, 0, [(.focus, 45, "xcode"), (.distraction, 5, "x.com")])
            f.session(october, 14, 0, [(.focus, 35, "xcode"), (.distraction, 15, "youtube.com")])
        }
        return f
    }

    static var october: DateInterval { calendar.dateInterval(of: .month, for: at(0, 0))! }
    static var september: DateInterval { calendar.dateInterval(of: .month, for: at(-30, 0))! }
    static var november: DateInterval { calendar.dateInterval(of: .month, for: at(20, 0))! }
}

/// The month in review: facts by fixed rules, the suggestions, and the
/// experiments that ran.
final class MonthReviewTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar
    let locale = CoachFixture.locale

    private func months(_ fixture: CoachFixture = F.septemberAndOctober()) -> (october: CoachData, september: CoachData) {
        let all = fixture.data(from: -60, to: 28)
        return (all.clipped(to: F.october), all.clipped(to: F.september))
    }

    // MARK: - Facts

    func test_facts_compareTheMonthWithTheOneBefore() throws {
        let (october, september) = months()
        let facts = try XCTUnwrap(MonthFacts.make(october, before: september, locale: locale, calendar: calendar))
        XCTAssertEqual(facts.headline, "October: 13h 20m focused at an 80% focus rate, 5 points up on September.")
        XCTAssertEqual(facts.changes.map(\.sentence), [
            "Mornings got stronger. Before noon rose from 70% to 90%.",
            "Afternoons slipped. You drifted 1h 10m more between 12:00 and 17:00, most of it on youtube.com.",
            "Sessions got longer. 50 minutes on average, up from 40.",
        ])
        XCTAssertEqual(facts.changes.map(\.tone), [.focus, .drift, .focus])
        XCTAssertEqual(facts.facts.first, facts.headline)
    }

    func test_facts_withNothingToCompare_sayWhatWentBest() throws {
        let (october, _) = months()
        let facts = try XCTUnwrap(MonthFacts.make(october, before: .empty(F.september), locale: locale, calendar: calendar))
        XCTAssertEqual(facts.headline, "October: 13h 20m focused at an 80% focus rate.")
        XCTAssertEqual(facts.changes.map(\.sentence), [
            "Mornings were your strongest. Before noon ran at 90%.",
            "youtube.com was your top distraction. 2h 30m this month.",
        ])
    }

    func test_facts_needAnHourTracked() {
        var f = CoachFixture()
        f.session(-15, 9, 0, [(.focus, 40, "a")])
        let (october, september) = months(f)
        XCTAssertNil(MonthFacts.make(october, before: september, locale: locale, calendar: calendar))
    }

    func test_facts_whenTheMonthSlippedOverall() throws {
        // September as the month, against October as the one before: everything turns round.
        let (october, september) = months()
        let facts = try XCTUnwrap(MonthFacts.make(september, before: october, locale: locale, calendar: calendar))
        XCTAssertEqual(facts.headline, "September: 10h focused at a 75% focus rate, 5 points down on October.")
        XCTAssertEqual(facts.changes.last?.sentence, "Sessions got shorter. 40 minutes on average, down from 50.")
    }

    func test_article() {
        XCTAssertEqual(MonthFacts.withArticle("80%"), "an 80%")
        XCTAssertEqual(MonthFacts.withArticle("8%"), "an 8%")
        XCTAssertEqual(MonthFacts.withArticle("11%"), "an 11%")
        XCTAssertEqual(MonthFacts.withArticle("18%"), "an 18%")
        XCTAssertEqual(MonthFacts.withArticle("75%"), "a 75%")
        XCTAssertEqual(MonthFacts.withArticle("1%"), "a 1%")
    }

    // MARK: - Suggestions

    func test_suggestions_comeFromTheMonthsStrongestPattern() throws {
        let (october, _) = months()
        let suggestions = MonthReviewBuilder.suggestions(october, settings: CoachSettings(), weekendsCount: false,
                                                         morningHour: 9, locale: locale, calendar: calendar)
        let first = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(first.experiment, .shorterSessions(.afternoon, minutes: 25))
        XCTAssertEqual(first.reason, "Your sessions between 12:00 and 17:00 are where focus slips.")
        XCTAssertEqual(first.baseline ?? 0, 0.7, accuracy: 0.001)
    }

    func test_suggestions_skipWhatsAlreadyOn() {
        let (october, _) = months()
        let settings = CoachSettings(inPlace: [.shorterSessions(.afternoon, minutes: 25)])
        let suggestions = MonthReviewBuilder.suggestions(october, settings: settings, weekendsCount: false,
                                                         morningHour: 9, locale: locale, calendar: calendar)
        XCTAssertEqual(suggestions.map(\.experiment), [.stricterPreset(.afternoon, .strict)])
    }

    func test_aDayThatDriftedIsNamedInFull() {
        let finding = CoachFinding.driftDay(.init(day: F.at(3, 0), drift: 7200, othersAverage: 1200, target: "youtube.com",
                                                  name: "youtube.com", isSite: true, targetSeconds: 5400, dailySeconds: 1800))
        let reason = MonthReviewBuilder.reason(for: finding, locale: locale, calendar: calendar)
        XCTAssertTrue(reason.hasPrefix("Thursday"), reason)
        XCTAssertTrue(reason.contains("22 October"), reason)
        XCTAssertTrue(reason.hasSuffix(" drifted most, 1h 30m of it on youtube.com."), reason)
    }

    // MARK: - Experiments that ran

    private func trial(_ experiment: CoachExperiment, week start: Int, before: Double?, after: Double?) -> CoachTrial {
        CoachTrial(experiment: experiment, before: before, after: after,
                   week: DateInterval(start: F.at(start, 0), end: F.at(start + 7, 0)),
                   appliedAt: F.at(start, 10), kept: false, undo: .rule(UUID()))
    }

    func test_trials_listWhatRanInTheMonth_withHowItWent() {
        let kept = trial(.siteLimit(host: "x.com", minutes: 15), week: -14, before: 24, after: 8)
        let tooLittle = trial(.earlierMorningPlan(hour: 8), week: -7, before: 600, after: nil)
        let off = trial(.shorterSessions(.evening, minutes: 25), week: 0, before: 0.6, after: 0.69)
        let running = trial(.stricterPreset(.morning, .strict), week: 7, before: 0.8, after: nil)
        let september = trial(.siteLimit(host: "reddit.com", minutes: 20), week: -28, before: 30, after: 20)
        let lines = MonthReviewBuilder.trials([running, off, september, tooLittle, kept], in: F.october,
                                              kept: [kept.id], now: F.at(9, 12), locale: locale, calendar: calendar)
        XCTAssertEqual(lines.map(\.title), ["A 15-minute daily limit on x.com", "The morning plan at 8:00",
                                            "25-minute sessions after 17:00", "Strict before noon"])
        XCTAssertEqual(lines.map(\.result), ["24 → 8 min a day", "Too little to tell", "+9 pts after 17:00", "Still running"])
        XCTAssertEqual(lines.map(\.improved), [true, false, true, false])
        XCTAssertEqual(lines.map(\.status), ["Kept on", "Turned off", "Turned off", "On until 1 November"])
    }

    func test_anEmptyReview() {
        let review = MonthReview.empty(F.october)
        XCTAssertFalse(review.hasData)
        XCTAssertTrue(review.suggestions.isEmpty)
    }
}
