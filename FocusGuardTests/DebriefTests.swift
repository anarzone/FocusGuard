import SwiftData
import XCTest
@testable import FocusGuard

/// The session goal and the debrief: the facts they stand on, what the
/// model is told, and how its write-up is kept.
@MainActor
final class DebriefTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func event(_ minute: Double, _ length: Double, _ app: String, _ classification: Classification,
                       bundle: String? = nil, title: String? = nil, url: String? = nil) -> DebriefFacts.Event {
        let from = start.addingTimeInterval(minute * 60)
        return DebriefFacts.Event(start: from, end: from.addingTimeInterval(length * 60 - 1),
                                  bundleId: bundle ?? "com.test.\(app.lowercased())", appName: app,
                                  title: title, url: url, classification: classification)
    }

    private func facts(goal: String? = "Ship the session-names PR", optedOut: Set<String> = []) -> DebriefFacts {
        DebriefFacts.make(goal: goal, start: start, end: start.addingTimeInterval(50 * 60), events: [
            event(0, 20, "Xcode", .focus, title: "FocusGuard — SessionNamer.swift"),
            event(20, 5, "Safari", .focus, bundle: "com.apple.Safari",
                  title: "Pull Request #49 · anarzone/FocusGuard", url: "https://github.com/anarzone/FocusGuard/pull/49"),
            event(25, 3, "Safari", .distraction, bundle: "com.apple.Safari", title: "Home / X", url: "https://x.com/home"),
            event(28, 11, "Xcode", .focus, title: "FocusGuard — SessionNamerTests.swift"),
            event(39, 5, "Messages", .neutral, bundle: "com.apple.MobileSMS", title: "Chat with Sam"),
            event(44, 6, "Claude", .focus, title: "Naming rules"),
        ], isOptedOut: { optedOut.contains($0) })
    }

    // MARK: - Facts

    func testFactsAddUpTimeByKindAndNameSitesByHost() {
        let facts = facts()
        XCTAssertEqual(facts.focused, (20 + 5 + 11 + 6) * 60, accuracy: 0.5)
        XCTAssertEqual(facts.drifted, 3 * 60, accuracy: 0.5)
        XCTAssertEqual(facts.other, 5 * 60, accuracy: 0.5)
        XCTAssertEqual(facts.apps.map(\.name), ["Xcode", "Claude", "github.com", "Messages", "x.com"])
        XCTAssertEqual(facts.apps.first { $0.name == "github.com" }?.isSite, true)
        XCTAssertEqual(facts.focusRate, 42.0 / 45.0, accuracy: 0.001)
    }

    func testDriftsRememberWhatCameBeforeThem() {
        let facts = facts()
        XCTAssertEqual(facts.drifts.count, 1)
        XCTAssertEqual(facts.drifts.first?.name, "x.com")
        XCTAssertEqual(facts.drifts.first?.after, "github.com")
        XCTAssertEqual(facts.topDrift?.name, "x.com")
    }

    func testTitlesFromOptedOutAppsAreLeftOutEvenWhenStored() {
        let facts = facts(optedOut: ["com.apple.MobileSMS"])
        XCTAssertFalse(facts.titles.contains { $0.title == "Chat with Sam" })
        XCTAssertTrue(facts.titles.contains { $0.title == "FocusGuard — SessionNamer.swift" })
        // The app's time still counts; only its title is gone.
        XCTAssertNotNil(facts.apps.first { $0.name == "Messages" })
    }

    func testThePromptCarriesAllowedTitlesOnly() {
        let prompt = DebriefPrompt(facts: facts(optedOut: ["com.apple.MobileSMS"]))
        XCTAssertTrue(prompt.text.contains("Goal: Ship the session-names PR"))
        XCTAssertTrue(prompt.text.contains("FocusGuard — SessionNamer.swift"))
        XCTAssertFalse(prompt.text.contains("Chat with Sam"))
        XCTAssertTrue(prompt.text.contains("x.com at"))
        XCTAssertEqual(prompt.appNames.first, "Xcode")
    }

    // MARK: - What the pane shows

    func testThePlainSummaryIsTimeRateAndTopApps() {
        let debrief = SessionDebrief.plain(facts(), label: "Steady Deep Dive")
        XCTAssertFalse(debrief.isWritten)
        XCTAssertNil(debrief.verdict)
        XCTAssertNil(debrief.tip)
        XCTAssertEqual(debrief.workedOn.map(\.app), ["Xcode", "Claude", "github.com"])
        XCTAssertEqual(debrief.drift, "x.com · 3 min")
        XCTAssertEqual(debrief.focusPercent, 93)
    }

    func testAWriteUpKeepsOnlyNamesFromTheSessionAndTheirRealTimes() {
        let stored = StoredDebrief(verdict: .done, evidence: "PR #49 was merged.", workedOn: [
            .init(app: "xcode", what: "SessionNamer.swift and its tests"),
            .init(app: "Figma", what: "made up"),
            .init(app: "github.com", what: "merged PR #49"),
        ], tip: "Keep the build log in view")
        let debrief = SessionDebrief.written(stored, facts: facts(), label: "Steady Deep Dive", verdict: .partly)
        XCTAssertEqual(debrief.workedOn.map(\.app), ["Xcode", "github.com"])
        XCTAssertEqual(debrief.workedOn.first?.seconds ?? 0, 31 * 60, accuracy: 1)
        XCTAssertEqual(debrief.verdict, .partly)   // the user's correction wins
        XCTAssertTrue(debrief.isWritten)

        let noGoal = SessionDebrief.written(stored, facts: facts(goal: nil), label: "x", verdict: .done)
        XCTAssertNil(noGoal.verdict)
    }

    func testCleanupTrimsDropsEmptiesAndKeepsAVerdictOnlyWithAGoal() {
        let draft = StoredDebrief(verdict: .done, evidence: "  none ", evidenceShort: "PR #49 merged",
                                  workedOn: (1...5).map { .init(app: "App\($0)", what: "thing \($0)") } + [.init(app: "X", what: " ")],
                                  driftDetail: "", tip: " Keep the build log in view ", tipDetail: "3 of 5 drifts began in a build.",
                                  project: "FocusGuard", standup: "Shipped names.")
        let tidy = DebriefCleanup.tidy(draft, hasGoal: true)
        XCTAssertNil(tidy.evidence)
        XCTAssertEqual(tidy.workedOn.count, 3)
        XCTAssertNil(tidy.driftDetail)
        XCTAssertEqual(tidy.tip, "Keep the build log in view")
        XCTAssertEqual(tidy.verdict, .done)

        let noGoal = DebriefCleanup.tidy(draft, hasGoal: false)
        XCTAssertNil(noGoal.verdict)
        XCTAssertNil(noGoal.evidenceShort)
    }

    func testAStoredDebriefRoundTripsOnTheSession() {
        let session = Session(startedAt: start)
        session.storedDebrief = StoredDebrief(verdict: .partly, evidence: "Half the tests pass.", project: "FocusGuard")
        XCTAssertEqual(session.storedDebrief?.evidence, "Half the tests pass.")
        session.goalVerdict = .notYet
        XCTAssertEqual(session.goalVerdictRaw, "notYet")
        session.storedDebrief = nil
        XCTAssertNil(session.debriefData)
    }

    // MARK: - Projects

    func testProjectsComeFromTheGoalFirstThenTheModelThenTheApps() {
        let f = facts()
        XCTAssertEqual(ProjectGuess.guess(goal: "Fix the focusguard menu", titles: f.titles, apps: f.apps,
                                          known: ["Support", "FocusGuard"]), "FocusGuard")
        XCTAssertEqual(ProjectGuess.guess(goal: "Something", modelProject: "support", titles: f.titles, apps: f.apps,
                                          known: ["Support"]), "Support")
        XCTAssertEqual(ProjectGuess.guess(goal: nil, titles: f.titles, apps: f.apps, known: []), "FocusGuard")
        XCTAssertFalse(ProjectGuess.mentions("Refocus the plan", "Focus"))
        XCTAssertTrue(ProjectGuess.mentions("Fix FocusGuard's menu", "FocusGuard"))
    }

    func testARepositoryOrASharedTitleNamesTheProject() {
        let github = [DebriefFacts.Title(app: "github.com", title: "Fix the ring · Pull Request #52 · anarzone/anar.to",
                                         seconds: 300, at: start)]
        XCTAssertEqual(ProjectGuess.repository(in: github), "anar.to")

        let apps = [DebriefFacts.App(name: "Xcode", bundleId: "x", isSite: false, classification: .focus, seconds: 900)]
        let titles = [
            DebriefFacts.Title(app: "Xcode", title: "Lexis — Cafe.swift", seconds: 500, at: start),
            DebriefFacts.Title(app: "Xcode", title: "Lexis — Menu.swift", seconds: 400, at: start),
        ]
        XCTAssertEqual(ProjectGuess.sharedName(titles: titles, apps: apps), "Lexis")
        XCTAssertNil(ProjectGuess.sharedName(titles: Array(titles.prefix(1)), apps: apps))   // one title isn't enough
    }

    // MARK: - Goal suggestions

    func testSuggestionsOfferAnUnfinishedLastGoalAndTheCalendarEvent() {
        XCTAssertEqual(GoalSuggestion.make(lastGoal: "Day strip hover", lastVerdict: .partly, calendarTitle: "Design review")
            .map(\.text), ["Day strip hover", "Design review"])
        XCTAssertEqual(GoalSuggestion.make(lastGoal: "Done thing", lastVerdict: .done, calendarTitle: nil), [])
        XCTAssertEqual(GoalSuggestion.make(lastGoal: "Review", lastVerdict: nil, calendarTitle: "review").count, 1)
        XCTAssertEqual(GoalSuggestion.make(lastGoal: "  ", lastVerdict: nil, calendarTitle: "Standup").first?.source, .calendar)
    }
}

