import XCTest
@testable import FocusGuard

/// A week of plain coach data, built session by session.
struct CoachFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()
    static let locale = Locale(identifier: "en_GB")
    /// Monday 19 Oct 2026, 00:00 UTC.
    static let monday = Date(timeIntervalSince1970: 1_792_368_000)

    var events: [CoachEvent] = []
    var sessions: [CoachSession] = []

    /// `day` 0 is Monday 19 Oct; 7 is the Monday after.
    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        monday.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3_600 + minute * 60))
    }

    /// A session made of blocks, one after another.
    @discardableResult
    mutating func session(_ day: Int, _ hour: Int, _ minute: Int = 0,
                          _ blocks: [(Classification, Int, String)]) -> CoachSession {
        let id = UUID()
        var cursor = Self.at(day, hour, minute)
        let start = cursor
        for (kind, minutes, target) in blocks {
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            events.append(CoachEvent(start: cursor, end: end, kind: kind, target: target, name: target,
                                     isSite: target.contains("."), session: id))
            cursor = end
        }
        let session = CoachSession(id: id, start: start, end: cursor, plannedMinutes: Int(cursor.timeIntervalSince(start) / 60))
        sessions.append(session)
        return session
    }

    /// Time outside sessions.
    mutating func loose(_ start: Date, minutes: Int, _ kind: Classification, _ target: String) {
        events.append(CoachEvent(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), kind: kind,
                                 target: target, name: target, isSite: target.contains("."), session: nil))
    }

    func data(from: Int = 0, to: Int = 7) -> CoachData {
        CoachData(interval: DateInterval(start: Self.at(from, 0), end: Self.at(to, 0)),
                  events: events.sorted { $0.start < $1.start }, sessions: sessions.sorted { $0.start < $1.start })
    }

    // MARK: - Weeks with one clear pattern

    /// Mornings at 90%; evenings at 60%, their drift all after minute 30.
    static func lateEveningDrift(week: Int = 0, eveningDrift: Int = 20) -> CoachFixture {
        var f = CoachFixture()
        for day in 0..<3 {
            f.session(week * 7 + day, 9, 0, [(.focus, 45, "com.apple.dt.Xcode"), (.distraction, 5, "x.com")])
            f.session(week * 7 + day, 18, 0, [(.focus, 50 - eveningDrift, "com.apple.dt.Xcode"), (.distraction, eveningDrift, "x.com")])
        }
        return f
    }

    /// x.com opened within a minute or two of 4 of 5 sessions ending, 30 minutes each time.
    static func xAfterSessions(week: Int = 0, visit: Int = 30) -> CoachFixture {
        var f = CoachFixture()
        for day in 0..<5 {
            let s = f.session(week * 7 + day, 10, 0, [(.focus, 50, "com.apple.dt.Xcode")])
            if day < 4 { f.loose(s.end.addingTimeInterval(90), minutes: visit, .distraction, "x.com") }
        }
        return f
    }

    /// Two days starting at 09:00 with 4h focused, three starting at 11:00 with 2h.
    static func lateStarts(week: Int = 0) -> CoachFixture {
        var f = CoachFixture()
        for day in 0..<5 {
            let early = day < 2
            f.session(week * 7 + day, early ? 9 : 11, 0, [(.focus, early ? 120 : 60, "com.apple.dt.Xcode")])
            f.session(week * 7 + day, 15, 0, [(.focus, early ? 120 : 60, "com.apple.dt.Xcode")])
        }
        return f
    }
}

