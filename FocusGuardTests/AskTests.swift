import XCTest
import SwiftData
@testable import FocusGuard

/// Ask: questions sorted by keywords or the model, facts worked out by rules
/// on `StatsStore`, and words the model may only reword.
@MainActor
final class AskTests: XCTestCase {
    private var container: ModelContainer!

    /// UTC, weeks from Monday, 24-hour clocks: the same answers on any Mac.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Wednesday 28 October 2026, 18:00.
    private lazy var now = date(2026, 10, 28, 18)

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// An hour as answers write it, in the system's style for the locale
    /// ("09:00" or "9:00").
    private func clock(_ hour: Int) -> String {
        HabitFormat.time(date(2026, 10, 28, hour), locale: locale, calendar: calendar)
    }

    // MARK: - Seed

    /// The 28 days before today, the same every day:
    ///
    ///     09:00–10:00  Xcode, focus         (a 60-minute session)
    ///     10:00–11:30  Xcode, focus
    ///     11:30–11:40  youtube.com, drift
    ///     11:40–12:00  Xcode, focus
    ///     13:00–13:20  x.com, drift          ┐ a 30-minute session
    ///     13:20–13:30  Xcode, focus          ┘
    ///     13:30–13:40  x.com, drift
    ///     13:40–16:00  Xcode, focus
    ///     16:00–17:00  Slack, neutral
    ///
    /// and on Fridays 17:00–18:00 on reddit.com, drift. Nothing today.
    private func seed() throws {
        let context = container.mainContext
        let today = calendar.startOfDay(for: now)
        for back in 1...28 {
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            func at(_ hour: Int, _ minute: Int) -> Date { calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)! }

            let long = Session(startedAt: at(9, 0), plannedDurationMinutes: 60)
            long.endedAt = at(10, 0)
            let short = Session(startedAt: at(13, 0), plannedDurationMinutes: 30)
            short.endedAt = at(13, 30)
            context.insert(long)
            context.insert(short)

            var events: [(Date, Date, Classification, String, String, String?, Session?)] = [
                (at(9, 0), at(10, 0), .focus, "com.apple.dt.Xcode", "Xcode", nil, long),
                (at(10, 0), at(11, 30), .focus, "com.apple.dt.Xcode", "Xcode", nil, nil),
                (at(11, 30), at(11, 40), .distraction, "com.google.Chrome", "Google Chrome", "https://www.youtube.com/watch?v=1", nil),
                (at(11, 40), at(12, 0), .focus, "com.apple.dt.Xcode", "Xcode", nil, nil),
                (at(13, 0), at(13, 20), .distraction, "com.google.Chrome", "Google Chrome", "https://x.com/home", short),
                (at(13, 20), at(13, 30), .focus, "com.apple.dt.Xcode", "Xcode", nil, short),
                (at(13, 30), at(13, 40), .distraction, "com.google.Chrome", "Google Chrome", "https://x.com/home", nil),
                (at(13, 40), at(16, 0), .focus, "com.apple.dt.Xcode", "Xcode", nil, nil),
                (at(16, 0), at(17, 0), .neutral, "com.tinyspeck.slackmacgap", "Slack", nil, nil),
            ]
            if calendar.component(.weekday, from: day) == 6 {
                events.append((at(17, 0), at(18, 0), .distraction, "com.google.Chrome", "Google Chrome", "https://reddit.com/r/all", nil))
            }
            for (start, end, kind, bundleId, name, url, session) in events {
                let event = ActivityEvent(startedAt: start, endedAt: end, bundleIdentifier: bundleId, appName: name)
                event.url = url
                event.classification = kind
                event.session = session
                context.insert(event)
            }
        }
        try context.save()
    }

    private func askFacts(_ text: String, intent: AskIntent, settings: AskContext = AskContext()) async throws -> AskFacts {
        try seed()
        let store = StatsStore(container: container)
        return await store.askFacts(AskQuestion(text: text, intent: intent), settings: settings, now: now,
                                    calendar: calendar, locale: locale)
    }

    private func rows(_ visual: AskVisual?) -> [AskRow] {
        if case let .rows(rows, _, _)? = visual { return rows }
        return []
    }

    private func bars(_ visual: AskVisual?) -> [AskBar] {
        if case let .bars(bars, _, _)? = visual { return bars }
        return []
    }

    // MARK: - Sorting questions without the model

    func testTheSuggestedQuestionsMatchTheirKinds() {
        let expected: [AskIntent] = [.bestHours, .pullsAway, .weekCompare, .driftDay, .sessionLength, .coachExperiment]
        XCTAssertEqual(AskSuggestions.all.map(AskIntentMatcher.match), expected)
    }

    func testKeywordsSortOtherWordings() {
        let cases: [(String, AskIntent)] = [
            ("What pulls me away after lunch?", .pullsAway),
            ("What distracts me in the evening?", .pullsAway),
            ("When am I most productive?", .bestHours),
            ("Am I getting distracted on Mondays?", .driftDay),
            ("Was this week better than last week?", .weekCompare),
            ("How did my focus go this week?", .weekCompare),
            ("Which sessions went best?", .sessionLength),
            ("How much time did I spend on YouTube this week?", .appTime),
            ("How long was I on x.com today?", .appTime),
            ("Did the coach’s experiment help?", .coachExperiment),
            ("What did I write in my Notion doc?", .unknown),
            ("Tell me a joke", .unknown),
        ]
        for (text, intent) in cases {
            XCTAssertEqual(AskIntentMatcher.match(text), intent, text)
        }
    }

    func testHoursAndPeriodsComeFromTheWords() {
        XCTAssertEqual(AskHours.parse("What pulls me away after lunch?"), AskHours(from: 13, to: 15))
        XCTAssertEqual(AskHours.parse("What distracts me in the morning?"), AskHours(from: 6, to: 12))
        XCTAssertEqual(AskHours.parse("What do I open after 3pm?"), AskHours(from: 15, to: 17))
        XCTAssertEqual(AskHours.parse("Distractions around 14:00?"), AskHours(from: 13, to: 15))
        XCTAssertNil(AskHours.parse("What pulls me away most?"))

        XCTAssertEqual(AskPeriod.parse("Time on YouTube today?"), .today)
        XCTAssertEqual(AskPeriod.parse("Time on YouTube this week?"), .thisWeek)
        XCTAssertEqual(AskPeriod.parse("Time on YouTube last week?"), .lastWeek)
        XCTAssertEqual(AskPeriod.parse("Time on YouTube?"), .recent)
        XCTAssertEqual(AskPeriod.parse("Time on YouTube yesterday?"), .yesterday)
    }

    func testSuggestionsSkipQuestionsAlreadyAsked() {
        XCTAssertEqual(AskSuggestions.next(after: ["When do I focus best?", "what pulls me away most?"]),
                       ["How did this week compare with last?", "Which day drifts most, and why?", "How long should my sessions be?"])
        XCTAssertEqual(AskSuggestions.next(after: AskSuggestions.all, limit: 1), ["When do I focus best?"])
    }

    // MARK: - Sorting questions with the model

    func testTheModelPicksAKindFromTheList() async throws {
        let model = FakeOnDeviceModel { _ in FakeOnDeviceModel.json(["kind": "driftDay"]) }
        let question = await AskClassifier(model: model).classify("Which afternoon goes worst?")
        XCTAssertEqual(question.intent, .driftDay)

        let request = try XCTUnwrap(model.requests.first)
        XCTAssertTrue(request.prompt.contains("Question: Which afternoon goes worst?"))
        guard case let .object(fields) = request.shape, case let .choice(kinds)? = fields.first?.shape else {
            return XCTFail("Expected a choice of kinds")
        }
        XCTAssertEqual(kinds, AskIntent.allCases.map(\.rawValue))
    }

    func testKeywordsDecideWhenTheModelCantOrFails() async {
        let unsure = FakeOnDeviceModel { _ in FakeOnDeviceModel.json(["kind": "unknown"]) }
        let unsureAnswer = await AskClassifier(model: unsure).classify("What pulls me away most?")
        XCTAssertEqual(unsureAnswer.intent, .pullsAway)

        let broken = FakeOnDeviceModel { _ in throw OnDeviceAIError.unreadableAnswer }
        let brokenAnswer = await AskClassifier(model: broken).classify("How long should my sessions be?")
        XCTAssertEqual(brokenAnswer.intent, .sessionLength)

        let stray = FakeOnDeviceModel { _ in FakeOnDeviceModel.json(["kind": "weather"]) }
        let strayAnswer = await AskClassifier(model: stray).classify("When do I focus best?")
        XCTAssertEqual(strayAnswer.intent, .bestHours)

        let none = await AskClassifier(model: nil).classify("What pulls me away after lunch?")
        XCTAssertEqual(none.intent, .pullsAway)
        XCTAssertEqual(none.hours, AskHours(from: 13, to: 15))
    }

    // MARK: - Facts

    func testBestHours() async throws {
        let facts = try await askFacts("When do I focus best?", intent: .bestHours)
        XCTAssertEqual(facts.lead, "Mornings: \(clock(9)) to \(clock(12)).")
        XCTAssertEqual(facts.detail, "Your focus rate then is 94%, against 83% from \(clock(13)) to \(clock(16)). "
                       + "Those hours hold 53% of all the time you focused.")
        XCTAssertEqual(facts.basis, "From the last 4 weeks · 54 sessions")
        let shown = bars(facts.visual)
        XCTAssertEqual(shown.count, 9)   // 09:00 to 17:00
        XCTAssertEqual(shown.filter(\.highlighted).count, 3)
        XCTAssertEqual(shown.first?.label, nil)
        XCTAssertEqual(shown[1].label, "10")
        XCTAssertEqual(facts.action?.kind, .planSession(at: date(2026, 10, 29, 9)))
        XCTAssertEqual(facts.action?.title, "Plan tomorrow's first session at \(clock(9))")
    }

    func testBestHoursStartsASessionInsideThem() async throws {
        try seed()
        let store = StatsStore(container: container)
        let morning = date(2026, 10, 28, 9, 30)
        let facts = await store.askFacts(AskQuestion(text: "When do I focus best?", intent: .bestHours),
                                         settings: AskContext(sessionMinutes: 45), now: morning, calendar: calendar, locale: locale)
        XCTAssertEqual(facts.action?.kind, .startSession(minutes: 45))
        let busy = await store.askFacts(AskQuestion(text: "When do I focus best?", intent: .bestHours),
                                        settings: AskContext(busy: true), now: morning, calendar: calendar, locale: locale)
        XCTAssertNil(busy.action)
    }

    func testWhatPullsYouAwayAfterLunch() async throws {
        let facts = try await askFacts("What pulls me away after lunch?", intent: .pullsAway)
        XCTAssertEqual(facts.lead, "x.com, on all 27 days.")
        XCTAssertEqual(facts.detail, "It was all 13h 30m of the drift between \(clock(13)) and \(clock(15)).")
        XCTAssertEqual(facts.basis, "From the last 4 weeks · \(clock(13)) to \(clock(15))")
        XCTAssertEqual(rows(facts.visual).map(\.name), ["x.com"])
        XCTAssertEqual(facts.action?.kind, .limit(host: "x.com", minutes: 20))
        XCTAssertEqual(facts.action?.title, "Limit x.com to 20 minutes a day")
    }

    func testWhatPullsYouAwayAllDay() async throws {
        let facts = try await askFacts("What pulls me away most?", intent: .pullsAway,
                                    settings: AskContext(limitedSites: ["x.com"]))
        XCTAssertEqual(facts.lead, "x.com, on all 27 days.")
        XCTAssertEqual(facts.detail, "It took 13h 30m of the 22h you drifted in the last 4 weeks. youtube.com comes next, at 4h 30m.")
        XCTAssertEqual(rows(facts.visual).map(\.name), ["x.com", "youtube.com", "reddit.com"])
        XCTAssertEqual(rows(facts.visual).map(\.text), ["13h 30m", "4h 30m", "4h"])
        XCTAssertNil(facts.action, "x.com already has a limit")
    }

    func testThisWeekAgainstLast() async throws {
        let facts = try await askFacts("How did this week compare with last?", intent: .weekCompare)
        XCTAssertEqual(facts.lead, "Down 5h 20m on the same days last week.")
        XCTAssertEqual(facts.detail, "You've focused 10h 40m so far, against 16h by this point last week. "
                       + "Your focus rate is 89%, the same as then.")
        XCTAssertEqual(rows(facts.visual).map(\.text), ["10h 40m", "16h", "37h 20m"])
        XCTAssertEqual(facts.basis, "From this week so far and last week · 18 sessions")
        XCTAssertEqual(facts.action?.kind, .startSession(minutes: 50))
    }

    func testTheDayThatDriftsMost() async throws {
        let facts = try await askFacts("Which day drifts most, and why?", intent: .driftDay)
        XCTAssertEqual(facts.lead, "Fridays, with 1h 40m of drift on an average one.")
        XCTAssertEqual(facts.detail, "That's against 40m on other days. reddit.com takes 1h of it.")
        XCTAssertEqual(facts.basis, "From the last 4 weeks · 56 sessions")
        let days = bars(facts.visual)
        XCTAssertEqual(days.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(days.firstIndex(where: \.highlighted), 4)
        XCTAssertNil(facts.action, "reddit.com takes under 15 minutes on an average day")
    }

    func testSessionLength() async throws {
        let facts = try await askFacts("How long should my sessions be?", intent: .sessionLength)
        XCTAssertEqual(facts.lead, "Sessions of 45 to 74 minutes.")
        XCTAssertEqual(facts.detail, "Your focus rate in those is 100% across 27 sessions, "
                       + "against 33% in sessions of 25 to 44 minutes.")
        XCTAssertEqual(rows(facts.visual).map(\.name), ["25 to 44 min", "45 to 74 min"])
        XCTAssertEqual(facts.basis, "From the last 4 weeks · 54 sessions")
        XCTAssertEqual(facts.action?.kind, .startSession(minutes: 60))
    }

    func testSessionLengthWithTooFewSessions() {
        let builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale)
        let facts = builder.sessionLength([AskSession(start: now, minutes: 50, focus: 3000, drift: 0)])
        XCTAssertEqual(facts.lead, "Too few sessions to tell yet.")
        XCTAssertNil(facts.action)
    }

    func testTimeOnASite() async throws {
        let facts = try await askFacts("How much time on youtube this week?", intent: .appTime)
        XCTAssertEqual(facts.lead, "youtube.com: 20m this week.")
        XCTAssertEqual(facts.detail, "About 10m a day on the 27 days you used it lately, mostly counted as drift.")
        XCTAssertEqual(rows(facts.visual).map(\.text), ["20m", "1h 10m", "1h 10m", "1h 10m"])
        XCTAssertNil(facts.action, "Under 15 minutes a day gets no limit")
    }

    func testTimeInAnApp() async throws {
        let facts = try await askFacts("How long in Slack?", intent: .appTime)
        XCTAssertEqual(facts.lead, "Slack: 27h in the last 4 weeks.")
        XCTAssertTrue(facts.detail.hasSuffix("mostly counted as neutral time."))
    }

    func testTimeOnSomethingNeverTracked() async throws {
        let facts = try await askFacts("How much time on Figma?", intent: .appTime)
        XCTAssertEqual(facts.lead, "Nothing by that name was tracked.")
        XCTAssertEqual(facts.suggestion, "How much time on Xcode this week?")
    }

    func testTargetsMatchWholeWordsAndPreferSites() {
        let targets = [
            AskFactsBuilder.Target(key: "com.google.Chrome", name: "Google Chrome", isSite: false, seconds: 900, names: ["google chrome"]),
            AskFactsBuilder.Target(key: "youtube.com", name: "youtube.com", isSite: true, seconds: 100, names: ["youtube.com", "youtube"]),
            AskFactsBuilder.Target(key: "com.apple.mail", name: "Mail", isSite: false, seconds: 50, names: ["mail"]),
        ]
        XCTAssertEqual(AskFactsBuilder.match("Time on YouTube in Google Chrome?", in: targets)?.key, "com.google.Chrome")
        XCTAssertEqual(AskFactsBuilder.match("How long on youtube.com?", in: targets)?.key, "youtube.com")
        XCTAssertNil(AskFactsBuilder.match("How long on email?", in: targets))
    }

    func testDidTheExperimentWork() {
        let builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale)
        let week = DateInterval(start: date(2026, 10, 19, 0), end: date(2026, 10, 26, 0))
        let trial = CoachTrial(experiment: .siteLimit(host: "x.com", minutes: 20), before: 41, after: 18, week: week,
                               appliedAt: week.start, kept: false, undo: .limit(UUID()))
        let facts = builder.coach(AskCoachInput(finished: trial), shipped: true)
        XCTAssertEqual(facts.lead, "Yes: 41 → 18 min a day.")
        XCTAssertEqual(facts.detail, "The experiment was a 20-minute limit on x.com. It ended with the week, so it's off now.")
        XCTAssertEqual(facts.basis, "From the week of 19 October")
        XCTAssertEqual(rows(facts.visual).map(\.text), ["41 min a day", "18 min a day"])
        XCTAssertNil(facts.action)

        let running = builder.coach(AskCoachInput(running: trial), shipped: true)
        XCTAssertEqual(running.lead, "It's still running.")
        let none = builder.coach(AskCoachInput(), shipped: true)
        XCTAssertEqual(none.lead, "No experiment ran last week.")
        XCTAssertEqual(none.suggestion, "How did this week compare with last?")
    }

    func testWithLittleTrackedItSaysSo() async {
        let store = StatsStore(container: container)
        let facts = await store.askFacts(AskQuestion(text: "When do I focus best?", intent: .bestHours), settings: AskContext(),
                                         now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(facts.lead, "Too little tracked to tell yet.")
    }

    // MARK: - Day summaries

    func testDriftByHourAddsUpToTheDay() throws {
        try seed()
        let friday = date(2026, 10, 23, 0)
        let summary = try XCTUnwrap(DaySummary.make(days: [friday], context: ModelContext(container), calendar: calendar).first)
        XCTAssertEqual(summary.driftByHour.reduce(0, +), summary.bar.distraction, accuracy: 0.01)
        // Counted like the day's bar, each event a second past its end.
        XCTAssertEqual(summary.driftByHour[13], 30 * 60, accuracy: 2.01)
        XCTAssertEqual(summary.driftByHour[17], 60 * 60, accuracy: 1.01)
        for (key, group) in summary.distractions {
            let byHour = summary.distractionsByHour.values.reduce(0) { $0 + ($1[key] ?? 0) }
            XCTAssertEqual(byHour, group.seconds, accuracy: 0.01, key)
        }
        XCTAssertEqual(summary.distractionsByHour[13]?["x.com"] ?? 0, 30 * 60, accuracy: 0.01)
        XCTAssertNil(summary.distractionsByHour[9])
    }

    // MARK: - Words

    func testTheWordsAreTheTemplatesAndTheModelOnlySorts() async throws {
        try seed()
        let model = FakeOnDeviceModel { request in
            FakeOnDeviceModel.json(["kind": "weekCompare", "lead": "Focused less this week.", "detail": "Nothing else."])
        }
        let engine = AskEngine(stats: StatsStore(container: container), model: model, now: now, calendar: calendar, locale: locale)
        let answer = await engine.answer("Did I focus more this week?")
        XCTAssertEqual(model.requests.count, 1, "asked to sort, not to word")
        XCTAssertNotEqual(answer.lead, "Focused less this week.")
    }

    func testThePagesOwnQuestionsNeedNoSorting() async {
        let model = FakeOnDeviceModel { _ in FakeOnDeviceModel.json(["kind": "unknown"]) }
        let sorted = await AskClassifier(model: model).classify("When do I focus best?")
        XCTAssertEqual(sorted.intent, .bestHours)
        XCTAssertTrue(model.requests.isEmpty)
    }

    // MARK: - Questions narrower than four weeks

    private func answer(_ text: String, _ intent: AskIntent) async throws -> AskFacts {
        try await askFacts(text, intent: intent)
    }

    func testBestHoursInTheAfternoon() async throws {
        let facts = try await answer("When do I focus best in the afternoon?", .bestHours)
        XCTAssertEqual(facts.lead, "Afternoons: \(clock(13)) to \(clock(16)).")
        XCTAssertTrue(facts.detail.contains("83%"), facts.detail)
    }

    func testBestHoursWhenNothingWasTrackedThenSaysSo() async throws {
        let facts = try await answer("When do I focus best in the evening?", .bestHours)
        XCTAssertEqual(facts.lead, "Too little tracked then to tell.")
    }

    func testWhatPulledMeAwayYesterday() async throws {
        let facts = try await answer("What pulled me away yesterday?", .pullsAway)
        XCTAssertEqual(facts.lead, "x.com, most of all.")
        XCTAssertEqual(facts.detail, "It took 30m of the 40m you drifted yesterday. youtube.com comes next, at 10m.")
        XCTAssertEqual(facts.basis, "From yesterday")
    }

    func testWhatPulledMeAwayTodayWithNothingToday() async throws {
        let facts = try await answer("What pulled me away today?", .pullsAway)
        XCTAssertEqual(facts.lead, "Too little tracked then to tell.")
    }

    func testWhatDistractedMeLastWeek() async throws {
        let facts = try await answer("What distracted me last week?", .pullsAway)
        XCTAssertEqual(facts.lead, "x.com, on all 7 days.")
        XCTAssertEqual(facts.detail, "It took 3h 30m of the 5h 40m you drifted last week. youtube.com comes next, at 1h 10m.")
    }

    func testWhatDistractsMeOnMondays() async throws {
        let facts = try await answer("What distracts me on Mondays?", .pullsAway)
        XCTAssertEqual(facts.lead, "x.com, on all 4 days.")
        XCTAssertEqual(facts.detail, "It took 2h of the 2h 40m you drifted on Mondays. youtube.com comes next, at 40m.")
    }

    func testMondaysAgainstFridays() async throws {
        let facts = try await answer("Do I focus better on Mondays or Fridays?", .bestHours)
        XCTAssertEqual(facts.lead, "Mondays, at 89%, against 76% on Fridays.")
        let reversed = AskFactsBuilder(now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(reversed.weekdayCompare([], first: 2, second: 6).lead, "Too little tracked on those days to compare.")
    }

    func testTheBestDayWhenNoneStandsOut() async throws {
        let facts = try await answer("What's my most productive day of the week?", .bestHours)
        XCTAssertEqual(facts.lead, "No day stands out.")
        XCTAssertEqual(facts.detail, "Your focus rate runs about 87% whichever the day.")
    }

    func testMorningSessions() async throws {
        let facts = try await answer("How long should my morning sessions be?", .sessionLength)
        XCTAssertEqual(facts.lead, "Only one length to go on so far.")
        XCTAssertTrue(facts.detail.contains("of 45 to 74 minutes"), facts.detail)
    }

    func testTwoLengthsItNames() async throws {
        let facts = try await answer("Are 25 minute sessions better than 50 minute ones?", .sessionLength)
        XCTAssertEqual(facts.lead, "Sessions of 45 to 74 minutes.")
        XCTAssertTrue(facts.detail.contains("in sessions of 25 to 44 minutes"), facts.detail)
    }

    func testAMonthItCantNarrowToIsSaidPlainly() async throws {
        let facts = try await answer("How much time on YouTube in September?", .appTime)
        XCTAssertEqual(facts.lead, "youtube.com: 4h 30m in the last 4 weeks.")
        XCTAssertEqual(facts.detail, "It can only narrow this to today, yesterday, this week or last week.")
        XCTAssertEqual(AskPeriod.parse("How much time on YouTube last month?"), .unsupported)
    }

    func testYesterdaysTimeOnASite() async throws {
        let facts = try await answer("How much time on YouTube yesterday?", .appTime)
        XCTAssertEqual(facts.lead, "youtube.com: 10m yesterday.")
    }

    // MARK: - What the words mean

    func testMinutesIntoSomethingArentAClockTime() {
        XCTAssertNil(AskHours.parse("What pulls me away after 15 minutes in a session?"))
        XCTAssertNil(AskHours.parse("Do I drift after 25 min?"))
        XCTAssertNil(AskHours.parse("Am I better after 2 hours?"))
        XCTAssertEqual(AskHours.parse("What distracts me after 15?"), AskHours(from: 15, to: 17))
        XCTAssertEqual(AskHours.parse("What distracts me after 2?"), AskHours(from: 14, to: 16))
    }

    func testWhichSiteWastesMyTimeNamesNoSite() async {
        for question in ["Which site wastes most of my time?", "Which app eats my time?", "What app takes up my day?"] {
            XCTAssertEqual(AskIntentMatcher.match(question), .pullsAway, question)
            let model = FakeOnDeviceModel { _ in FakeOnDeviceModel.json(["kind": "appTime"]) }
            let sorted = await AskClassifier(model: model).classify(question)
            XCTAssertEqual(sorted.intent, .pullsAway, question)
        }
    }

    func testWhatPeopleCallThings() {
        let x = AskFactsBuilder.Target(key: "x.com", name: "x.com", isSite: true, seconds: 60, names: ["x.com", "twitter", "tweets"])
        XCTAssertEqual(AskFactsBuilder.match("Did I use Twitter a lot?", in: [x])?.key, "x.com")
        XCTAssertEqual(AskFactsBuilder.aliases["x.com"]?.contains("twitter"), true)
    }

    func testWeekdaysInAQuestion() {
        XCTAssertEqual(AskWeekdays.parse("Do I focus better on Mondays or Fridays?"), [2, 6])
        XCTAssertEqual(AskWeekdays.parse("Bin ich freitags oder montags besser?"), [6, 2])
        XCTAssertEqual(AskWeekdays.parse("What distracts me?"), [])
        XCTAssertTrue(AskWeekdays.asksWhichDay("What's my most productive day of the week?"))
        XCTAssertFalse(AskWeekdays.asksWhichDay("What time of day am I most productive?"))
    }

    // MARK: - Flat data

    private func flatDays(_ count: Int = 14, drift: TimeInterval) -> [DaySummary] {
        (1...count).map { back in
            var day = DaySummary(day: calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!)
            day.breakdown.add(4 * 3600, .focus)
            day.breakdown.add(drift, .distraction)
            for hour in 9..<13 { day.focusByHour[hour] = 3600 * 0.8; day.driftByHour[hour] = 3600 * 0.2 }
            return day
        }
    }

    func testATieIsntALittleHigher() {
        let builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale)
        let facts = builder.driftDay(flatDays(drift: 120), sessionCount: 14)
        XCTAssertEqual(facts.lead, "No day stands out.")
        XCTAssertEqual(facts.detail, "Drift runs about 2m a day, whatever the day.")
    }

    func testHoursThatDontDifferDontStandOut() {
        let builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale)
        let facts = builder.bestHours(flatDays(drift: 120), sessionCount: 14)
        XCTAssertEqual(facts.lead, "No hours stand out.")
        XCTAssertEqual(facts.detail, "Your focus rate holds at about 80% whenever you work.")
        XCTAssertNil(facts.action)
    }

    func testOneTimeOfDayIsNotTooLittle() {
        var days: [DaySummary] = []
        for back in 1...10 {
            var day = DaySummary(day: calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!)
            day.breakdown.add(20 * 60, .focus)
            day.focusByHour[9] = 20 * 60
            days.append(day)
        }
        let facts = AskFactsBuilder(now: now, calendar: calendar, locale: locale).bestHours(days, sessionCount: 10)
        XCTAssertEqual(facts.lead, "Only one time of day to go on.")
        XCTAssertEqual(facts.detail, "You only focus around \(clock(9)) to \(clock(10)). Try a session at another time to compare.")
    }

    // MARK: - Clocks

    func testMidnightToTwoIsntMorning() {
        var days: [DaySummary] = []
        for back in 1...10 {
            var day = DaySummary(day: calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!)
            day.breakdown.add(4 * 3600, .focus)
            for hour in [0, 1] { day.focusByHour[hour] = 3600 * 0.9; day.driftByHour[hour] = 3600 * 0.1 }
            for hour in [22, 23] { day.focusByHour[hour] = 3600 * 0.6; day.driftByHour[hour] = 3600 * 0.4 }
            days.append(day)
        }
        let builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale)
        let facts = builder.bestHours(days, sessionCount: 10)
        XCTAssertEqual(facts.lead, "Nights: \(clock(0)) to \(clock(2)).")
        XCTAssertEqual(facts.action?.title, "Plan a session at \(clock(0)) tomorrow")
    }

    func testHoursStayRightOnTheDaysTheClocksChange() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let us = Locale(identifier: "en_US")
        func nine(on day: DateComponents) -> Date { newYork.date(from: day)! }
        let plain = HabitFormat.time(nine(on: DateComponents(year: 2026, month: 6, day: 1, hour: 9)), locale: us, calendar: newYork)
        for (month, day) in [(11, 1), (3, 8)] {
            let now = nine(on: DateComponents(year: 2026, month: month, day: day, hour: 20))
            XCTAssertEqual(AskFactsBuilder(now: now, calendar: newYork, locale: us).clock(9), plain)
        }
    }

    // MARK: - Experiments where nothing moved

    func testNothingMovedIsNeverAYes() {
        let builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale)
        let week = DateInterval(start: date(2026, 10, 19, 0), end: date(2026, 10, 26, 0))
        func lead(_ experiment: CoachExperiment, _ before: Double, _ after: Double) -> String {
            builder.coach(AskCoachInput(finished: CoachTrial(experiment: experiment, before: before, after: after, week: week,
                                                             appliedAt: week.start, kept: false, undo: .rule(UUID()))), shipped: true).lead
        }
        let none = "It made no difference."
        XCTAssertEqual(lead(.shorterSessions(.evening, minutes: 25), 0.80, 0.804), none)
        XCTAssertEqual(lead(.earlierMorningPlan(hour: 8), 600, 598), none)
        XCTAssertEqual(lead(.siteLimit(host: "x.com", minutes: 20), 41.2, 41.1), none)
        XCTAssertEqual(lead(.siteLimit(host: "x.com", minutes: 20), 41, 41), none)
        XCTAssertEqual(lead(.weekdayGoal(weekday: 2, minutes: 60), 3600, 3600), none)
        XCTAssertEqual(lead(.sessionBeforeFirstCall(minutes: 25), 3000, 3010), none)
        XCTAssertEqual(lead(.siteLimit(host: "x.com", minutes: 20), 41, 18), "Yes: 41 → 18 min a day.")
        XCTAssertEqual(lead(.shorterSessions(.evening, minutes: 25), 0.80, 0.75), "Not this time: −5 pts.")
    }

    // MARK: - The time limit

    private struct NeverAnswers: OnDeviceModel {
        func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String {
            // Ignores being cancelled, as a stuck model might.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return "{}"
        }
    }

    func testAModelThatNeverAnswersIsGivenUpOn() async {
        let timed = TimedOnDeviceModel(base: NeverAnswers(), limit: 0.05)
        do {
            _ = try await timed.respond(instructions: "", prompt: "", shape: .text)
            XCTFail("it can't have answered")
        } catch {
            XCTAssertEqual(error as? OnDeviceAIError, .timedOut)
        }
    }

    func testAnAnswerInTimeGetsThrough() async throws {
        let timed = TimedOnDeviceModel(base: FakeOnDeviceModel { _ in "{\"kind\":\"driftDay\"}" }, limit: 5)
        let reply = try await timed.respond(instructions: "", prompt: "", shape: .text)
        XCTAssertEqual(reply, "{\"kind\":\"driftDay\"}")
    }

    func testTheEngineAnswersWhatItCantSeeWithASuggestion() async {
        let store = StatsStore(container: container)
        let engine = AskEngine(stats: store, model: nil, asked: ["When do I focus best?"], now: now,
                               calendar: calendar, locale: locale)
        let answer = await engine.answer("What did I write in my Notion doc?")
        XCTAssertEqual(answer.lead, "That's not something FocusGuard can see.")
        XCTAssertEqual(answer.detail, "It sees which app or site you used, when, and for how long. It can't see what you did inside them.")
        XCTAssertEqual(answer.suggestion, "What pulls me away most?")
        XCTAssertNil(answer.action)
    }
}