// MARK: - The on-device adapter

/// Stands in for the on-device model: answers every question with one JSON
/// reply (or an error), and keeps what was asked.
@MainActor
private final class ScriptedOnDeviceModel: OnDeviceModel {
    var reply: String
    var fails = false
    private(set) var prompts: [String] = []

    init(reply: String) { self.reply = reply }

    func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String {
        prompts.append(prompt)
        if fails { throw OnDeviceAIError.unreadableAnswer }
        return reply
    }
}

@MainActor
final class DebriefWriterTests: XCTestCase {
    func testTheAnswerIsReadIntoAStoredDebrief() async throws {
        let fake = ScriptedOnDeviceModel(reply: """
        {"verdict":"partly","evidence":"Tests pass, PR still open.","evidenceShort":"PR open",
         "workedOn":[{"app":"Xcode","what":"SessionNamer tests"}],"driftNote":"At 19:23.",
         "tip":"Close x.com before a build","tipReason":"Both drifts began in a build.",
         "project":"FocusGuard","standup":"Wrote the namer tests."}
        """)
        let facts = DebriefFacts.make(goal: "Ship it", start: .now, end: .now.addingTimeInterval(600), events: [
            DebriefFacts.Event(start: .now, end: .now.addingTimeInterval(599), bundleId: "x", appName: "Xcode",
                               title: "FocusGuard — Namer.swift", url: nil, classification: .focus),
        ], isOptedOut: { _ in false })
        let stored = try await DebriefWriter.write(DebriefPrompt(facts: facts), with: fake)
        XCTAssertEqual(stored.verdict, .partly)
        XCTAssertEqual(stored.workedOn, [.init(app: "Xcode", what: "SessionNamer tests")])
        XCTAssertEqual(stored.tipDetail, "Both drifts began in a build.")
        XCTAssertTrue(fake.prompts.first?.contains("FocusGuard — Namer.swift") ?? false)
    }

