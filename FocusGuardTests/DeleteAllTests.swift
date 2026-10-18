import XCTest
import SwiftData
@testable import FocusGuard

/// `context.delete(model:where:)` fails on session-linked rows; these make
/// sure every delete path handles them.
@MainActor
final class DeleteAllTests: XCTestCase {
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

    private func sessionWithEvents(startedAt: Date, events: Int) -> Session {
        let session = Session(startedAt: startedAt, label: "s")
        session.endedAt = startedAt.addingTimeInterval(600)
        session.status = .completed
        context.insert(session)
        for i in 0..<events {
            let t = startedAt.addingTimeInterval(Double(i) * 10)
            context.insert(ActivityEvent(startedAt: t, endedAt: t.addingTimeInterval(9),
                                         bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", session: session))
        }
        return session
    }

    func testDeletesSessionLinkedEventsAndKeepsTheSession() {
        let session = sessionWithEvents(startedAt: .now, events: 3)
        Persistence.save(context)

        let deleted = Persistence.deleteAll(ActivityEvent.self, in: context)

        XCTAssertEqual(deleted, 3)
        XCTAssertEqual(Persistence.fetchCount(context, FetchDescriptor<ActivityEvent>()), 0)
        XCTAssertEqual(session.events.count, 0)
        XCTAssertEqual(Persistence.fetchCount(context, FetchDescriptor<Session>()), 1)
    }

    func testDeletingSessionsCascadesToTheirEvents() {
        _ = sessionWithEvents(startedAt: .now, events: 4)
        context.insert(ActivityEvent(startedAt: .now, endedAt: .now, bundleIdentifier: "b", appName: "Loose"))
        Persistence.save(context)

        Persistence.deleteAll(Session.self, in: context)

        XCTAssertEqual(Persistence.fetchCount(context, FetchDescriptor<Session>()), 0)
        XCTAssertEqual(Persistence.fetch(context, FetchDescriptor<ActivityEvent>()).map(\.appName), ["Loose"])
    }

    func testPagesThroughLargeSets() {
        for i in 0..<1203 {
            context.insert(ActivityEvent(startedAt: .now, endedAt: .now, bundleIdentifier: "b\(i % 3)", appName: "A"))
        }
        Persistence.save(context)
        XCTAssertEqual(Persistence.deleteAll(ActivityEvent.self, where: #Predicate { $0.bundleIdentifier != "b0" }, in: context, pageSize: 100), 802)
        XCTAssertEqual(Persistence.fetchCount(context, FetchDescriptor<ActivityEvent>()), 401)
    }

    func testRetentionPrunesOldSessionActivity() {
        // Explicit retention, so the test never depends on this machine's setting.
        let old = Calendar.current.date(byAdding: .day, value: -120, to: .now)!
        _ = sessionWithEvents(startedAt: old, events: 3)
        _ = sessionWithEvents(startedAt: .now, events: 2)
        Persistence.save(context)

        RetentionPolicy.prune(context: context, days: 90)

        XCTAssertEqual(Persistence.fetchCount(context, FetchDescriptor<ActivityEvent>()), 2)
        XCTAssertEqual(Persistence.fetchCount(context, FetchDescriptor<Session>()), 1)
    }
}
