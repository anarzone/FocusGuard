import XCTest
@testable import FocusGuard

/// The evening wrap-up's tip for tomorrow: which rule speaks, what it says,
/// and the session its button plans.
final class EveningTipTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar
    let locale = CoachFixture.locale

    /// Monday: 100 minutes of focus from 09:00, then youtube.com from 15:00
    /// for `youtube` minutes.
    private func monday(youtube: Int = 40) -> CoachData {
        var f = CoachFixture()
        f.session(0, 9, 0, [(.focus, 100, "a")])
        f.loose(F.at(0, 11), minutes: 5, .distraction, "x.com")
        f.loose(F.at(0, 15), minutes: youtube, .distraction, "youtube.com")
        return f.data(from: 0, to: 1)
    }

    private func choose(today: CoachData, recent: CoachData? = nil, gap: Int, tomorrowStart: Date? = nil,
                        now: Date = F.at(0, 21)) -> EveningTip? {
        EveningTip.choose(today: today, recent: recent ?? today, gapMinutes: gap, tomorrowStart: tomorrowStart,
                          sessionMinutes: 50, morningHour: 9, now: now, locale: locale, calendar: calendar)
    }

    // MARK: - A missed goal

    func test_missedGoal_holdsTheHourTheDriftCameFrom() throws {
        let tip = try XCTUnwrap(choose(today: monday(), gap: 60))
        XCTAssertEqual(tip.kind, .driftHour)
        XCTAssertEqual(tip.text, "Most of the gap was youtube.com after 15:00. Tomorrow, a 50-minute session at 15:00 holds that hour.")
        XCTAssertEqual(tip.slot, F.at(1, 15))
        XCTAssertEqual(tip.button, "Plan it for 15:00")
    }

    func test_missedGoal_onlySaysMostOfTheGapWhenItWas() throws {
        let tip = try XCTUnwrap(choose(today: monday(), gap: 120))
        XCTAssertEqual(tip.text, "youtube.com took 40 minutes after 15:00. Tomorrow, a 50-minute session at 15:00 holds that hour.")
    }

    func test_missedGoal_aLittleDrift_fallsBackToTheBestStart() throws {
        let tip = try XCTUnwrap(choose(today: monday(youtube: 15), gap: 60, tomorrowStart: F.at(1, 10)))
        XCTAssertEqual(tip.kind, .bestStart)
        XCTAssertEqual(tip.text, "Best time to start tomorrow: 10:00.")
        XCTAssertEqual(tip.slot, F.at(1, 10))
        XCTAssertEqual(tip.button, "Plan it for 10:00")
    }

    func test_missedGoal_afterALateStart_saysStartEarlier() throws {
        // Two weeks where 09:00 starts focused 4 hours and 11:00 starts 2;
        // today (Wednesday) started at 11:00 too.
        let recent = F.lateStarts().data()
        let today = recent.clipped(to: DateInterval(start: F.at(2, 0), end: F.at(2, 21)))
        let tip = try XCTUnwrap(choose(today: today, recent: recent, gap: 120, now: F.at(2, 21)))
        XCTAssertEqual(tip.kind, .startEarlier)
        XCTAssertEqual(tip.text, "Tomorrow, start before 10:00: your early days focused 2h more.")
        XCTAssertEqual(tip.slot, F.at(3, 9))
        XCTAssertEqual(tip.button, "Plan it for 9:00")
    }

    func test_missedGoal_afterAnEarlyStart_doesntSayStartEarlier() {
        let recent = F.lateStarts().data()
        let today = recent.clipped(to: DateInterval(start: F.at(0, 0), end: F.at(0, 21)))
        XCTAssertNil(choose(today: today, recent: recent, gap: 30))
    }

    // MARK: - A met goal

    func test_metGoal_saysStartEarlier_andPlansTomorrowMorning() throws {
        let recent = F.lateStarts().data()
        let today = recent.clipped(to: DateInterval(start: F.at(0, 0), end: F.at(0, 21)))
        let tip = try XCTUnwrap(choose(today: today, recent: recent, gap: 0, tomorrowStart: F.at(1, 8, 30)))
        XCTAssertEqual(tip.kind, .startEarlier)
        XCTAssertEqual(tip.button, "Plan tomorrow")
        // The best time to start is early enough, so it's the one planned.
        XCTAssertEqual(tip.slot, F.at(1, 8, 30))
    }

    func test_metGoal_ignoresTodaysDrift() throws {
        let tip = try XCTUnwrap(choose(today: monday(), gap: -10, tomorrowStart: F.at(1, 10)))
        XCTAssertEqual(tip.kind, .bestStart)
    }

    func test_nothingToGoOn_noTip() {
        XCTAssertNil(choose(today: .empty(DateInterval(start: F.at(0, 0), end: F.at(1, 0))), gap: 60))
    }

    // MARK: - The notification's words

    private let driftTip = EveningTip(kind: .driftHour, text: "Most of the gap was youtube.com after 15:00. Tomorrow, a 50-minute session at 15:00 holds that hour.",
                                      slot: CoachFixture.at(1, 15), button: "Plan it for 15:00")

    func test_wrapUpWithATip_goalMet() {
        let tip = EveningTip(kind: .startEarlier, text: "Tomorrow, start before 10:00: your early days focused 2h more.",
                             slot: F.at(1, 9), button: "Plan tomorrow")
        let wrapUp = EveningWrapUp(focusedMinutes: 192, goalMinutes: 180, streak: 3, best: nil, tomorrowStart: nil,
                                   focusPercent: 86, tip: tip)
        XCTAssertEqual(wrapUp.title, "Day done: goal met")
        XCTAssertEqual(wrapUp.body(locale: locale, calendar: calendar),
                       "3h 12m focused at 86%. That's 3 days in a row. Tomorrow, start before 10:00: your early days focused 2h more.")
    }

    func test_wrapUpWithATip_goalMissed() {
        let wrapUp = EveningWrapUp(focusedMinutes: 100, goalMinutes: 240, streak: 0, best: nil, tomorrowStart: nil,
                                   focusPercent: 70, tip: driftTip)
        XCTAssertEqual(wrapUp.title, "Day done: 1h 40m of 4h")
        XCTAssertEqual(wrapUp.body(locale: locale, calendar: calendar), driftTip.text)
    }

    func test_wrapUpWithJustTheBestStart_keepsTheBestStretch() {
        let tip = EveningTip(kind: .bestStart, text: "Best time to start tomorrow: 10:00.", slot: F.at(1, 10), button: "Plan it for 10:00")
        let wrapUp = EveningWrapUp(focusedMinutes: 100, goalMinutes: 240, streak: 0,
                                   best: .init(name: "Comeback Run", start: F.at(0, 14, 5), end: F.at(0, 14, 55)),
                                   tomorrowStart: F.at(1, 10), tip: tip)
        XCTAssertEqual(wrapUp.body(locale: locale, calendar: calendar),
                       "Best stretch: Comeback Run, 14:05–14:55. Best time to start tomorrow: 10:00.")
    }

    func test_planItButton_plansTheSession() {
        let slot = F.at(1, 15)
        XCTAssertEqual(NotificationCommand(action: NotificationAction.planThem.rawValue, category: "wrapUp|Plan it for 15:00",
                                           info: [NotificationInfo.slots: [slot.timeIntervalSinceReferenceDate]]),
                       .planSessions([slot]))
    }
}
