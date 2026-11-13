import XCTest
@testable import FocusGuard

/// What the causes leave out: distractions right after the last focused
/// stretch, and days with no focused stretch at all. Synthetic days only.
@MainActor
final class AnalyzerLeftOutTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar

    private func event(_ day: Int, _ h: Int, _ m: Int, _ minutes: Double, _ kind: Classification, _ target: String) -> CoachEvent {
        let start = F.at(day, h, m)
        return CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: kind, target: target, name: target,
                          isSite: target.contains(".") && !target.hasPrefix("com."), session: nil, bundleId: nil)
    }

    /// Two hours of focus with ten minutes lost between, then `after`
    /// minutes of x.com `gap` minutes after the last stretch ends at 12:10.
    private func day(_ day: Int, after: Double = 0, gap: Int = 5) -> AnalyzerDay {
        var events = [event(day, 9, 0, 60, .focus, "com.xcode"), event(day, 10, 0, 10, .distraction, "x.com"),
                      event(day, 10, 10, 120, .focus, "com.xcode")]
        if after > 0 { events.append(event(day, 12, 10 + gap, after, .distraction, "x.com")) }
        return AnalyzerDayBuilder.make(day: F.at(day, 0), events: events, calendar: calendar)
    }

    private var period: DateInterval { DateInterval(start: F.at(0, 0), end: F.at(7, 0)) }

    // MARK: The day

    func testDistractionsRightAfterTheLastStretchAreCountedApart() {
        let plain = day(0)
        XCTAssertTrue(plain.hasFocus)
        XCTAssertEqual(plain.afterLast, 0)
        XCTAssertEqual(plain.losses.map(\.seconds), [10 * 60], "Between stretches, as before")
        let late = day(0, after: 40)
        XCTAssertEqual(late.afterLast, 40 * 60)
        XCTAssertEqual(late.losses.map(\.seconds), [10 * 60], "Not lost between stretches: no stretch came after")
        XCTAssertEqual(late.distraction, 50 * 60)
    }

    func testOnlyTheTwoHoursAfterItCount() {
        // From 13:10 to 14:40: 60 minutes fall inside the two hours after 12:10.
        XCTAssertEqual(day(0, after: 90, gap: 60).afterLast, 60 * 60)
        XCTAssertEqual(day(0, after: 30, gap: 180).afterLast, 0, "The evening is its own")
    }

    func testADayWithNoFocusedStretchHasNoneOfThis() {
        // Never two minutes of focus in a row.
        let blank = AnalyzerDayBuilder.make(day: F.at(0, 0), events: [
            event(0, 9, 0, 1, .focus, "com.xcode"), event(0, 9, 1, 90, .distraction, "x.com"),
            event(0, 10, 31, 1, .focus, "com.xcode"),
        ], calendar: calendar)
        XCTAssertFalse(blank.hasFocus)
        XCTAssertEqual(blank.losses, [])
        XCTAssertEqual(blank.afterLast, 0)
        XCTAssertEqual(blank.distraction, 90 * 60)
    }

    // MARK: The period

    func testThePeriodAddsUpEachKind() {
        let days = [day(0, after: 40), day(1), day(2, after: 20)]
        let quiet = [AnalyzerQuietDay(day: F.at(3, 0), tracked: 4 * 3600, distraction: 3 * 3600)]
        let out = AnalyzerLeftOut.make(period: period, days: days, quiet: quiet, weekendsCount: false, calendar: calendar)
        XCTAssertEqual(out.days.count, 7)
        XCTAssertEqual(out.between, 30 * 60)
        XCTAssertEqual(out.after, 60 * 60)
        XCTAssertEqual(out.afterDays, 2)
        XCTAssertEqual(out.awayDays, 1)
        XCTAssertEqual(out.away, 3 * 3600)
        XCTAssertEqual(out.workingDays, 3)
        let total: TimeInterval = 30 * 60 + 60 * 60 + 3 * 3600
        XCTAssertEqual(out.total, total)
        XCTAssertEqual(out.days.map(\.isOff), [false, false, false, false, true, true, true])
        XCTAssertTrue(out.isWorthShowing)
    }

    func testALightDayOrAWeekendIsntADayThatGotAway() {
        let light = AnalyzerQuietDay(day: F.at(3, 0), tracked: 2 * 3600, distraction: 10 * 60)
        let saturday = AnalyzerQuietDay(day: F.at(5, 0), tracked: 5 * 3600, distraction: 4 * 3600)
        let short = AnalyzerQuietDay(day: F.at(4, 0), tracked: 40 * 60, distraction: 35 * 60)
        let out = AnalyzerLeftOut.make(period: period, days: [], quiet: [light, saturday, short], weekendsCount: false, calendar: calendar)
        XCTAssertEqual(out.awayDays, 0)
        let weekends = AnalyzerLeftOut.make(period: period, days: [], quiet: [saturday], weekendsCount: true, calendar: calendar)
        XCTAssertEqual(weekends.awayDays, 1, "Weekends count when they're switched on")
    }

    func testAWorkingDayWithNoSolidStretchGotAwayToo() {
        // An hour tracked, a minute of focus at a time between x.com.
        var events: [CoachEvent] = []
        for index in 0..<6 {
            let hour: Int = 9 + index / 2, minute: Int = (index % 2) * 30
            events.append(event(1, hour, minute, 1, .focus, "com.xcode"))
            events.append(event(1, hour, minute + 1, 10, .distraction, "x.com"))
        }
        events.append(event(1, 12, 0, 10, .neutral, "com.finder"))
        let blank = AnalyzerDayBuilder.make(day: F.at(1, 0), events: events, calendar: calendar)
        XCTAssertFalse(blank.hasFocus, "No stretch long enough")
        let out = AnalyzerLeftOut.make(period: period, days: [blank], quiet: [], weekendsCount: false, calendar: calendar)
        XCTAssertEqual(out.awayDays, 1)
        XCTAssertEqual(out.away, 60 * 60)
    }

    func testALittleLeftOutIsntWorthACard() {
        let once = AnalyzerLeftOut.make(period: period, days: [day(0, after: 50)], quiet: [], weekendsCount: false, calendar: calendar)
        XCTAssertFalse(once.isWorthShowing, "One day is no pattern")
        let small = AnalyzerLeftOut.make(period: period, days: [day(0, after: 10), day(1, after: 10)], quiet: [], weekendsCount: false, calendar: calendar)
        XCTAssertFalse(small.isWorthShowing, "Twenty minutes in a period")
        XCTAssertFalse(AnalyzerLeftOut().isWorthShowing)
    }

    func testTheReportCarriesItWithoutWhatsFine() {
        let days = (0..<5).map { day($0, after: 30) }
        let report = AnalyzerReport.make(period: period, days: days, before: [], muted: [], weekendsCount: false, calendar: calendar)
        XCTAssertEqual(report.leftOut.after, 5 * 30 * 60)
        XCTAssertEqual(report.leftOut.between, 5 * 10 * 60)
        let taught = AnalyzerReport.make(period: period, days: days, before: [], muted: [], weekendsCount: false,
                                         lessons: AnalyzerLessons(fine: ["com.xcode>x.com"]), calendar: calendar)
        XCTAssertEqual(taught.leftOut.between, 0, "What the user said is fine isn't lost")
        XCTAssertEqual(taught.leftOut.after, 5 * 30 * 60)
    }

    // MARK: The words

    private var sample: AnalyzerLeftOut {
        AnalyzerLeftOut.make(period: period, days: [day(0, after: 40), day(1), day(2, after: 20)],
                             quiet: [AnalyzerQuietDay(day: F.at(3, 0), tracked: 4 * 3600, distraction: 3 * 3600)],
                             weekendsCount: false, calendar: calendar)
    }

    func testTheHeadlineSaysHowMuchMoreThereIs() {
        XCTAssertEqual(AnalyzerLeftOutCopy.headline(sample), "4h on distractions outside your focused stretches",
                       "Facts only: the evening isn't called lost")
    }

    func testTheBodyNamesEachKindAndWhenTheBlankDaysCostMore() {
        XCTAssertEqual(AnalyzerLeftOutCopy.body(sample),
                       "The causes only count the time between two focused stretches. On 2 days, 1h more went to distractions in the 2 hours after your last stretch. One day had no focused stretch at all, with 3h on distractions.")
        let afterOnly = AnalyzerLeftOut.make(period: period, days: [day(0, after: 40)], quiet: [], weekendsCount: false, calendar: calendar)
        XCTAssertEqual(AnalyzerLeftOutCopy.body(afterOnly),
                       "The causes only count the time between two focused stretches. On one day, 40m more went to distractions in the 2 hours after your last stretch.")
    }

    func testEachDayTellsItsOwnStory() {
        let days = sample.days
        XCTAssertEqual(AnalyzerLeftOutCopy.story(days[0], calendar: calendar, locale: F.locale),
                       "Mon 19: 3h focused, 10m lost between stretches. 40m more on distractions after the last one.")
        XCTAssertEqual(AnalyzerLeftOutCopy.story(days[1], calendar: calendar, locale: F.locale), "Tue 20: 3h focused, 10m lost between stretches.")
        XCTAssertEqual(AnalyzerLeftOutCopy.story(days[3], calendar: calendar, locale: F.locale), "Thu 22: no focused stretch, and 3h on distractions.")
        XCTAssertEqual(AnalyzerLeftOutCopy.story(days[5], calendar: calendar, locale: F.locale), "Sat 24: not a working day.")
    }

    func testTheTilesSayWhatEachPartIs() {
        let tiles = AnalyzerLeftOutCopy.tiles(sample)
        XCTAssertEqual(tiles.map(\.value), ["30m", "1h", "1 day · 3h"])
        XCTAssertEqual(tiles[1].note, "On 2 of 3 days, about 30m each, in the 2 hours after it.")
        XCTAssertEqual(tiles.map(\.isLeftOut), [false, true, true])
        let clean = AnalyzerLeftOutCopy.tiles(AnalyzerLeftOut.make(period: period, days: [day(0)], quiet: [], weekendsCount: false, calendar: calendar))
        XCTAssertEqual(clean.map(\.value), ["10m", "0m", "0"])
        XCTAssertEqual(clean[2].note, "Every working day had at least one focused stretch.")
    }
}