    func testWorkedOnCanOnlyNameTheSessionsApps() {
        guard case .object(let fields) = DebriefWriter.shape(apps: ["Xcode", "github.com"]),
              let workedOn = fields.first(where: { $0.name == "workedOn" }),
              case .list(let item, let count) = workedOn.shape,
              case .object(let itemFields) = item,
              case .choice(let names) = itemFields.first(where: { $0.name == "app" })?.shape
        else { return XCTFail("unexpected shape") }
        XCTAssertEqual(names, ["Xcode", "github.com"])
        XCTAssertEqual(count, 1...3)
    }
}

// MARK: - Coordinator

@MainActor
final class DebriefCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var model: ScriptedOnDeviceModel!
    /// Whether the fake stands for a Mac with Apple Intelligence.
    private var available = true

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "DebriefCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        available = true
        model = ScriptedOnDeviceModel(reply: """
        {"verdict":"done","evidence":"PR #49 was merged at 19:41.","evidenceShort":"PR #49 merged",
         "workedOn":[{"app":"Xcode","what":"SessionNamer.swift"}],"driftNote":"","tip":"Keep the build log in view",
         "tipReason":"The drift began in a build.","project":"FocusGuard","standup":"Shipped session names."}
        """)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        context = nil
        container = nil
        model = nil
        try await super.tearDown()
    }

    private func make(pro: Bool = true, optedOut: Set<String> = []) -> DebriefCoordinator {
        let entitlements = Entitlements(defaults: defaults)
        if pro { entitlements.startTrialIfNeeded(for: .debrief) }
        let fake = model!
        let coordinator = DebriefCoordinator(context: context, isOptedOut: { optedOut.contains($0) },
                                             model: { [unowned self] in self.available ? fake : nil },
                                             entitlements: entitlements, defaults: defaults)
        coordinator.isShipped = true
        return coordinator
    }

    /// A 20-minute session: 15 in Xcode, 3 on x.com, 2 in Messages.
    private func finishedSession(goal: String? = nil) throws -> Session {
        let start = Date().addingTimeInterval(-30 * 60)
        let session = Session(startedAt: start, plannedDurationMinutes: 20)
        session.goal = goal
        context.insert(session)
        let parts: [(String, String, Classification, Double, String?, String?)] = [
            ("Xcode", "com.apple.dt.Xcode", .focus, 8, "FocusGuard — Session.swift", nil),
            ("Xcode", "com.apple.dt.Xcode", .focus, 7, "FocusGuard — AppState.swift", nil),
            ("Safari", "com.apple.Safari", .distraction, 3, "Home / X", "https://x.com/home"),
            ("Messages", "com.apple.MobileSMS", .neutral, 2, "Chat with Sam", nil),
        ]
        var at = start
        for (app, bundle, kind, minutes, title, url) in parts {
            let event = ActivityEvent(startedAt: at, endedAt: at.addingTimeInterval(minutes * 60 - 1),
                                      bundleIdentifier: bundle, appName: app, windowTitle: title, url: url, session: session)
            event.classification = kind
            context.insert(event)
            at = at.addingTimeInterval(minutes * 60)
        }
        session.endedAt = at
        session.status = .completed
        try context.save()
        return session
    }

    private func waitForWriting(_ coordinator: DebriefCoordinator) async {
        for _ in 0..<200 where !coordinator.writing.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTheTypedGoalMovesOntoTheSessionThatStarts() {
        let coordinator = make()
        defaults.set("  Ship the session-names PR ", forKey: SessionGoal.key)
        let session = Session()
        context.insert(session)
        coordinator.sessionStarted(session)
        XCTAssertEqual(session.goal, "Ship the session-names PR")
        XCTAssertEqual(defaults.string(forKey: SessionGoal.key), "")
    }

    func testFreeUsersKeepNoGoalAndGetNoDebrief() throws {
        let coordinator = make(pro: false)
        defaults.set("A goal", forKey: SessionGoal.key)
        let started = Session()
        context.insert(started)
        coordinator.sessionStarted(started)
        XCTAssertNil(started.goal)

        let session = try finishedSession(goal: "A goal")
        coordinator.sessionEnded(session)
        XCTAssertTrue(model.prompts.isEmpty)
        XCTAssertNil(session.project)
    }

    func testAFinishedSessionGetsItsDebriefWrittenAndKept() async throws {
        let coordinator = make(optedOut: ["com.apple.MobileSMS"])
        let session = try finishedSession(goal: "Ship the session-names PR")
        coordinator.sessionEnded(session)
        XCTAssertEqual(coordinator.status(for: session), .writing)
        await waitForWriting(coordinator)

        XCTAssertEqual(coordinator.status(for: session), .written)
        XCTAssertEqual(session.storedDebrief?.evidence, "PR #49 was merged at 19:41.")
        XCTAssertEqual(session.goalVerdict, .done)
        XCTAssertEqual(session.project, "FocusGuard")
        XCTAssertFalse(model.prompts.first?.contains("Chat with Sam") ?? true)

        let debrief = coordinator.debrief(for: session)
        XCTAssertEqual(debrief.workedOn.first?.app, "Xcode")
        XCTAssertEqual(debrief.drift, "x.com · 3 min")

        coordinator.correct(session, to: .partly)
        XCTAssertEqual(coordinator.debrief(for: session).verdict, .partly)

        // Written once.
        coordinator.write(for: session)
        XCTAssertEqual(model.prompts.count, 1)
    }

    func testWithoutAppleIntelligenceTheGoalStaysAndTheSummaryIsPlain() throws {
        available = false
        let coordinator = make()
        let session = try finishedSession(goal: "Ship it")
        coordinator.sessionEnded(session)
        XCTAssertTrue(model.prompts.isEmpty)
        XCTAssertEqual(coordinator.status(for: session), .plain(.needsAppleIntelligence))
        XCTAssertEqual(session.project, "FocusGuard")   // from the Xcode titles
        let debrief = coordinator.debrief(for: session)
        XCTAssertFalse(debrief.isWritten)
        XCTAssertEqual(debrief.goal, "Ship it")
        XCTAssertNil(debrief.verdict)

        coordinator.correct(session, to: .done)
        XCTAssertEqual(coordinator.debrief(for: session).verdict, .done)
    }

    func testAFailedWriteFallsBackToThePlainSummary() async throws {
        model.fails = true
        let coordinator = make()
        let session = try finishedSession()
        coordinator.sessionEnded(session)
        await waitForWriting(coordinator)
        XCTAssertEqual(coordinator.status(for: session), .plain(.failed))
        XCTAssertNil(session.debriefData)
    }
}

