import XCTest
import SwiftData
@testable import FocusGuard

/// The weekly coach's week: one note from last week, "Try it this week"
/// applying the experiment, and the week after measuring it and undoing it
/// unless it was kept.
@MainActor
final class WeeklyCoachTests: XCTestCase {
    typealias F = CoachFixture

    /// Rewords only the headline, as JSON.
    struct FakeModel: OnDeviceModel {
        let headline: String
        func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String {
            String(decoding: try JSONEncoder().encode(["headline": headline]), as: UTF8.self)
        }
    }

    private var container: ModelContainer!
    private var limits: DailyLimitsEngine!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var policy = OverridePolicy.standard
    private var preset = DriftResponse.standard
    private var unlocked = true
    private var canReadCalendar = false
    private var trialStarts = 0
    /// Monday 26 Oct 2026, 10:00: the week after the fixtures' week.
    private var clock = F.at(7, 10)
    private var fixture = CoachFixture()
    private var coach: WeeklyCoach!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        suiteName = "WeeklyCoachTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        policy = .standard
        preset = .standard
        unlocked = true
        canReadCalendar = false
        trialStarts = 0
        clock = F.at(7, 10)
        fixture = CoachFixture()
        limits = DailyLimitsEngine(context: container.mainContext, notifier: DailyLimitsEngineTests.RecordingNotifier(),
                                   overlay: EscalationEngineTests.StubOverlay(), policy: { [unowned self] in self.policy },
                                   calendar: F.calendar, now: clock)
        coach = makeCoach()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        coach = nil
        limits = nil
        container = nil
        try await super.tearDown()
    }

    private func makeCoach() -> WeeklyCoach {
        let coach = WeeklyCoach(defaults: defaults, calendar: F.calendar)
        coach.isShipped = true
        coach.reader = { [unowned self] interval in self.fixture.data(from: -21, to: 28).clipped(to: interval) }
        coach.applier = LiveCoachApplier(limits: limits, preset: { [unowned self] in self.preset }, defaults: defaults,
                                         canReadCalendar: { [unowned self] in self.canReadCalendar })
        coach.isUnlocked = { [unowned self] in self.unlocked }
        coach.startTrial = { [unowned self] in self.trialStarts += 1; self.unlocked = true }
        coach.now = { [unowned self] in self.clock }
        coach.locale = F.locale
        coach.goalSeconds = { _ in 3 * 3600 }
        coach.model = { nil }
        return coach
    }

    private func add(_ more: CoachFixture) {
        fixture.events += more.events
        fixture.sessions += more.sessions
    }

    private var siteLimits: [String] { limits.statuses.filter(\.isSite).map(\.target) }

    // MARK: - The note

    func test_makesOneNoteAWeek_fromLastWeek() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()

        let note = try XCTUnwrap(coach.note)
        XCTAssertEqual(note.week.start, F.at(7, 0))
        XCTAssertEqual(note.about.start, F.at(0, 0))
        XCTAssertEqual(note.headline, "You reach for x.com right after most sessions.")
        XCTAssertEqual(note.experiment, .siteLimit(host: "x.com", minutes: 15))
        XCTAssertEqual(note.baseline ?? 0, 24, accuracy: 0.01)
        XCTAssertFalse(note.onDevice)
        XCTAssertEqual(coach.state.choice, .open)

        // Later the same week the note stays as it was.
        fixture = F.lateEveningDrift()
        clock = F.at(9, 18)
        await coach.refresh()
        XCTAssertEqual(coach.note, note)
    }

    func test_theNoteSurvivesARelaunch() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()
        coach.tryIt()
        let relaunched = makeCoach()
        XCTAssertEqual(relaunched.note, coach.note)
        XCTAssertEqual(relaunched.state, coach.state)
    }

    func test_tooLittleData_noNote() async {
        fixture.session(0, 10, 0, [(.focus, 20, "a")])
        await coach.refresh()
        XCTAssertNil(coach.note)
        XCTAssertEqual(coach.state.week, F.at(7, 0))
    }

    func test_usesTheModelsWords_whenTheyStickToTheFacts() async throws {
        fixture = F.xAfterSessions()
        coach.model = { FakeModel(headline: "x.com follows 4 of 5 of your sessions") }
        await coach.refresh()
        let note = try XCTUnwrap(coach.note)
        XCTAssertEqual(note.headline, "x.com follows 4 of 5 of your sessions.")
        XCTAssertTrue(note.onDevice)
    }

    func test_lockedCoach_makesNoNote() async {
        fixture = F.xAfterSessions()
        unlocked = false
        await coach.refresh()
        XCTAssertNil(coach.note)
        XCTAssertNil(coach.state.week)
    }

    // MARK: - A daily limit

    func test_tryIt_addsTheLimit_andTheWeekEndRemovesIt() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()
        coach.tryIt()
        XCTAssertEqual(siteLimits, ["x.com"])
        XCTAssertEqual(limits.statuses.first?.minutes, 15)
        XCTAssertEqual(coach.state.choice, .trying)

        // The experiment week: x.com for 10 minutes after 4 of 5 sessions.
        add(F.xAfterSessions(week: 1, visit: 10))
        clock = F.at(14, 9)
        await coach.refresh()

        XCTAssertEqual(siteLimits, [])
        XCTAssertNil(coach.state.running)
        let result = try XCTUnwrap(coach.lastResult)
        XCTAssertEqual(result.after ?? 0, 8, accuracy: 0.01)
        XCTAssertEqual(result.change, "24 → 8 min a day")
        XCTAssertEqual(CoachWords.result(result).sentence,
                       "Last week's experiment, a 15-minute limit on x.com: 24 → 8 min a day. It's off again.")
        XCTAssertEqual(coach.note?.about.start, F.at(7, 0))
    }

    func test_keptLimit_staysAfterTheWeek_untilStopped() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()
        coach.tryIt()
        coach.keepRunning()
        add(F.xAfterSessions(week: 1, visit: 10))
        clock = F.at(14, 9)
        await coach.refresh()

        XCTAssertEqual(siteLimits, ["x.com"])
        XCTAssertEqual(coach.state.kept.count, 1)
        XCTAssertEqual(coach.lastResult.map { CoachWords.result($0).rest }, " It stays on.")

        coach.stop(try XCTUnwrap(coach.state.kept.first))
        XCTAssertEqual(siteLimits, [])
        XCTAssertTrue(coach.state.kept.isEmpty)
    }

    func test_onStrict_theWeekEndStillRemovesTheLimit_butUndoWaitsForTomorrow() async throws {
        policy = .strict
        fixture = F.xAfterSessions()
        await coach.refresh()
        coach.tryIt()
        coach.reconsider()
        XCTAssertEqual(limits.statuses.first?.pending, .removal, "Strict: taking it back waits for tomorrow")
        XCTAssertEqual(coach.state.choice, .open)

        // Tried again later, the week's end takes it off at once.
        let other = try XCTUnwrap(limits.statuses.first)
        limits.removeLimit(other.id, evenOnStrict: true)
        coach.tryIt()
        XCTAssertEqual(siteLimits, ["x.com"])
        clock = F.at(14, 0)
        await coach.refresh()
        XCTAssertEqual(siteLimits, [])
    }

    func test_tryIt_whenTheLimitIsAlreadyThere_saysSo() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()
        limits.addLimit(target: "x.com", isSite: true, minutes: 30)
        coach.tryIt()
        XCTAssertEqual(coach.state.choice, .open)
        XCTAssertNotNil(coach.problem)
        XCTAssertEqual(limits.statuses.first?.minutes, 30, "the user's own limit is left alone")
    }

    // MARK: - Shorter sessions by the hour

    func test_shorterEveningSessions_lastTheWeek() async throws {
        fixture = F.lateEveningDrift()
        await coach.refresh()
        XCTAssertEqual(coach.note?.experiment, .shorterSessions(.evening, minutes: 25))
        coach.tryIt()

        XCTAssertEqual(CoachRules.sessionMinutes(at: F.at(8, 18), defaults, calendar: F.calendar), 25)
        XCTAssertNil(CoachRules.sessionMinutes(at: F.at(8, 10), defaults, calendar: F.calendar))
        // It stops by itself at the week's end, even before the coach looks.
        XCTAssertNil(CoachRules.sessionMinutes(at: F.at(14, 18), defaults, calendar: F.calendar))

        clock = F.at(14, 9)
        await coach.refresh()
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
        XCTAssertNil(coach.state.finished?.change, "no evening sessions in the experiment week")
    }

    func test_keepLastResult_turnsItBackOnForGood() async throws {
        fixture = F.lateEveningDrift()
        await coach.refresh()
        coach.tryIt()
        // Better evenings in the experiment week.
        add(F.lateEveningDrift(week: 1, eveningDrift: 5))
        clock = F.at(14, 9)
        await coach.refresh()

        let result = try XCTUnwrap(coach.lastResult)
        XCTAssertEqual(result.change, "+30 pts")
        XCTAssertTrue(result.improved)
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
        XCTAssertTrue(coach.canKeepLastResult)

        coach.keepLastResult()
        XCTAssertEqual(CoachRules.all(defaults).map(\.until), [nil])
        XCTAssertEqual(CoachRules.sessionMinutes(at: F.at(30, 19), defaults, calendar: F.calendar), 25)
        XCTAssertEqual(coach.state.kept.count, 1)
        XCTAssertFalse(coach.canKeepLastResult)
    }

    func test_notNow_andTakingItBack() async throws {
        fixture = F.lateEveningDrift()
        await coach.refresh()
        coach.notNow()
        XCTAssertEqual(coach.state.choice, .dismissed)
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)

        coach.reconsider()
        XCTAssertEqual(coach.state.choice, .open)
        coach.tryIt()
        XCTAssertEqual(CoachRules.all(defaults).count, 1)
        coach.reconsider()
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
        XCTAssertNil(coach.state.running)
    }

    // MARK: - The morning plan

    func test_earlierMorningPlan_putsTheOldSettingsBack() async throws {
        fixture = F.lateStarts()
        defaults.set(false, forKey: HabitSettings.morningPlan)
        await coach.refresh()
        XCTAssertEqual(coach.note?.experiment, .earlierMorningPlan(hour: 8))

        coach.tryIt()
        XCTAssertEqual(HabitSchedule.morningStartHour(defaults), 8)
        XCTAssertTrue(HabitSettings.isOn(HabitSettings.morningPlan, defaults))

        clock = F.at(14, 9)
        await coach.refresh()
        XCTAssertNil(defaults.object(forKey: HabitSettings.morningPlanHour))
        XCTAssertEqual(HabitSchedule.morningStartHour(defaults), 9)
        XCTAssertFalse(HabitSettings.isOn(HabitSettings.morningPlan, defaults))
    }

    // MARK: - Erase all data

    func test_eraseForgetsTheNote_andUndoesThisWeeksExperiment() async throws {
        fixture = F.lateEveningDrift()
        await coach.refresh()
        coach.tryIt()
        XCTAssertEqual(CoachRules.all(defaults).count, 1)

        coach.erase()
        XCTAssertNil(coach.note)
        XCTAssertNil(coach.state.running)
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
        XCTAssertNil(makeCoach().state.week, "a relaunch starts over too")
    }

    func test_eraseKeepsKeptChanges_withoutTheirNumbers() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()
        coach.tryIt()
        coach.keepRunning()

        coach.erase()
        XCTAssertEqual(siteLimits, ["x.com"])
        let kept = try XCTUnwrap(coach.state.kept.first)
        XCTAssertNil(kept.before)
        XCTAssertNil(kept.after)
        coach.stop(kept)
        XCTAssertEqual(siteLimits, [])
    }

    // MARK: - Plans

    func test_aFinishedTrialEndsTheExperiment_evenOnFree() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()
        coach.tryIt()
        unlocked = false
        clock = F.at(14, 9)
        await coach.refresh()
        XCTAssertEqual(siteLimits, [])
        XCTAssertNil(coach.note)
    }

    func test_tryingWithoutPro_startsTheTrialFirst() async throws {
        fixture = F.xAfterSessions()
        await coach.refresh()
        unlocked = false
        coach.tryIt()
        XCTAssertEqual(trialStarts, 1)
        XCTAssertEqual(siteLimits, ["x.com"])
    }

    // MARK: - The newer patterns' experiments

    func test_weeklyRhythm_lowersThatWeekdaysGoal_forTheWeek() async throws {
        fixture = F.slowFridays(weeks: 3, from: -2)
        await coach.refresh()
        XCTAssertEqual(coach.note?.experiment, .weekdayGoal(weekday: 6, minutes: 60))
        XCTAssertEqual(coach.note?.headline, "Fridays have been your weakest day three weeks running.")

        coach.tryIt()
        XCTAssertEqual(FocusGoal.minutes(on: F.at(11, 12), defaults, calendar: F.calendar), 60)
        XCTAssertEqual(FocusGoal.minutes(on: F.at(8, 12), defaults, calendar: F.calendar), 240)

        clock = F.at(14, 9)
        await coach.refresh()
        XCTAssertTrue(FocusGoal.weekdayMinutes(defaults).isEmpty)
        XCTAssertEqual(coach.state.history?.last?.experiment, .weekdayGoal(weekday: 6, minutes: 60))
    }

    func test_weekdayGoal_putsBackAGoalTheWeekdayHadBefore() async throws {
        FocusGoal.setMinutes(150, forWeekday: 6, defaults)
        let applier = try XCTUnwrap(coach.applier)
        let undo = try XCTUnwrap(applier.apply(.weekdayGoal(weekday: 6, minutes: 60), until: nil))
        XCTAssertEqual(FocusGoal.weekdayMinutes(defaults), [6: 60])
        applier.undo(undo, weekOver: true)
        XCTAssertEqual(FocusGoal.weekdayMinutes(defaults), [6: 150])
    }

    func test_bestSessionLength_setsTheLengthForTheWeek() async throws {
        fixture = F.shortSessionsWin(weeks: 2, from: -1)
        await coach.refresh()
        XCTAssertEqual(coach.note?.experiment, .sessionLength(minutes: 25))

        coach.tryIt()
        XCTAssertEqual(CoachRules.sessionMinutes(at: F.at(8, 10), defaults, calendar: F.calendar), 25)
        XCTAssertEqual(CoachRules.sessionMinutes(at: F.at(9, 20), defaults, calendar: F.calendar), 25)

        clock = F.at(14, 9)
        await coach.refresh()
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
    }

    func test_callHeavyDays_putASessionBeforeTheFirstCall_whenTheCalendarCanBeRead() async throws {
        fixture = F.callHeavy()
        canReadCalendar = true
        // The session before the first call comes with the morning plan, off by default now.
        defaults.set(true, forKey: HabitSettings.morningPlan)
        await coach.refresh()
        XCTAssertEqual(coach.note?.experiment, .sessionBeforeFirstCall(minutes: 25))

        coach.tryIt()
        XCTAssertEqual(CoachRules.sessionBeforeFirstCall(at: F.at(8, 8), defaults, calendar: F.calendar), 25)
        // It doesn't change the usual length.
        XCTAssertNil(CoachRules.sessionMinutes(at: F.at(8, 8), defaults, calendar: F.calendar))
    }

    func test_callHeavyDays_withoutTheCalendar_haveNothingToTry() async throws {
        fixture = F.callHeavy()
        await coach.refresh()
        XCTAssertEqual(coach.note?.headline, "Days with 3 hours of calls kept 25% of your usual focus.")
        XCTAssertNil(coach.note?.experiment)
    }

    // MARK: - The month in review

    private func makeReviewer() -> MonthReviewer {
        let reviewer = MonthReviewer(coach: coach, defaults: defaults, calendar: F.calendar)
        reviewer.isShipped = true
        reviewer.now = { [unowned self] in self.clock }
        reviewer.isUnlocked = { [unowned self] in self.unlocked }
        reviewer.model = { nil }
        reviewer.locale = F.locale
        return reviewer
    }

    func test_monthReview_isWorkedOutFromTheMonthAndTheOneBefore() async throws {
        fixture = F.septemberAndOctober()
        clock = F.at(14, 10)    // Monday 2 November
        let reviewer = makeReviewer()
        XCTAssertEqual(reviewer.lastFinishedMonth, F.october)
        XCTAssertEqual(reviewer.tryHeading, "Try in November")

        await reviewer.load(F.october)
        let review = try XCTUnwrap(reviewer.review(for: F.october))
        XCTAssertTrue(review.hasData)
        XCTAssertFalse(review.onDevice)
        XCTAssertEqual(review.headline, "October: 13h 20m focused at an 80% focus rate, 5 points up on September.")
        XCTAssertEqual(review.changes.count, 3)
        XCTAssertEqual(review.suggestions.map(\.experiment), [.shorterSessions(.afternoon, minutes: 25)])

        // An older month has no suggestions: they're for the month ahead.
        await reviewer.load(F.september)
        XCTAssertEqual(reviewer.review(for: F.september)?.suggestions, [])
    }

    func test_monthReview_usesTheModelsHeadline_whenItSticksToTheFacts() async throws {
        fixture = F.septemberAndOctober()
        clock = F.at(14, 10)
        let reviewer = makeReviewer()
        reviewer.model = { FakeModel(headline: "Your October ran at 80% over 13h 20m, 5 points up on September") }
        await reviewer.load(F.october)
        let review = try XCTUnwrap(reviewer.review(for: F.october))
        XCTAssertEqual(review.headline, "Your October ran at 80% over 13h 20m, 5 points up on September.")
        XCTAssertTrue(review.onDevice)
    }

    func test_monthReview_isLockedOnFree_andNeedsAFinishedMonth() async {
        fixture = F.septemberAndOctober()
        clock = F.at(14, 10)
        let reviewer = makeReviewer()
        unlocked = false
        await reviewer.load(F.october)
        XCTAssertNil(reviewer.review(for: F.october))
        unlocked = true
        await reviewer.load(F.november)
        XCTAssertNil(reviewer.review(for: F.november))
    }

    func test_monthReview_tryIt_runsToTheMonthsEnd_thenComesOff() async throws {
        fixture = F.septemberAndOctober()
        clock = F.at(14, 10)
        let reviewer = makeReviewer()
        await reviewer.load(F.october)
        let suggestion = try XCTUnwrap(reviewer.review(for: F.october)?.suggestions.first)

        reviewer.tryIt(suggestion)
        XCTAssertNotNil(reviewer.trial(for: suggestion))
        XCTAssertEqual(CoachRules.all(defaults).map(\.until), [F.november.end])
        XCTAssertEqual(CoachRules.sessionMinutes(at: F.at(16, 15), defaults, calendar: F.calendar), 25)
        XCTAssertEqual(coach.inPlace, [.shorterSessions(.afternoon, minutes: 25)])
        XCTAssertEqual(reviewer.trials(in: F.november).map(\.status), ["On until 30 November"])

        // Trying it twice does nothing.
        reviewer.tryIt(suggestion)
        XCTAssertEqual(coach.monthTrials.count, 1)
        XCTAssertNotNil(coach.monthProblem)

        clock = F.at(43, 9)     // 1 December
        await coach.refresh()
        XCTAssertTrue(coach.monthTrials.isEmpty)
        XCTAssertNil(coach.state.monthTrials)
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
        XCTAssertEqual(coach.state.history?.last?.experiment, .shorterSessions(.afternoon, minutes: 25))
        XCTAssertEqual(reviewer.trials(in: F.november).map(\.status), ["Turned off"])
    }

    func test_monthReview_undo_takesTheExperimentBack() async throws {
        fixture = F.septemberAndOctober()
        clock = F.at(14, 10)
        let reviewer = makeReviewer()
        await reviewer.load(F.october)
        let suggestion = try XCTUnwrap(reviewer.review(for: F.october)?.suggestions.first)
        reviewer.tryIt(suggestion)
        reviewer.undo(suggestion)
        XCTAssertNil(reviewer.trial(for: suggestion))
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
        XCTAssertNil(coach.state.monthTrials)
    }

    func test_monthTrials_surviveARelaunch_andEraseUndoesThem() async throws {
        fixture = F.septemberAndOctober()
        clock = F.at(14, 10)
        let reviewer = makeReviewer()
        await reviewer.load(F.october)
        let suggestion = try XCTUnwrap(reviewer.review(for: F.october)?.suggestions.first)
        reviewer.tryIt(suggestion)
        XCTAssertEqual(makeCoach().monthTrials.count, 1)

        coach.erase()
        XCTAssertTrue(CoachRules.all(defaults).isEmpty)
        XCTAssertTrue(coach.monthTrials.isEmpty)
    }
}