final class CoachPatternTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar
    let locale = CoachFixture.locale

    // MARK: - Time of day

    func test_timeOfDay_findsTheWeakPartOfTheDay() throws {
        let finding = CoachPatternFinder.timeOfDay(F.lateEveningDrift().data(), calendar: calendar)
        guard case .timeOfDay(let f)? = finding else { return XCTFail("expected a time-of-day finding") }
        XCTAssertEqual(f.weak, .evening)
        XCTAssertEqual(f.strong, .morning)
        XCTAssertEqual(f.weakRate, 0.6, accuracy: 0.001)
        XCTAssertEqual(f.strongRate, 0.9, accuracy: 0.001)
        XCTAssertEqual(f.weakSessions, 3)
        XCTAssertEqual(f.lateDriftShare, 1, accuracy: 0.001)
        XCTAssertEqual(f.weakMinutes, 50)
    }

    func test_timeOfDay_needsAGapOf15Points() {
        // Evenings at 80% against mornings at 90%.
        XCTAssertNil(CoachPatternFinder.timeOfDay(F.lateEveningDrift(eveningDrift: 10).data(), calendar: calendar))
    }

    func test_timeOfDay_needsTwoSessionsInEachPart() {
        var f = CoachFixture()
        f.session(0, 9, 0, [(.focus, 45, "a"), (.distraction, 5, "x.com")])
        f.session(1, 9, 0, [(.focus, 45, "a"), (.distraction, 5, "x.com")])
        f.session(0, 18, 0, [(.focus, 20, "a"), (.distraction, 30, "x.com")])
        XCTAssertNil(CoachPatternFinder.timeOfDay(f.data(), calendar: calendar))
    }

    // MARK: - Right after sessions

    func test_afterSessions_findsTheSiteOpenedRightAfter() {
        let finding = CoachPatternFinder.afterSessions(F.xAfterSessions().data(), calendar: calendar)
        guard case .afterSessions(let f)? = finding else { return XCTFail("expected an after-sessions finding") }
        XCTAssertEqual(f.target, "x.com")
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(f.sessions, 5)
        XCTAssertEqual(f.withinMinutes, 3)
        XCTAssertEqual(f.dailySeconds, 24 * 60, accuracy: 1)   // 2h over 5 days
    }

    func test_afterSessions_ignoresVisitsLaterThanThreeMinutes() {
        var f = CoachFixture()
        for day in 0..<5 {
            let s = f.session(day, 10, 0, [(.focus, 50, "a")])
            f.loose(s.end.addingTimeInterval(5 * 60), minutes: 30, .distraction, "x.com")
        }
        XCTAssertNil(CoachPatternFinder.afterSessions(f.data(), calendar: calendar))
    }

    // MARK: - The day that drifted

    func test_driftDay_findsThursday() {
        var f = CoachFixture()
        for day in 0..<5 {
            f.session(day, 10, 0, [(.focus, 50, "a")])
            f.loose(F.at(day, 14), minutes: day == 3 ? 120 : 20, .distraction, day == 3 ? "youtube.com" : "x.com")
        }
        guard case .driftDay(let d)? = CoachPatternFinder.driftDay(f.data(), calendar: calendar) else {
            return XCTFail("expected a drift-day finding")
        }
        XCTAssertEqual(d.day, F.at(3, 0))
        XCTAssertEqual(d.drift, 120 * 60, accuracy: 1)
        XCTAssertEqual(d.othersAverage, 20 * 60, accuracy: 1)
        XCTAssertEqual(d.target, "youtube.com")
        XCTAssertEqual(CoachDraft.headline(for: .driftDay(d), locale: locale, calendar: calendar), "Thursday drifted most.")
    }

    // MARK: - Late starts

    func test_lateStarts_comparesEarlyAndLateDays() {
        guard case .lateStarts(let f)? = CoachPatternFinder.lateStarts(F.lateStarts().data(), calendar: calendar) else {
            return XCTFail("expected a late-starts finding")
        }
        XCTAssertEqual(f.earlyDays, 2)
        XCTAssertEqual(f.lateDays, 3)
        XCTAssertEqual(f.earlyFocus, 4 * 3600, accuracy: 1)
        XCTAssertEqual(f.lateFocus, 2 * 3600, accuracy: 1)
    }

    // MARK: - Ranking and nothing to say

    func test_aSteadyWeekHasNoPattern() {
        var f = CoachFixture()
        for day in 0..<5 {
            f.session(day, 9, 0, [(.focus, 45, "a"), (.distraction, 5, "x.com")])
            f.session(day, 15, 0, [(.focus, 45, "a"), (.distraction, 5, "x.com")])
        }
        XCTAssertTrue(CoachPatternFinder.find(in: f.data(), calendar: calendar).isEmpty)
    }

    func test_findingsComeStrongestFirst() {
        // Evenings 30 points behind mornings, and two hours of YouTube on Thursday.
        var f = F.lateEveningDrift()
        f.loose(F.at(3, 14), minutes: 120, .distraction, "youtube.com")
        let findings = CoachPatternFinder.find(in: f.data(), calendar: calendar)
        XCTAssertEqual(findings.count, 2)
        guard case .timeOfDay? = findings.first, case .driftDay? = findings.last else {
            return XCTFail("expected the time of day first, then Thursday: \(findings)")
        }
        XCTAssertGreaterThan(findings[0].strength, findings[1].strength)
    }

    // MARK: - Experiments

    private func timeOfDay(lateShare: Double, minutes: Int = 50) -> CoachFinding {
        .timeOfDay(.init(weak: .evening, weakRate: 0.6, weakSessions: 3, strong: .morning, strongRate: 0.9,
                         strongSessions: 3, lateDriftShare: lateShare, weakMinutes: minutes))
    }

    func test_lateDriftInLongSessions_suggestsShorterSessions() {
        XCTAssertEqual(CoachPlanner.experiment(for: timeOfDay(lateShare: 0.8), settings: CoachSettings()),
                       .shorterSessions(.evening, minutes: 25))
    }

    func test_driftAllThrough_suggestsTheNextPresetUp() {
        XCTAssertEqual(CoachPlanner.experiment(for: timeOfDay(lateShare: 0.2), settings: CoachSettings(preset: .standard)),
                       .stricterPreset(.evening, .strict))
        XCTAssertEqual(CoachPlanner.experiment(for: timeOfDay(lateShare: 0.2), settings: CoachSettings(preset: .gentle)),
                       .stricterPreset(.evening, .standard))
    }

    func test_onStrict_fallsBackToShorterSessions_orNothing() {
        XCTAssertEqual(CoachPlanner.experiment(for: timeOfDay(lateShare: 0.2), settings: CoachSettings(preset: .strict)),
                       .shorterSessions(.evening, minutes: 25))
        XCTAssertNil(CoachPlanner.experiment(for: timeOfDay(lateShare: 0.2, minutes: 25), settings: CoachSettings(preset: .strict)))
    }

    func test_siteLimit_isAboutSixtyPercentOfDailyUse() throws {
        let finding = try XCTUnwrap(CoachPatternFinder.afterSessions(F.xAfterSessions().data(), calendar: calendar))
        XCTAssertEqual(CoachPlanner.experiment(for: finding, settings: CoachSettings()), .siteLimit(host: "x.com", minutes: 15))
        XCTAssertEqual(CoachPlanner.limit(on: "x.com", dailySeconds: 3 * 3600, settings: CoachSettings()),
                       [.siteLimit(host: "x.com", minutes: 60)])
        XCTAssertEqual(CoachPlanner.limit(on: "x.com", dailySeconds: 10 * 60, settings: CoachSettings()), [])
    }

    func test_neverSuggestsALimitThatsAlreadyThere() throws {
        let finding = try XCTUnwrap(CoachPatternFinder.afterSessions(F.xAfterSessions().data(), calendar: calendar))
        XCTAssertNil(CoachPlanner.experiment(for: finding, settings: CoachSettings(limitedSites: ["x.com"])))
    }

    func test_neverSuggestsALimitOnAnApp() {
        let finding = CoachFinding.afterSessions(.init(target: "com.tinyspeck.slackmacgap", name: "Slack", isSite: false,
                                                       count: 4, sessions: 5, withinMinutes: 3, dailySeconds: 3600))
        XCTAssertNil(CoachPlanner.experiment(for: finding, settings: CoachSettings()))
    }

    func test_lateStarts_movesTheMorningPlanAnHourEarlier() {
        let finding = CoachFinding.lateStarts(.init(cutoff: 600, lateDays: 3, earlyDays: 2, lateFocus: 7200, earlyFocus: 14400))
        XCTAssertEqual(CoachPlanner.experiment(for: finding, settings: CoachSettings(morningPlanHour: 9)), .earlierMorningPlan(hour: 8))
        XCTAssertNil(CoachPlanner.experiment(for: finding, settings: CoachSettings(morningPlanHour: 7)))
    }

    func test_skipsExperimentsThatOverlapOnesInPlace() {
        let settings = CoachSettings(inPlace: [.shorterSessions(CoachHours(from: 18, to: 24), minutes: 25)])
        XCTAssertEqual(CoachPlanner.experiment(for: timeOfDay(lateShare: 0.8), settings: settings), .stricterPreset(.evening, .strict))
    }

    func test_planFallsThroughToTheNextFindingWithAnExperiment() throws {
        let app = CoachFinding.afterSessions(.init(target: "com.slack", name: "Slack", isSite: false,
                                                   count: 5, sessions: 5, withinMinutes: 3, dailySeconds: 3600))
        let plan = try XCTUnwrap(CoachPlanner.plan([app, timeOfDay(lateShare: 0.8)], settings: CoachSettings()))
        XCTAssertEqual(plan.1, .shorterSessions(.evening, minutes: 25))
    }

    // MARK: - Measuring

    func test_metrics() {
        let evenings = F.lateEveningDrift().data()
        XCTAssertEqual(CoachMetric.sessionRate(.evening).measure(evenings, calendar: calendar) ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(CoachMetric.siteMinutes("x.com").measure(F.xAfterSessions().data(), calendar: calendar) ?? 0, 24, accuracy: 0.01)
        XCTAssertEqual(CoachMetric.firstSession.measure(F.lateStarts().data(), calendar: calendar) ?? 0, (2 * 540 + 3 * 660) / 5, accuracy: 0.01)
        XCTAssertNil(CoachMetric.sessionRate(.afternoon).measure(evenings, calendar: calendar))

        XCTAssertEqual(CoachMetric.sessionRate(.evening).change(from: 0.61, to: 0.70), "+9 pts")
        XCTAssertEqual(CoachMetric.sessionRate(.evening).change(from: 0.61, to: 0.58), "−3 pts")
        XCTAssertEqual(CoachMetric.siteMinutes("x.com").change(from: 41.2, to: 18), "41 → 18 min a day")
        XCTAssertEqual(CoachMetric.firstSession.change(from: 640, to: 600), "first session 40 minutes earlier")
        XCTAssertTrue(CoachMetric.siteMinutes("x.com").improved(from: 41, to: 18))
        XCTAssertFalse(CoachMetric.sessionRate(.evening).improved(from: 0.7, to: 0.6))
    }

    // MARK: - Words

    func test_draft_saysOnlyWhatTheNumbersSay() throws {
        let finding = try XCTUnwrap(CoachPatternFinder.timeOfDay(F.lateEveningDrift().data(), calendar: calendar))
        let draft = CoachDraft.make(finding, experiment: .shorterSessions(.evening, minutes: 25), locale: locale, calendar: calendar)
        XCTAssertEqual(draft.headline, "Your sessions after 17:00 are where focus slips.")
        XCTAssertEqual(draft.points.map(\.sentence), [
            "After 17:00: 60% focus rate across 3 sessions.",
            "Before noon: 90% across 3 sessions.",
            "Most of that drift came late: 100% of it after the 25th minute.",
        ])
        XCTAssertEqual(draft.why, "Most of the drift came after the 25th minute, so a shorter session ends before it does.")
        XCTAssertEqual(CoachExperiment.shorterSessions(.evening, minutes: 25).title(locale: locale, calendar: calendar),
                       "25-minute sessions after 17:00")
        XCTAssertEqual(CoachExperiment.shorterSessions(.evening, minutes: 25).shortName(locale: locale, calendar: calendar),
                       "shorter evening sessions")
    }

    func test_draft_forASiteRightAfterSessions() throws {
        let finding = try XCTUnwrap(CoachPatternFinder.afterSessions(F.xAfterSessions().data(), calendar: calendar))
        let draft = CoachDraft.make(finding, experiment: .siteLimit(host: "x.com", minutes: 15), locale: locale, calendar: calendar)
        XCTAssertEqual(draft.points.first?.sentence, "x.com within 3 minutes of finishing 4 of 5 sessions.")
        XCTAssertEqual(draft.points.last?.sentence, "About 24 min a day on x.com last week.")
        XCTAssertEqual(CoachExperiment.siteLimit(host: "x.com", minutes: 15).title(), "A 15-minute daily limit on x.com")
    }

    func test_draftWithoutAFinding() {
        let draft = CoachDraft.make(nil, experiment: nil)
        XCTAssertEqual(draft.headline, "A steady week, with nothing that stood out.")
        XCTAssertTrue(draft.points.isEmpty)
        XCTAssertNil(draft.why)
    }
}

