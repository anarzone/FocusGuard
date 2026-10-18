import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class Tier1FixTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    func testSiteRulesMatchTheSiteAndSubdomainsOnly() {
        XCTAssertTrue(Classifier.host("youtube.com", matches: "youtube.com"))
        XCTAssertTrue(Classifier.host("www.youtube.com", matches: "youtube.com"))
        XCTAssertTrue(Classifier.host("m.youtube.com", matches: "https://www.youtube.com/watch"))
        XCTAssertFalse(Classifier.host("notyoutube.com", matches: "youtube.com"))
        XCTAssertFalse(Classifier.host("youtube.com.phishing.net", matches: "youtube.com"))
        XCTAssertFalse(Classifier.host("youtube.com", matches: ""))
    }

    func testSiteRuleClassificationUsesExactMatching() {
        context.insert(AppRule(pattern: "youtube.com", matchKind: .host, classification: .distraction))
        Persistence.save(context)
        let classifier = Classifier(context: context)
        XCTAssertEqual(classifier.classify(bundleId: "com.apple.Safari", windowTitle: nil, url: "https://m.youtube.com/x"), .distraction)
        XCTAssertEqual(classifier.classify(bundleId: "com.apple.Safari", windowTitle: nil, url: "https://notyoutube.com/"), .neutral)
    }

    func testEqualPriorityTieGoesToTheNewerRule() {
        context.insert(AppRule(pattern: "com.tinyspeck.slackmacgap", matchKind: .bundleId, classification: .distraction,
                               priority: 200, createdAt: Date(timeIntervalSince1970: 100)))
        context.insert(AppRule(pattern: "com.tinyspeck.slackmacgap", matchKind: .bundleId, classification: .focus,
                               priority: 200, createdAt: Date(timeIntervalSince1970: 200)))
        Persistence.save(context)
        for _ in 0..<5 {
            let classifier = Classifier(context: context)
            XCTAssertEqual(classifier.classify(bundleId: "com.tinyspeck.slackmacgap", windowTitle: nil, url: nil), .focus)
        }
    }

    func testInvalidTitlePatternIsSkippedNotFatal() {
        XCTAssertNil(Classifier.compileTitlePattern("(unclosed"))
        XCTAssertNotNil(Classifier.compileTitlePattern("(?i)jira"))
        context.insert(AppRule(pattern: "(unclosed", matchKind: .titleRegex, classification: .distraction, priority: 400))
        context.insert(AppRule(pattern: "jira", matchKind: .titleRegex, classification: .focus, priority: 300))
        Persistence.save(context)
        let classifier = Classifier(context: context)
        XCTAssertEqual(classifier.classify(bundleId: "x", windowTitle: "JIRA board", url: nil), .focus)
    }

    func testDistractionTimeIsClampedToTheRangeEnd() {
        let from = Date(timeIntervalSince1970: 1_800_000_000)
        let to = from.addingTimeInterval(600)
        let e = ActivityEvent(startedAt: from.addingTimeInterval(300), endedAt: to.addingTimeInterval(3600),
                              bundleIdentifier: "com.apple.Safari", appName: "Safari", url: "https://youtube.com/")
        e.classification = .distraction
        context.insert(e)
        Persistence.save(context)
        let entries = ReportBuilder(context: context).topDistractions(from: from, to: to)
        XCTAssertEqual(entries.first?.seconds ?? 0, 300, accuracy: 1)
    }

    func testDurationNeverNegative() {
        let now = Date()
        let e = ActivityEvent(startedAt: now, endedAt: now.addingTimeInterval(-30), bundleIdentifier: "b", appName: "A")
        XCTAssertEqual(e.duration, 0)
    }
}
