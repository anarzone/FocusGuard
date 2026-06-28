import XCTest
@testable import FocusGuard

final class FocusSummaryBuilderTests: XCTestCase {
    private func sampleSummary() -> String {
        FocusSummaryBuilder.summary(.init(
            rangeLabel: "Today",
            breakdown: BreakdownSnapshot(focus: 95 * 60, neutral: 40 * 60, distraction: 120 * 60),
            distractions: [
                DistractionEntry(kind: .twitter, name: "twitter.com", subtitle: "twitter.com",
                                 seconds: 60 * 60, fractionOfTotal: 0.5, host: "twitter.com",
                                 bundleId: "com.apple.Safari"),
            ],
            currentStreak: 3,
            weeklyAverageFocusSeconds: 110 * 60
        ))
    }

    func test_summary_includesAggregatedNumbersAndHosts() {
        let s = sampleSummary()
        XCTAssertTrue(s.contains("Today"))
        XCTAssertTrue(s.contains("Focus: 95 min (37%)"))   // 95 / 255 ≈ 37%
        XCTAssertTrue(s.contains("Distraction: 120 min"))
        XCTAssertTrue(s.contains("Current focus streak: 3 days"))
        XCTAssertTrue(s.contains("7-day average focus: 110 min/day"))
        XCTAssertTrue(s.contains("twitter.com — 60 min (50% of distraction time)"))
    }

    /// The summary is the data boundary — it must never carry raw window titles
    /// or full URLs, only hostnames/app names + numbers.
    func test_summary_doesNotLeakRawContent() {
        let s = sampleSummary()
        XCTAssertFalse(s.contains("://"))         // no full URLs
        XCTAssertFalse(s.lowercased().contains("window"))   // no window titles
    }

    func test_summary_handlesNoDistractions() {
        let s = FocusSummaryBuilder.summary(.init(
            rangeLabel: "Yesterday",
            breakdown: BreakdownSnapshot(focus: 0, neutral: 0, distraction: 0),
            distractions: [],
            currentStreak: 1,
            weeklyAverageFocusSeconds: 0
        ))
        XCTAssertTrue(s.contains("Current focus streak: 1 day"))   // singular
        XCTAssertTrue(s.contains("Top distractions: none recorded."))
    }

    func test_parseTips_stripsMarkersAndCaps() {
        let reply = """
        - Block twitter.com during deep-work blocks.
        2. Schedule email for after lunch.
        • Take a 5-minute break every 50 minutes.

        Extra tip one
        Extra tip two
        """
        let tips = AIInsightsService.parseTips(reply)
        XCTAssertEqual(tips.count, 4)   // capped at 4
        XCTAssertEqual(tips[0], "Block twitter.com during deep-work blocks.")
        XCTAssertEqual(tips[1], "Schedule email for after lunch.")
        XCTAssertEqual(tips[2], "Take a 5-minute break every 50 minutes.")
    }
}