/// The model only rewords; anything it adds is thrown away.
final class CoachWriterTests: XCTestCase {
    /// Answers with these fields as JSON, the way guided generation does;
    /// with none, it fails like a model hitting its guardrails.
    struct FakeModel: OnDeviceModel {
        let replies: [String: String]?
        func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String {
            guard let replies else { throw OnDeviceAIError.unreadableAnswer }
            return String(decoding: try JSONEncoder().encode(replies), as: UTF8.self)
        }
    }

    private let draft = CoachDraft(
        headline: "Your sessions after 17:00 are where focus slips.",
        points: [CoachPoint(lead: "After 17:00: 61%", rest: " focus rate across 4 sessions.", tone: .drift),
                 CoachPoint(lead: "Before noon: 86%", rest: " across 5 sessions.", tone: .focus)],
        why: "A shorter session is easier to keep focused all the way through.",
        facts: ["After 17:00: 61% focus rate across 4 sessions.", "Before noon: 86% across 5 sessions.",
                "Suggested experiment: 25-minute sessions after 17:00. Sessions after 17:00 start at 25 minutes."]
    )

    func test_withoutAModel_theTemplateStays() async {
        let wording = await CoachWriter(model: nil).write(draft)
        XCTAssertEqual(wording, CoachWording(headline: draft.headline, why: draft.why, onDevice: false))
    }

