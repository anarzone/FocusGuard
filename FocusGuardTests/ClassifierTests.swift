import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class ClassifierTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var classifier: Classifier!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        classifier = Classifier(context: context)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        classifier = nil
        try await super.tearDown()
    }

    // MARK: - Bundle id

    func test_bundleIdMatchReturnsRuleClassification() {
        context.insert(AppRule(pattern: "com.jetbrains.PhpStorm", matchKind: .bundleId, classification: .focus))
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(
            classifier.classify(bundleId: "com.jetbrains.PhpStorm", windowTitle: nil, url: nil),
            .focus
        )
    }

    func test_bundleIdRequiresExactMatch() {
        context.insert(AppRule(pattern: "com.jetbrains.PhpStorm", matchKind: .bundleId, classification: .focus))
        Persistence.save(context)
        classifier.invalidate()

        // Substring should NOT match — only exact bundle ids.
        XCTAssertEqual(
            classifier.classify(bundleId: "com.jetbrains.PhpStorm.beta", windowTitle: nil, url: nil),
            .neutral
        )
    }

    // MARK: - Host

    func test_hostMatchOnURL() {
        context.insert(AppRule(pattern: "youtube.com", matchKind: .host, classification: .distraction))
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(
            classifier.classify(
                bundleId: "com.google.Chrome",
                windowTitle: nil,
                url: "https://www.youtube.com/watch?v=abc"
            ),
            .distraction
        )
    }

    func test_hostMatchIsSubstring() {
        // "youtube.com" should also match "music.youtube.com"
        context.insert(AppRule(pattern: "youtube.com", matchKind: .host, classification: .distraction))
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(
            classifier.classify(bundleId: "com.google.Chrome", windowTitle: nil,
                                url: "https://music.youtube.com/playlist"),
            .distraction
        )
    }

    func test_hostMatchIsCaseInsensitive() {
        context.insert(AppRule(pattern: "YouTube.com", matchKind: .host, classification: .distraction))
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(
            classifier.classify(bundleId: "com.google.Chrome", windowTitle: nil,
                                url: "https://www.youtube.com/"),
            .distraction
        )
    }

    func test_hostRequiresURL() {
        context.insert(AppRule(pattern: "youtube.com", matchKind: .host, classification: .distraction))
        Persistence.save(context)
        classifier.invalidate()

        // No URL → host rule can't fire.
        XCTAssertEqual(
            classifier.classify(bundleId: "com.google.Chrome", windowTitle: "Some title", url: nil),
            .neutral
        )
    }

    // MARK: - Priority

    func test_higherPriorityRuleWinsOnConflict() {
        // Bundle rule says Chrome=neutral; URL host rule says youtube=distraction.
        // Both match — host has higher priority and should win for browser+URL.
        context.insert(AppRule(pattern: "com.google.Chrome",  matchKind: .bundleId, classification: .neutral, priority: 100))
        context.insert(AppRule(pattern: "youtube.com", matchKind: .host, classification: .distraction, priority: 100))
        Persistence.save(context)
        classifier.invalidate()

        // The classifier walks rules in priority order; both at 100, host happens
        // to come second — but then on a tie, lookup order matters. Let's force
        // a clear priority gap to make the test deterministic.
        let descriptor = FetchDescriptor<AppRule>()
        let rules = (try? context.fetch(descriptor)) ?? []
        for rule in rules where rule.matchKind == .host { rule.priority = 200 }
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(
            classifier.classify(bundleId: "com.google.Chrome", windowTitle: nil,
                                url: "https://www.youtube.com/"),
            .distraction
        )
    }

    // MARK: - Default

    func test_noMatchingRuleReturnsNeutral() {
        XCTAssertEqual(
            classifier.classify(bundleId: "com.unknown.app", windowTitle: nil, url: nil),
            .neutral
        )
    }

    // MARK: - Title regex

    func test_titleRegexMatch() {
        context.insert(AppRule(
            pattern: "(?i)\\bplaying\\b",
            matchKind: .titleRegex,
            classification: .distraction
        ))
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(
            classifier.classify(bundleId: "com.example", windowTitle: "Now Playing: Song", url: nil),
            .distraction
        )
    }

    // MARK: - Cache invalidation

    func test_invalidateForcesRefetch() {
        context.insert(AppRule(pattern: "com.app", matchKind: .bundleId, classification: .focus))
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(classifier.classify(bundleId: "com.app", windowTitle: nil, url: nil), .focus)

        // Add a higher-priority distraction rule for the same bundle.
        context.insert(AppRule(pattern: "com.app", matchKind: .bundleId, classification: .distraction, priority: 999))
        Persistence.save(context)
        classifier.invalidate()

        XCTAssertEqual(classifier.classify(bundleId: "com.app", windowTitle: nil, url: nil), .distraction)
    }
}
