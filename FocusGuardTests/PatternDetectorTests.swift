import UserNotifications
import XCTest
@testable import FocusGuard

/// "Drifting to x.com?" after a few visits outside a session, and never for
/// looks while a tool works: those cost nothing. Nothing here is delivered.
@MainActor
final class PatternDetectorTests: XCTestCase {
    private var sent: [UNNotificationRequest] = []
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PatternDetectorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        sent = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func snap(_ url: String?, _ kind: Classification) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: url == nil ? "com.apple.dt.Xcode" : "com.google.Chrome", appName: "App",
                         windowTitle: nil, url: url, classification: kind, observedAt: .now)
    }

    /// Three visits to x.com, with work in between.
    private func visitThreeTimes(_ detector: PatternDetector, whileToolWorks: Bool) {
        for _ in 0..<3 {
            detector.observe(snapshot: snap("https://x.com/home", .distraction), isInSession: false, whileToolWorks: whileToolWorks)
            detector.observe(snapshot: snap(nil, .focus), isInSession: false, whileToolWorks: whileToolWorks)
        }
    }

    func testThreeVisitsOutsideASessionPrompt() {
        let presenter = NotificationPresenter(defaults: defaults, send: { [unowned self] in self.sent.append($0) }, register: { _ in })
        visitThreeTimes(PatternDetector(presenter: presenter), whileToolWorks: false)
        XCTAssertEqual(sent.count, 1)
    }

    func testLooksWhileAToolWorksArentVisits() {
        let presenter = NotificationPresenter(defaults: defaults, send: { [unowned self] in self.sent.append($0) }, register: { _ in })
        visitThreeTimes(PatternDetector(presenter: presenter), whileToolWorks: true)
        XCTAssertEqual(sent.count, 0)
    }
}