    func test_keepsTheModelsWordsWhenTheyStickToTheFacts() async {
        let model = FakeModel(replies: ["headline": "\"Your evenings slip to 61%, while mornings hold at 86%\"",
                                        "why": "Ending at 25 minutes keeps your evening sessions short enough to stay on track."])
        let wording = await CoachWriter(model: model).write(draft)
        XCTAssertEqual(wording.headline, "Your evenings slip to 61%, while mornings hold at 86%.")
        XCTAssertEqual(wording.why, "Ending at 25 minutes keeps your evening sessions short enough to stay on track.")
        XCTAssertTrue(wording.onDevice)
    }

    func test_dropsWordsWithNumbersThatArentInTheFacts() async {
        let model = FakeModel(replies: ["headline": "After 18:00 you drop to 40%.",
                                        "why": "Most people focus 30% better in short sessions."])
        let wording = await CoachWriter(model: model).write(draft)
        XCTAssertEqual(wording.headline, draft.headline)
        XCTAssertEqual(wording.why, draft.why)
        XCTAssertFalse(wording.onDevice)
    }

    func test_aFailingModel_leavesTheTemplate() async {
        let wording = await CoachWriter(model: FakeModel(replies: nil)).write(draft)
        XCTAssertEqual(wording, CoachWording(headline: draft.headline, why: draft.why, onDevice: false))
    }