/// The coach's rules by the hour, and the places that read them.
@MainActor
final class CoachRulesTests: XCTestCase {
    typealias F = CoachFixture
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "CoachRulesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_aRuleIsInForceInItsHours_untilItsWeekEnds() {
        let rule = CoachRule(hours: .evening, change: .sessionMinutes(25), until: F.at(7, 0))
        CoachRules.add(rule, defaults)
        XCTAssertEqual(CoachRules.sessionMinutes(at: F.at(2, 17), defaults, calendar: F.calendar), 25)
        XCTAssertNil(CoachRules.sessionMinutes(at: F.at(2, 16), defaults, calendar: F.calendar))
        XCTAssertNil(CoachRules.sessionMinutes(at: F.at(7, 18), defaults, calendar: F.calendar))

        CoachRules.keep(rule.id, defaults)
        XCTAssertEqual(CoachRules.sessionMinutes(at: F.at(70, 18), defaults, calendar: F.calendar), 25)
    }

    func test_pruneDropsOnlyExpiredRules() {
        CoachRules.add(CoachRule(hours: .evening, change: .sessionMinutes(25), until: F.at(7, 0)), defaults)
        CoachRules.add(CoachRule(hours: .morning, change: .preset(.strict), until: nil), defaults)
        CoachRules.pruneExpired(now: F.at(7, 1), defaults)
        XCTAssertEqual(CoachRules.all(defaults).map(\.hours), [.morning])
    }

    func test_presetPicksTheStrictestInForce() {
        CoachRules.add(CoachRule(hours: CoachHours(from: 0, to: 24), change: .preset(.standard)), defaults)
        CoachRules.add(CoachRule(hours: .evening, change: .preset(.strict)), defaults)
        XCTAssertEqual(CoachRules.preset(at: F.at(1, 10), defaults, calendar: F.calendar), .standard)
        XCTAssertEqual(CoachRules.preset(at: F.at(1, 20), defaults, calendar: F.calendar), .strict)
    }

    func test_usualMinutes_followsTheCoach() {
        defaults.set(50, forKey: SessionDefaultsKey.durationMinutes)
        XCTAssertEqual(FocusActions.usualMinutes(defaults), 50)
        CoachRules.add(CoachRule(hours: CoachHours(from: 0, to: 24), change: .sessionMinutes(25)), defaults)
        XCTAssertEqual(FocusActions.usualMinutes(defaults), 25)
    }

    func test_morningStartHour_defaultsToNine() {
        XCTAssertEqual(HabitSchedule.morningStartHour(defaults), 9)
        defaults.set(8, forKey: HabitSettings.morningPlanHour)
        XCTAssertEqual(HabitSchedule.morningStartHour(defaults), 8)
    }

    // MARK: - The drift engine

    private func snap(at: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: "com.example", appName: "Twitter", windowTitle: nil, url: nil,
                         classification: .distraction, observedAt: at)
    }

    func test_driftEngine_followsAStricterPresetWhileItLasts() {
        let overlay = EscalationEngineTests.StubOverlay()
        let engine = EscalationEngine(presenter: EscalationEngineTests.RecordingPresenter(), overlay: overlay)
        let start = F.at(1, 18)
        engine.presetOverride = { _ in .strict }
        engine.observe(snapshot: snap(at: start), isInSession: true)
        XCTAssertNotNil(overlay.current, "Strict blocks as soon as you drift")
        XCTAssertEqual(engine.policy, .strict)
    }

    func test_driftEngine_ignoresAnOverrideThatIsntStricter() {
        let overlay = EscalationEngineTests.StubOverlay()
        let engine = EscalationEngine(presenter: EscalationEngineTests.RecordingPresenter(), overlay: overlay)
        engine.presetOverride = { _ in .gentle }
        engine.observe(snapshot: snap(at: F.at(1, 18)), isInSession: true)
        XCTAssertNil(overlay.current)
        XCTAssertEqual(engine.presetInForce(), engine.preset)
    }
}
