import XCTest
import SwiftData
@testable import FocusGuard

/// Smart categories with a fake model: what's sure applies on its own,
/// what isn't waits, the person's categories are never touched, nothing
/// is asked twice, and opted-out titles never reach the model.
@MainActor
final class SmartCategoriesTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var classifier: Classifier!
    private var defaults: UserDefaults!
    private var suite: String!
    private var unlocked = true
    private var inSession = false
    private var optedOut: Set<String> = []
    private var trials: [ProFeature] = []
    /// 26 Oct 2026, 16:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_030_400)

    /// What the fake model says, by name: category, how sure, reason.
    private var answers: [String: (String, Int, String)] = [:]
    private var model: FakeOnDeviceModel!
    private var modelAvailable = true

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
        classifier = Classifier(context: context)
        suite = "SmartCategoriesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        unlocked = true
        inSession = false
        optedOut = []
        trials = []
        answers = [:]
        modelAvailable = true
        model = FakeOnDeviceModel { [unowned self] request in
            let items = FakeOnDeviceModel.items(in: request.prompt).map { item -> [String: Any] in
                let (category, sure, reason) = self.answers[item.name] ?? ("neutral", 50, "No idea")
                return ["id": item.id, "reason": reason, "category": category, "sure": sure]
            }
            return FakeOnDeviceModel.json(["items": items])
        }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        container = nil
        context = nil
        classifier = nil
        try await super.tearDown()
    }

    private func makeEngine(flagOn: Bool = true) -> SmartCategories {
        SmartCategories(container: container, classifier: classifier,
                        optedOut: { [unowned self] in self.optedOut },
                        isUnlocked: { [unowned self] _ in self.unlocked },
                        startTrial: { [unowned self] in self.trials.append($0) },
                        model: { [unowned self] in self.modelAvailable ? self.model : nil },
                        isInSession: { [unowned self] in self.inSession },
                        defaults: defaults, now: { [unowned self] in self.now }, flagOn: flagOn)
    }

    /// `minutes` of one app (or a site, with `url`) ending `hoursAgo` before now.
    @discardableResult
    private func use(_ bundleId: String, name: String, minutes: Double, hoursAgo: Double = 1,
                     title: String? = nil, url: String? = nil, session: Session? = nil,
                     classification: Classification = .neutral) -> ActivityEvent {
        let end = now.addingTimeInterval(-hoursAgo * 3600)
        let event = ActivityEvent(startedAt: end.addingTimeInterval(-minutes * 60), endedAt: end,
                                  bundleIdentifier: bundleId, appName: name, windowTitle: title, url: url, session: session)
        event.classification = classification
        context.insert(event)
        Persistence.save(context)
        return event
    }

    private func rule(_ pattern: String) -> AppRule? {
        Persistence.fetch(context, FetchDescriptor<AppRule>()).first { $0.pattern == pattern }
    }

    // MARK: - Deciding

    private func evidence(seconds: TimeInterval = 3600, inSession: TimeInterval = 0) -> SmartEvidence {
        SmartEvidence(key: "x", name: "X", bundleId: "x", host: nil, seconds: seconds, inSession: inSession,
                      hours: nil, alongside: [], titles: [])
    }

    func test_sureFocusAndNeutralApply_unsureOnesAsk() {
        let decide = { (c: Classification, sure: Int) in
            SmartCategorizer.decide(.init(key: "x", classification: c, sure: sure, reason: ""), evidence: self.evidence())
        }
        XCTAssertEqual(decide(.focus, 80), .apply)
        XCTAssertEqual(decide(.neutral, 75), .apply)
        XCTAssertEqual(decide(.focus, 74), .askUser)
        XCTAssertEqual(decide(.neutral, 20), .askUser)
    }

    func test_distractingNeedsMoreCertainty() {
        let verdict = { (sure: Int) in SmartCategorizer.Verdict(key: "x", classification: .distraction, sure: sure, reason: "") }
        XCTAssertEqual(SmartCategorizer.decide(verdict(80), evidence: evidence()), .askUser)
        XCTAssertEqual(SmartCategorizer.decide(verdict(90), evidence: evidence()), .apply)
    }

    func test_distractingButMostlyUsedInSessions_asks() {
        let verdict = SmartCategorizer.Verdict(key: "x", classification: .distraction, sure: 99, reason: "")
        XCTAssertEqual(SmartCategorizer.decide(verdict, evidence: evidence(seconds: 1800, inSession: 1500)), .askUser)
        // A few minutes in a session isn't enough to doubt it.
        XCTAssertEqual(SmartCategorizer.decide(verdict, evidence: evidence(seconds: 300, inSession: 300)), .apply)
    }

    // MARK: - Evidence

    func test_evidence_groupsSitesByHost_andFindsWhatItsUsedNextTo() {
        let t = now.addingTimeInterval(-3600)
        let records = [
            ActivityRecord(start: t, end: t.addingTimeInterval(600), bundleId: "com.apple.dt.Xcode", appName: "Xcode",
                           title: nil, url: nil, inSession: true, classification: .focus),
            ActivityRecord(start: t.addingTimeInterval(630), end: t.addingTimeInterval(900), bundleId: "com.google.Chrome",
                           appName: "Chrome", title: "Issues", url: "https://www.linear.app/team", inSession: true, classification: .neutral),
            ActivityRecord(start: t.addingTimeInterval(950), end: t.addingTimeInterval(1500), bundleId: "com.apple.dt.Xcode",
                           appName: "Xcode", title: nil, url: nil, inSession: true, classification: .focus),
        ]
        let evidence = SmartEvidenceBuilder.build(records, optedOut: [])
        let linear = try? XCTUnwrap(evidence.first { $0.key == "linear.app" })
        XCTAssertEqual(linear?.name, "linear.app")
        XCTAssertEqual(linear?.host, "linear.app")
        XCTAssertEqual(linear?.alongside.map(\.name), ["Xcode"])
        XCTAssertEqual(linear?.alongside.first?.classification, .focus)
        XCTAssertEqual(linear?.titles, ["Issues"])
        XCTAssertEqual(linear?.sessionShare ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(evidence.first?.key, "com.apple.dt.Xcode", "most time first")
    }

    func test_evidence_neverReadsTitlesOfOptedOutApps() {
        let t = now.addingTimeInterval(-3600)
        let records = [
            ActivityRecord(start: t, end: t.addingTimeInterval(600), bundleId: "com.example.Diary", appName: "Diary",
                           title: "Dear diary, a secret", url: nil, inSession: false, classification: .neutral),
            ActivityRecord(start: t.addingTimeInterval(700), end: t.addingTimeInterval(900), bundleId: "com.apple.Safari",
                           appName: "Safari", title: "Bank statement", url: "https://bank.example/home", inSession: false, classification: .neutral),
        ]
        let evidence = SmartEvidenceBuilder.build(records, optedOut: ["com.example.Diary", "com.apple.Safari"])
        XCTAssertTrue(evidence.allSatisfy { $0.titles.isEmpty })
    }

    func test_busyHours() {
        var hours = [TimeInterval](repeating: 0, count: 24)
        hours[10] = 1800
        hours[11] = 1500
        hours[20] = 600
        XCTAssertEqual(SmartEvidenceBuilder.busyHours(hours), "mostly 10:00 to 12:00")
        XCTAssertNil(SmartEvidenceBuilder.busyHours([TimeInterval](repeating: 100, count: 24)))
    }

    func test_cleanTitle_dropsUnreadCount_andShortensLongOnes() {
        XCTAssertEqual(SmartEvidenceBuilder.cleanTitle("(3) Inbox"), "Inbox")
        XCTAssertEqual(SmartEvidenceBuilder.cleanTitle(String(repeating: "a", count: 90)).count, SmartEvidenceBuilder.titleLength)
    }

    // MARK: - Running

    func test_run_appliesSureOnes_andLeavesUnsureOnesForThePerson() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        use("com.example.Mystery", name: "Mystery", minutes: 20)
        answers = ["Figma": ("focus", 92, "Design tool you open next to Linear"),
                   "Mystery": ("distracting", 60, "Mostly late at night")]
        let engine = makeEngine()

        let made = await engine.run()

        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(rule("com.figma.Desktop")?.classification, .focus)
        XCTAssertEqual(rule("com.figma.Desktop")?.priority, SmartCategories.rulePriority)
        XCTAssertNil(rule("com.example.Mystery"), "an unsure guess changes nothing")
        XCTAssertEqual(engine.sortedForYou.map(\.key), ["com.figma.Desktop"])
        XCTAssertEqual(engine.needsYou.map(\.key), ["com.example.Mystery"])
        XCTAssertEqual(engine.needsYou.first?.suggested, .distraction)
        XCTAssertEqual(engine.suggestion(for: "com.figma.Desktop")?.reason, "Design tool you open next to Linear")
        XCTAssertEqual(engine.banner?.text, "Sorted 1 of 2 new apps and sites · 1 needs you")

        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>())
        XCTAssertEqual(events.first { $0.bundleIdentifier == "com.figma.Desktop" }?.classification, .focus,
                       "past activity follows the new category")
        XCTAssertEqual(events.first { $0.bundleIdentifier == "com.example.Mystery" }?.classification, .neutral)
    }

    func test_run_neverTouchesWhatThePersonSorted() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        use("com.example.Mine", name: "Mine", minutes: 40)
        classifier.setOverride(bundleId: "com.example.Mine", classification: .distraction)
        answers = ["Figma": ("focus", 95, "Design tool"), "Mine": ("focus", 99, "Looks like work")]
        let engine = makeEngine()

        await engine.run()

        let asked = model.requests.flatMap { FakeOnDeviceModel.items(in: $0.prompt).map(\.name) }
        XCTAssertEqual(asked, ["Figma"], "sorted ones aren't even asked about")
        XCTAssertEqual(rule("com.example.Mine")?.classification, .distraction)
        XCTAssertEqual(rule("com.example.Mine")?.priority, 300)
    }

    func test_run_keepsACategoryThePersonSetWhileTheModelWasThinking() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        answers = ["Figma": ("focus", 95, "Design tool")]
        let reply = model.reply
        model.reply = { [unowned self] request in
            self.classifier.setOverride(bundleId: "com.figma.Desktop", classification: .neutral)
            return try reply(request)
        }
        let engine = makeEngine()

        let made = await engine.run()

        XCTAssertTrue(made.isEmpty)
        XCTAssertEqual(rule("com.figma.Desktop")?.classification, .neutral)
        XCTAssertEqual(rule("com.figma.Desktop")?.priority, 300)
    }

    func test_run_asksAboutEachThingOnce() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        use("com.example.Mystery", name: "Mystery", minutes: 20)
        answers = ["Figma": ("focus", 92, "Design tool"), "Mystery": ("neutral", 40, "Hard to say")]
        let engine = makeEngine()

        await engine.run()
        await engine.run()

        XCTAssertEqual(model.requests.count, 1)
    }

    func test_run_batchesSixAtATime() async {
        for i in 1...8 { use("com.example.App\(i)", name: "App\(i)", minutes: Double(10 + i)) }
        let engine = makeEngine()

        let made = await engine.run()

        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(FakeOnDeviceModel.items(in: model.requests[0].prompt).count, 6)
        XCTAssertEqual(FakeOnDeviceModel.items(in: model.requests[1].prompt).count, 2)
        XCTAssertEqual(made.count, 8)
    }

    func test_run_skipsThingsBarelyUsed() async {
        use("com.example.Blip", name: "Blip", minutes: 0.5)
        let engine = makeEngine()

        await engine.run()

        XCTAssertTrue(model.requests.isEmpty)
    }

    func test_run_neverSendsOptedOutTitles() async {
        use("com.example.Diary", name: "Diary", minutes: 30, title: "A private entry")
        use("com.example.Editor", name: "Editor", minutes: 30, title: "Quarterly plan.md")
        optedOut = ["com.example.Diary"]
        let engine = makeEngine()

        await engine.run()

        let prompts = model.requests.map(\.prompt).joined(separator: "\n")
        XCTAssertFalse(prompts.contains("private entry"))
        XCTAssertTrue(prompts.contains("Quarterly plan.md"))
        XCTAssertTrue(prompts.contains("Diary"), "the app is still sorted, just without its titles")
    }

    func test_run_doesNothingWhenLockedOffUnavailableOrInASession() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)

        unlocked = false
        await makeEngine().run()
        unlocked = true
        modelAvailable = false
        await makeEngine().run()
        modelAvailable = true
        await makeEngine(flagOn: false).run()
        inSession = true
        await makeEngine().run()
        let switchedOff = makeEngine()
        inSession = false
        switchedOff.isEnabled = false
        await switchedOff.run()

        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertNil(rule("com.figma.Desktop"))
    }

    func test_aFailedBatchIsAskedAgainNextTime() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        answers = ["Figma": ("focus", 95, "Design tool")]
        let reply = model.reply
        model.reply = { _ in throw OnDeviceAIError.unreadableAnswer }
        let engine = makeEngine()

        await engine.run()
        XCTAssertNil(rule("com.figma.Desktop"))

        model.reply = reply
        await engine.run()
        XCTAssertEqual(rule("com.figma.Desktop")?.classification, .focus)
    }

    // MARK: - Undo, accept

    func test_undo_removesTheRule_putsPastActivityBack_andNeverSuggestsAgain() async {
        let event = use("com.example.Feed", name: "Feed", minutes: 40)
        answers = ["Feed": ("distracting", 97, "Scrolled late at night")]
        let engine = makeEngine()
        await engine.run()
        XCTAssertEqual(event.classification, .distraction)
        let record = try? XCTUnwrap(engine.sortedForYou.first)

        XCTAssertTrue(engine.undo(record!))

        XCTAssertNil(rule("com.example.Feed"))
        XCTAssertEqual(event.classification, .neutral)
        XCTAssertTrue(engine.sortedForYou.isEmpty)
        XCTAssertNil(engine.suggestion(for: "com.example.Feed"))
        await engine.run()
        XCTAssertEqual(model.requests.count, 1)
    }

    func test_undo_waitsWhileStrictKeepsItBlocked() async {
        use("com.example.Feed", name: "Feed", minutes: 40)
        answers = ["Feed": ("distracting", 97, "Scrolled late at night")]
        let engine = SmartCategories(container: container, classifier: classifier, optedOut: { [] },
                                     isUnlocked: { _ in true }, startTrial: { _ in },
                                     model: { [unowned self] in self.model }, isStrictLocked: { true },
                                     defaults: defaults, now: { [unowned self] in self.now }, flagOn: true)
        await engine.run()

        XCTAssertFalse(engine.undo(engine.sortedForYou[0]))
        XCTAssertEqual(rule("com.example.Feed")?.classification, .distraction)
    }

    func test_accept_makesItThePersonsCategory() async {
        use("com.example.Mystery", name: "Mystery", minutes: 20)
        answers = ["Mystery": ("focus", 50, "Used next to Xcode")]
        let engine = makeEngine()
        await engine.run()
        let record = engine.needsYou[0]

        engine.accept(record, as: .focus)

        XCTAssertEqual(rule("com.example.Mystery")?.classification, .focus)
        XCTAssertEqual(rule("com.example.Mystery")?.priority, 300)
        XCTAssertTrue(engine.needsYou.isEmpty)
        XCTAssertNil(engine.banner, "nothing sorted, nothing waiting")
    }

    func test_aPersonsChoiceTakesOverTheSmartRule() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        answers = ["Figma": ("focus", 95, "Design tool")]
        let engine = makeEngine()
        await engine.run()

        classifier.setOverride(bundleId: "com.figma.Desktop", classification: .distraction)

        XCTAssertEqual(rule("com.figma.Desktop")?.priority, 300)
        XCTAssertTrue(engine.sortedForYou.isEmpty, "it's theirs now, not a smart pick")
    }

    // MARK: - Banner

    func test_bannerText() {
        XCTAssertEqual(SmartBanner(sorted: 19, total: 21, needYou: 2).text, "Sorted 19 of 21 new apps and sites · 2 need you")
        XCTAssertEqual(SmartBanner(sorted: 4, total: 4, needYou: 0).text, "Sorted 4 new apps and sites")
        XCTAssertEqual(SmartBanner(sorted: 2, total: 3, needYou: 1).text, "Sorted 2 of 3 new apps and sites · 1 needs you")
    }

    func test_closingTheBannerHidesItUntilSomethingNew() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        answers = ["Figma": ("focus", 95, "Design tool")]
        let engine = makeEngine()
        await engine.run()
        XCTAssertNotNil(engine.banner)

        engine.closeBanner()

        XCTAssertNil(engine.banner)
    }

    func test_turningOnStartsTheTrial() {
        let engine = makeEngine()
        engine.isEnabled = false
        engine.turnOn()
        XCTAssertEqual(trials, [.smartCategories])
        XCTAssertTrue(engine.isEnabled)
    }

    func test_storeSurvivesARestart_andEraseClearsIt() async {
        use("com.figma.Desktop", name: "Figma", minutes: 40)
        answers = ["Figma": ("focus", 95, "Design tool")]
        await makeEngine().run()

        let again = makeEngine()
        XCTAssertEqual(again.store.records["com.figma.Desktop"]?.reason, "Design tool")

        again.erase()
        XCTAssertTrue(makeEngine().store.records.isEmpty)
    }

    // MARK: - YouTube video by video

    func test_videoIdAndTitle() {
        XCTAssertEqual(YouTubeVideos.videoId(in: "https://www.youtube.com/watch?v=abc123&t=42s"), "abc123")
        XCTAssertEqual(YouTubeVideos.videoId(in: "https://m.youtube.com/watch?v=xyz"), "xyz")
        XCTAssertNil(YouTubeVideos.videoId(in: "https://www.youtube.com/"))
        XCTAssertNil(YouTubeVideos.videoId(in: "https://www.youtube.com/shorts/abc"))
        XCTAssertNil(YouTubeVideos.videoId(in: "https://notyoutube.com/watch?v=abc"))
        XCTAssertEqual(YouTubeVideos.videoTitle("(2) Swift concurrency in depth - YouTube"), "Swift concurrency in depth")
        XCTAssertNil(YouTubeVideos.videoTitle("YouTube"))
        XCTAssertNil(YouTubeVideos.videoTitle(nil))
    }

    private func videoModel(_ verdicts: [String: (String, String)]) -> FakeOnDeviceModel {
        FakeOnDeviceModel { request in
            let videos = FakeOnDeviceModel.items(in: request.prompt).map { item -> [String: Any] in
                let (category, kind) = verdicts[item.name] ?? ("distracting", "something else")
                return ["id": item.id, "kind": kind, "category": category]
            }
            return FakeOnDeviceModel.json(["videos": videos])
        }
    }

    func test_perVideo_judgesEachVideo_andLeavesTheSitesCategoryAlone() async {
        context.insert(AppRule(pattern: "youtube.com", matchKind: .host, classification: .distraction, priority: 100))
        Persistence.save(context)
        classifier.invalidate()
        let talkURL = "https://www.youtube.com/watch?v=talk1"
        let raceURL = "https://www.youtube.com/watch?v=race1"
        let talk = use("com.google.Chrome", name: "Chrome", minutes: 20, title: "Swift concurrency in depth - YouTube",
                       url: talkURL, classification: .distraction)
        let race = use("com.google.Chrome", name: "Chrome", minutes: 10, title: "Best F1 overtakes of 2026 - YouTube",
                       url: raceURL, classification: .distraction)
        model = videoModel(["Swift concurrency in depth": ("focus", "coding talk"),
                            "Best F1 overtakes of 2026": ("distracting", "race highlights")])
        let engine = makeEngine()
        classifier.pageVerdict = { engine.videoVerdict(for: $0) }
        engine.setPerVideo(true)
        XCTAssertEqual(trials, [.youtubePerVideo])

        engine.noticed(bundleId: "com.google.Chrome", appName: "Chrome", url: talkURL,
                       title: "Best F1 overtakes of 2026 - YouTube", classification: .distraction)
        // The tab's title catches up a moment later; that one counts.
        engine.noticed(bundleId: "com.google.Chrome", appName: "Chrome", url: talkURL,
                       title: "Swift concurrency in depth - YouTube", classification: .distraction)
        engine.noticed(bundleId: "com.google.Chrome", appName: "Chrome", url: raceURL,
                       title: "Best F1 overtakes of 2026 - YouTube", classification: .distraction)
        let verdicts = await engine.sortVideos()

        XCTAssertEqual(verdicts.count, 2)
        XCTAssertEqual(talk.classification, .focus)
        XCTAssertEqual(race.classification, .distraction)
        XCTAssertEqual(rule("youtube.com")?.classification, .distraction, "the site's own category stays")
        XCTAssertEqual(classifier.classify(bundleId: "com.google.Chrome", windowTitle: nil, url: talkURL), .focus)
        XCTAssertEqual(engine.recentVideos().first { $0.videoId == "talk1" }?.kind, "coding talk")

        // Changing youtube.com's category keeps each video's verdict.
        classifier.setOverride(host: "youtube.com", classification: .neutral)
        XCTAssertEqual(talk.classification, .focus)
        XCTAssertEqual(race.classification, .distraction)

        // A correction sticks.
        engine.correct("race1", as: .neutral)
        XCTAssertEqual(race.classification, .neutral)

        // Off again: every video follows the site.
        engine.setPerVideo(false)
        XCTAssertEqual(talk.classification, .neutral)
        XCTAssertEqual(race.classification, .neutral)
        XCTAssertNil(classifier.pageVerdict(talkURL))
    }

    func test_perVideo_asksNothingWhileLockedOrOff() async {
        model = videoModel([:])
        let engine = makeEngine()
        engine.noticed(bundleId: "com.google.Chrome", appName: "Chrome", url: "https://www.youtube.com/watch?v=a",
                       title: "A talk - YouTube", classification: .distraction)
        await engine.sortVideos()
        XCTAssertTrue(model.requests.isEmpty, "video by video is off")

        engine.setPerVideo(true)
        unlocked = false
        engine.noticed(bundleId: "com.google.Chrome", appName: "Chrome", url: "https://www.youtube.com/watch?v=a",
                       title: "A talk - YouTube", classification: .distraction)
        await engine.sortVideos()
        XCTAssertTrue(model.requests.isEmpty, "locked")
        XCTAssertNil(engine.videoVerdict(for: "https://www.youtube.com/watch?v=a"))
    }

    func test_videoPromptMentionsWhatTheyWorkOn() async {
        model = videoModel([:])
        let engine = makeEngine()
        engine.setPerVideo(true)
        engine.noticed(bundleId: "com.apple.dt.Xcode", appName: "Xcode", url: nil, title: nil, classification: .focus)
        engine.noticed(bundleId: "com.google.Chrome", appName: "Chrome", url: "https://www.youtube.com/watch?v=a",
                       title: "A talk - YouTube", classification: .distraction)
        await engine.sortVideos()
        XCTAssertTrue(model.requests.first?.prompt.contains("Xcode") == true)
    }
}