    func test_asksForTheWhyOnlyWhenThereIsOne() {
        guard case .object(let fields) = CoachWriter.shape(withWhy: false) else { return XCTFail("expected an object") }
        XCTAssertEqual(fields.map(\.name), ["headline"])
        guard case .object(let both) = CoachWriter.shape(withWhy: true) else { return XCTFail("expected an object") }
        XCTAssertEqual(both.map(\.name), ["headline", "why"])
    }

    func test_dropsWordsNamingASiteThatIsntInTheFacts() {
        XCTAssertNil(CoachWriter.accept("Your evenings go to youtube.com instead.", allowed: draft.facts, maxLength: 110))
        XCTAssertNotNil(CoachWriter.accept("Your evenings are where focus slips.", allowed: draft.facts, maxLength: 110))
    }

    func test_takesTheFirstLineAndRejectsEmptyOrLongReplies() {
        XCTAssertEqual(CoachWriter.accept("\n  Mornings are your strong suit\nSecond line", allowed: draft.facts, maxLength: 110),
                       "Mornings are your strong suit.")
        XCTAssertNil(CoachWriter.accept("   ", allowed: draft.facts, maxLength: 110))
        XCTAssertNil(CoachWriter.accept(String(repeating: "word ", count: 40), allowed: draft.facts, maxLength: 110))
    }
}