// MARK: - Work log

final class WorkLogTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Monday 19 October 2026, 00:00 in London.
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))! }
    private var week: DateInterval { DateInterval(start: monday, duration: 7 * 86_400) }

    private func input(day: Int, hour: Int, minutes: Double, goal: String?, verdict: GoalVerdict? = nil,
                       project: String?, live: Bool = false, stored: StoredDebrief? = nil) -> WorkLogBuilder.Input {
        let start = calendar.date(byAdding: DateComponents(day: day, hour: hour), to: monday)!
        let end = start.addingTimeInterval(minutes * 60)
        let facts = DebriefFacts.make(goal: goal, start: start, end: end, events: [
            DebriefFacts.Event(start: start, end: end.addingTimeInterval(-1), bundleId: "x", appName: "Xcode",
                               title: nil, url: nil, classification: .focus),
        ], isOptedOut: { _ in false })
        return WorkLogBuilder.Input(id: UUID(), start: start, end: live ? nil : end, name: "Steady Deep Dive", goal: goal,
                                    verdict: verdict, project: project, stored: stored, facts: facts)
    }

    private func model() -> WorkLogModel {
        WorkLogBuilder.build([
            input(day: 4, hour: 18, minutes: 30, goal: "Finish the Today page", project: "FocusGuard", live: true),
            input(day: 4, hour: 14, minutes: 30, goal: "Review PR #52", verdict: .done, project: "FocusGuard",
                  stored: StoredDebrief(evidence: "Approved after the fixes.")),
            input(day: 4, hour: 11, minutes: 50, goal: "Day strip hover", verdict: .partly, project: "FocusGuard"),
            input(day: 4, hour: 10, minutes: 25, goal: "Reply to beta testers", verdict: .done, project: "Support"),
            input(day: 3, hour: 12, minutes: 30, goal: "Portfolio copy", verdict: .partly, project: "anar.to"),
            input(day: 3, hour: 15, minutes: 20, goal: nil, project: nil),
        ], interval: week, calendar: calendar)
    }

    func testSessionsAreGroupedByDayNewestFirst() {
        let model = model()
        XCTAssertEqual(model.days.count, 2)
        XCTAssertEqual(model.days.first?.entries.map(\.title),
                       ["Finish the Today page", "Review PR #52", "Day strip hover", "Reply to beta testers"])
        XCTAssertEqual(model.days.first?.entries.first?.state, .live)
        XCTAssertEqual(model.days.first?.entries[1].note, "Approved after the fixes.")
        XCTAssertEqual(model.days.last?.entries.first?.title, "Mostly Xcode")
        XCTAssertEqual(model.goalsDone, 2)
        XCTAssertEqual(model.goalsPartly, 2)
    }

    func testProjectsAddUpFocusedTimeWithNoProjectLast() {
        let model = model()
        XCTAssertEqual(model.projects.map(\.title), ["FocusGuard", "anar.to", "Support", "No project"])
        XCTAssertEqual(model.projects.first?.seconds ?? 0, 110 * 60, accuracy: 1)
        XCTAssertEqual(model.headline(offset: 0).lead, "2 goals done and 2 partly this week.")
        XCTAssertEqual(model.headline(offset: 0).rest, "Most of it went to FocusGuard.")
    }

    func testTheTimesheetHasWeekdaysAndTotals() {
        let sheet = model().timesheet
        XCTAssertEqual(sheet.days.count, 5)   // no weekend time
        let focusGuard = sheet.rows.first { $0.project == "FocusGuard" }
        XCTAssertEqual(focusGuard?.seconds[4] ?? 0, 110 * 60, accuracy: 1)
        XCTAssertEqual(sheet.total, 185 * 60, accuracy: 3)
        XCTAssertEqual(Timesheet.hours(110 * 60), "1.8")
        XCTAssertEqual(Timesheet.hours(0), "–")

        let csv = sheet.csv(calendar: calendar).split(separator: "\n").map(String.init)
        XCTAssertEqual(csv.first, "Project,2026-10-19,2026-10-20,2026-10-21,2026-10-22,2026-10-23,Total")
        XCTAssertEqual(csv[1], "FocusGuard,0.00,0.00,0.00,0.00,1.83,1.83")
        XCTAssertEqual(csv.last?.hasPrefix("Total,"), true)
        XCTAssertEqual(Timesheet.field("Acme, Inc"), "\"Acme, Inc\"")
        XCTAssertEqual(Timesheet.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testAWeekendDayShowsOnlyWithTimeOnIt() {
        let sheet = WorkLogBuilder.build([input(day: 5, hour: 10, minutes: 40, goal: "Saturday fix", verdict: .done, project: "X")],
                                         interval: week, calendar: calendar).timesheet
        XCTAssertEqual(sheet.days.count, 6)
    }

    /// The runner's own zone isn't the calendar's: CSV dates follow the calendar.
    func testCSVDatesFollowTheCalendarsTimeZone() {
        var far = Calendar(identifier: .gregorian)
        far.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!   // UTC+14, never the runner's
        far.firstWeekday = 2
        let monday = far.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        let sheet = Timesheet(days: (0..<5).map { far.date(byAdding: .day, value: $0, to: monday)! },
                              rows: [.init(project: "X", seconds: [3600, 0, 0, 0, 0])])
        XCTAssertEqual(sheet.csv(calendar: far).split(separator: "\n").first,
                       "Project,2026-10-19,2026-10-20,2026-10-21,2026-10-22,2026-10-23,Total")
    }

    /// A US week runs Sunday to Saturday; the timesheet still lists Monday to
    /// Friday, plus a weekend day only when it has time on it.
    func testASundayFirstWeekStillListsMondayToFriday() {
        var us = Calendar(identifier: .gregorian)
        us.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        us.firstWeekday = 1
        let wednesday = us.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        let week = ReportPeriod.week.interval(offset: 0, now: wednesday, calendar: us)
        XCTAssertEqual(us.component(.weekday, from: week.start), 1)   // starts on Sunday the 18th

        func session(day: Int, project: String) -> WorkLogBuilder.Input {
            let start = us.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 10))!
            let end = start.addingTimeInterval(3600)
            let facts = DebriefFacts.make(goal: "Work", start: start, end: end, events: [
                DebriefFacts.Event(start: start, end: end.addingTimeInterval(-1), bundleId: "x", appName: "Xcode",
                                   title: nil, url: nil, classification: .focus),
            ], isOptedOut: { _ in false })
            return .init(id: UUID(), start: start, end: end, name: "S", goal: "Work", verdict: .done,
                         project: project, stored: nil, facts: facts)
        }
        let weekdays = WorkLogBuilder.build((19...23).map { session(day: $0, project: "X") }, interval: week, calendar: us)
        XCTAssertEqual(weekdays.timesheet.days.map { us.component(.weekday, from: $0) }, [2, 3, 4, 5, 6])
        XCTAssertEqual(weekdays.timesheet.rows.first?.seconds, [3600, 3600, 3600, 3600, 3600])
        XCTAssertEqual(weekdays.timesheet.csv(calendar: us).split(separator: "\n").first,
                       "Project,2026-10-19,2026-10-20,2026-10-21,2026-10-22,2026-10-23,Total")

        let withSunday = WorkLogBuilder.build([session(day: 18, project: "X"), session(day: 23, project: "X")],
                                              interval: week, calendar: us)
        XCTAssertEqual(withSunday.timesheet.days.map { us.component(.weekday, from: $0) }, [1, 2, 3, 4, 5, 6])
    }

    func testTheStandupIsForTheNextWorkingDay() {
        let standup = model().standup
        XCTAssertEqual(standup.map { calendar.component(.weekday, from: $0.day) }, 2)   // Friday's is for Monday
        XCTAssertEqual(standup?.done, ["Reply to beta testers", "Review PR #52"])
        XCTAssertEqual(standup?.next, ["Day strip hover", "Finish the Today page"])
        XCTAssertEqual(standup?.text.split(separator: "\n").first, "Done: Reply to beta testers; Review PR #52.")
    }

    func testAnEmptyWeekSaysSo() {
        let empty = WorkLogBuilder.build([], interval: week, calendar: calendar)
        XCTAssertNil(empty.standup)
        XCTAssertEqual(empty.headline(offset: 0).lead, "No sessions yet this week.")
        XCTAssertEqual(empty.headline(offset: 1).lead, "No sessions last week.")
    }

    func testTheSidebarBadgeShowsUntilTheLogOpens() {
        XCTAssertFalse(WorkLogAccess.isOpen(shipped: false, unlocked: true))
        XCTAssertFalse(WorkLogAccess.isOpen(shipped: true, unlocked: false))
        XCTAssertTrue(WorkLogAccess.isOpen(shipped: true, unlocked: true))
    }
}
