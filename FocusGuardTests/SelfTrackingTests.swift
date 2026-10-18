import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class SelfTrackingTests: XCTestCase {
    func testCleanupRemovesOnlyFocusGuardEventsOnce() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let suite = "SelfTrackingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date()
        for (bundle, name) in [("com.anar.focusguard", "FocusGuard"), ("com.anar.focusguard", "FocusGuard"), ("com.apple.dt.Xcode", "Xcode")] {
            context.insert(ActivityEvent(startedAt: now, endedAt: now.addingTimeInterval(60), bundleIdentifier: bundle, appName: name))
        }
        Persistence.save(context)

        XCTAssertEqual(SelfTrackingCleanup.runIfNeeded(context: context, defaults: defaults, bundleId: "com.anar.focusguard"), 2)
        let left = Persistence.fetch(context, FetchDescriptor<ActivityEvent>())
        XCTAssertEqual(left.map(\.appName), ["Xcode"])

        // Runs once: a new FocusGuard row added later isn't touched.
        context.insert(ActivityEvent(startedAt: now, endedAt: now, bundleIdentifier: "com.anar.focusguard", appName: "FocusGuard"))
        XCTAssertEqual(SelfTrackingCleanup.runIfNeeded(context: context, defaults: defaults, bundleId: "com.anar.focusguard"), 0)
    }

    func testNeutralSnapshotKeepsTheAppButNeverCountsAsDrift() {
        let snap = ActivitySnapshot(bundleIdentifier: "com.google.Chrome", appName: "Chrome", windowTitle: nil,
                                    url: "https://youtube.com", classification: .distraction, observedAt: .distantPast)
        let neutral = snap.asNeutral(at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(neutral.classification, .neutral)
        XCTAssertEqual(neutral.appName, "Chrome")
        XCTAssertEqual(neutral.observedAt, Date(timeIntervalSince1970: 100))
    }
}
