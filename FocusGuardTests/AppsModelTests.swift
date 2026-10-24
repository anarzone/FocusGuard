import XCTest
import SwiftData
@testable import FocusGuard

/// Apps & Sites: where a category comes from, the rules list, the New rule
/// sheet's input, the sorting order and the daily-limit wording.
@MainActor
final class AppsModelTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    func testRuleSourceFollowsPriority() {
        XCTAssertEqual(RuleSource(nil), .none)
        XCTAssertEqual(RuleSource(AppRule(pattern: "x.com", matchKind: .host, classification: .distraction, priority: 100)), .builtIn)
        XCTAssertEqual(RuleSource(AppRule(pattern: "x.com", matchKind: .host, classification: .distraction, priority: 300)), .user)
    }

    func testItemsSayWhereTheirCategoryComesFrom() {
        let classifier = Classifier(context: context)
        context.insert(AppRule(pattern: "github.com", matchKind: .host, classification: .focus, priority: 100))
        let start = Date.now.addingTimeInterval(-3600)
        for (app, url, c) in [("Chrome", "https://github.com/a", Classification.focus),
                              ("Chrome", "https://news.example.org/", .neutral)] {
            let e = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(600),
                                  bundleIdentifier: "com.google.Chrome", appName: app, url: url)
            e.classification = c
            context.insert(e)
        }
        Persistence.save(context)
        classifier.setOverride(host: "news.example.org", classification: .distraction)

        let items = AppsModelBuilder.items(context: context, classifier: classifier, from: start, to: .now)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["github.com"]?.source, .builtIn)
        XCTAssertEqual(byName["github.com"]?.why, "Site · built-in rule")
        XCTAssertEqual(byName["news.example.org"]?.source, .user)
        XCTAssertEqual(byName["news.example.org"]?.row.classification, .distraction)

        // Unsorted ones come first, then the built-in guesses; the user's own stay out.
        XCTAssertEqual(AppsModelBuilder.toSort(items).map(\.name), ["github.com"])
    }

    func testRulesListReadsLikeTheCanvas() {
        let host = AppRule(pattern: "reddit.com", matchKind: .host, classification: .distraction, priority: 100)
        let part = AppRule(pattern: "reddit.com/r/swift", matchKind: .urlPrefix, classification: .focus, priority: 310)
        let title = AppRule(pattern: TitleRule.pattern(containing: "PR #"), matchKind: .titleRegex, classification: .focus, priority: 300)
        let app = AppRule(pattern: "com.example.NotInstalledApp", matchKind: .bundleId, classification: .neutral, priority: 300)
        let items = RuleItemBuilder.items(rules: [host, part, title, app], limits: [])
        XCTAssertEqual(items.first?.title, "reddit.com/r/swift")
        XCTAssertEqual(items.first?.note, "Wins over reddit.com")
        XCTAssertEqual(items.first(where: { $0.kind == .titleRegex })?.title, "contains “PR #”")
        XCTAssertEqual(items.first(where: { $0.kind == .titleRegex })?.matchLabel, "Window title")
        XCTAssertEqual(items.first(where: { $0.kind == .bundleId })?.title, "NotInstalledApp")
        XCTAssertEqual(items.last?.source, .builtIn)
    }

    func testTitleRulesAreEscapedAndReadBack() {
        let pattern = TitleRule.pattern(containing: " PR #12 (draft) ")
        XCTAssertNotNil(try? Regex(pattern))
        XCTAssertEqual(TitleRule.readable(pattern), "PR #12 (draft)")
        XCTAssertNotNil(Classifier.compileTitlePattern(pattern))
    }

    func testPartOfASiteInput() {
        XCTAssertEqual(NewRuleSheet.prefix("https://www.YouTube.com/shorts/"), "youtube.com/shorts")
        XCTAssertEqual(NewRuleSheet.prefix("reddit.com/r/swift"), "reddit.com/r/swift")
        XCTAssertNil(NewRuleSheet.prefix("youtube.com"))
        XCTAssertNil(NewRuleSheet.prefix("shorts"))
    }

    func testMatchPreviewCountsVisits() {
        let start = Date.now.addingTimeInterval(-7200)
        let urls = ["https://youtube.com/shorts/a", "https://youtube.com/shorts/b", "https://youtube.com/watch?v=1",
                    "https://youtube.com/shorts/c"]
        for (i, url) in urls.enumerated() {
            let s = start.addingTimeInterval(Double(i) * 60)
            context.insert(ActivityEvent(startedAt: s, endedAt: s.addingTimeInterval(59),
                                         bundleIdentifier: "com.google.Chrome", appName: "Chrome", url: url))
        }
        Persistence.save(context)
        let result = RuleMatchPreview.preview(kind: .urlPrefix, pattern: "youtube.com/shorts", context: context)
        // Two runs of matching pages: a–b, then c.
        XCTAssertEqual(result?.visits, 2)
        XCTAssertEqual(result?.seconds ?? 0, 180, accuracy: 1)
    }

    func testLimitWordingFollowsThePreset() {
        XCTAssertEqual(LimitGate.runsOut(.standard, preset: .standard),
                       "When it runs out: 5 more minutes after a 5-second wait, once a day (Standard).")
        XCTAssertEqual(LimitGate.runsOut(.gentle, preset: .gentle),
                       "When it runs out: 5 more minutes, up to 3 times a day (Gentle).")
        XCTAssertEqual(LimitGate.runsOut(.strict, preset: .strict),
                       "When it runs out: no extra time, and changes wait for tomorrow (Strict).")
    }

    func testFreeKeepsOneLimit() {
        let suite = "AppsModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let free = Entitlements(defaults: defaults)
        XCTAssertTrue(LimitGate.canAdd(existing: 0, entitlements: free))
        XCTAssertFalse(LimitGate.canAdd(existing: 1, entitlements: free))
        free.startTrialIfNeeded(for: .unlimitedLimits)
        XCTAssertTrue(LimitGate.canAdd(existing: 5, entitlements: free))
    }
}
