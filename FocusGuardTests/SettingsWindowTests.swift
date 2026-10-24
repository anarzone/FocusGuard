import XCTest
@testable import FocusGuard

/// Settings in the main window: the words the panes show, what diagnostics
/// leave out, and what stays hidden while Pro AI is off.
@MainActor
final class SettingsWindowTests: XCTestCase {
    func testNinePanesInCanvasOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.label), [
            "General", "Sessions", "Blocking", "Daily limits", "Notifications",
            "Integrations", "Privacy & data", "Pro & licence", "About",
        ])
    }

    func testPresetSummariesFollowTheRulings() {
        XCTAssertTrue(SettingsSessionsPane.summary(.gentle).contains("right away, for 2 minutes"))
        XCTAssertTrue(SettingsSessionsPane.summary(.standard).contains("5-second wait, for 2 minutes"))
        XCTAssertTrue(SettingsSessionsPane.summary(.strict).contains("unlocks after a 10-second wait"))
        XCTAssertEqual(SettingsLimitsPane.extra(.standard), "5 more minutes after a 5-second wait, once a day")
        XCTAssertEqual(SettingsLimitsPane.extra(.gentle), "5 more minutes, up to 3 times a day")
        XCTAssertEqual(SettingsLimitsPane.extra(.strict), "None. Limits can only be changed for tomorrow")
    }

    func testTimingsRead() {
        XCTAssertEqual(DriftTimingsSheet.seconds(30), "30 s")
        XCTAssertEqual(DriftTimingsSheet.seconds(90), "1 min 30 s")
        XCTAssertEqual(DriftTimingsSheet.seconds(180), "3 min")
    }

    func testLastCheckedLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 12))!
        XCTAssertEqual(UpdateWords.lastChecked(nil, now: now, calendar: calendar), "Not checked yet")
        XCTAssertTrue(UpdateWords.lastChecked(now.addingTimeInterval(-3600), now: now, calendar: calendar)
            .hasPrefix("Last checked today at "))
        XCTAssertTrue(UpdateWords.lastChecked(now.addingTimeInterval(-86_400), now: now, calendar: calendar)
            .hasPrefix("Last checked yesterday at "))
    }

    func testDiagnosticsLeaveOutSitesAndPaths() {
        let line = "tab report https://www.youtube.com/watch?v=abc from reddit.com saved to \(NSHomeDirectory())/Library/x"
        let scrubbed = DiagnosticsReport.scrub(line)
        XCTAssertFalse(scrubbed.contains("youtube"))
        XCTAssertFalse(scrubbed.contains("reddit.com"))
        XCTAssertFalse(scrubbed.contains(NSHomeDirectory()))
        XCTAssertTrue(scrubbed.contains("~/Library/x"))

        let text = DiagnosticsReport.build(sections: [("App", [("Version", "0.1.0 (1)")])],
                                           logs: ["opened x.com"], now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(text.contains("## App\nVersion: 0.1.0 (1)"))
        XCTAssertTrue(text.contains("opened <site>"))
    }

    func testProTableHidesAIUntilItShips() {
        XCTAssertFalse(FeatureFlags.proAI)
        XCTAssertFalse(PlanComparison.rows.contains { $0.ai })
        XCTAssertEqual(PlanComparison.rows.first { $0.name == "Daily site limits" }?.free, .text("1"))
        XCTAssertEqual(PlanComparison.rows.first { $0.name == "Reports and highlights" }?.free, .text("30 days"))
    }

    func testAppNamesForAppsThatArentInstalled() {
        XCTAssertEqual(RuleItemBuilder.fallbackName("com.hnc.Discord"), "Discord")
        XCTAssertEqual(RuleItemBuilder.fallbackName("com.example.thing.desktop"), "Thing")
        XCTAssertEqual(RuleItemBuilder.fallbackName("com.1password.1password"), "1password")
    }

    func testStoreSummary() {
        XCTAssertTrue(StoreStats(days: 41, sessions: 212, bytes: 38_000_000).summary.hasPrefix("41 days · 212 sessions · "))
        XCTAssertTrue(StoreStats(days: 1, sessions: 1, bytes: 0).summary.hasPrefix("1 day · 1 session"))
    }

    func testAppearanceFallsBackToSystem() {
        XCTAssertEqual(AppAppearance.parse("dark"), .dark)
        XCTAssertEqual(AppAppearance.parse("purple"), .system)
        XCTAssertEqual(AppAppearance.parse(nil), .system)
    }
}
