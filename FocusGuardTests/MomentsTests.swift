import XCTest
@testable import FocusGuard

/// The full-screen moments' words and waits: the block screen, the
/// daily-limit screen and the break screen.
final class MomentsTests: XCTestCase {
    private let ends = Date(timeIntervalSince1970: 1_792_840_000)

    private func copy(_ preset: DriftResponse, endsAt: Date? = nil, paused: Bool = true) -> BlockCopy {
        BlockCopy(place: "x.com", preset: preset, sessionLabel: "Evening focus", endsAt: endsAt, tabPaused: paused)
    }

    // MARK: - Block screen

    func test_headline_namesTheSession() {
        XCTAssertEqual(copy(.standard).headline, "Let's get back to Evening focus.")
    }

    func test_subtitle_promisesTheSiteBack_whenPassesExist() {
        let time = MomentText.time(ends)
        XCTAssertEqual(copy(.standard, endsAt: ends).subtitle, "x.com will still be there when the session ends at \(time).")
        XCTAssertEqual(copy(.gentle).subtitle, "x.com will still be there when the session ends.")
    }

    func test_subtitle_inStrict_saysThereAreNoPasses() {
        let time = MomentText.time(ends)
        XCTAssertEqual(copy(.strict, endsAt: ends).subtitle,
                       "Strict is on, so there are no passes this session. x.com is back at \(time).")
        XCTAssertEqual(copy(.strict).subtitle, "Strict is on, so there are no passes this session. x.com is back when it ends.")
    }

    func test_footer_namesThePreset() {
        let time = MomentText.time(ends)
        XCTAssertEqual(copy(.standard, endsAt: ends).footer, "Standard · the x.com tab stays paused until \(time)")
        XCTAssertEqual(copy(.gentle).footer, "Gentle · the x.com tab stays paused until the session ends")
        XCTAssertEqual(copy(.standard, paused: false).footer, "Standard · a pass lasts 2 minutes and counts as drift")
        XCTAssertEqual(copy(.strict, endsAt: ends).footer, "Strict · presets can change between sessions, not during one")
    }

    func test_timeAway() {
        XCTAssertEqual(BlockCopy.away(nil), "Drifted just now")
        XCTAssertEqual(BlockCopy.away(4), "Drifted just now")
        XCTAssertEqual(BlockCopy.away(102), "Drifted 1:42")
        XCTAssertEqual(BlockCopy.away(605), "Drifted 10:05")
    }

    func test_waits_countFromWhenTheScreenCameUp() {
        let shown = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(MomentText.secondsLeft(wait: 5, shownAt: shown, now: shown), 5)
        XCTAssertEqual(MomentText.secondsLeft(wait: 5, shownAt: shown, now: shown.addingTimeInterval(1.6)), 4)
        XCTAssertEqual(MomentText.secondsLeft(wait: 5, shownAt: shown, now: shown.addingTimeInterval(5)), 0)
        XCTAssertEqual(MomentText.secondsLeft(wait: 10, shownAt: shown, now: shown.addingTimeInterval(60)), 0)
        XCTAssertEqual(MomentText.secondsLeft(wait: 0, shownAt: shown, now: shown), 0, "Gentle lets you through right away")
    }

    func test_eachPolicy_findsItsPreset() {
        for preset in DriftResponse.allCases {
            XCTAssertEqual(MomentText.preset(for: preset.overridePolicy), preset)
        }
    }

    func test_clock() {
        XCTAssertEqual(MomentText.clock(18 * 60 + 24), "18:24")
        XCTAssertEqual(MomentText.clock(65 * 60 + 9), "1:05:09")
        XCTAssertEqual(MomentText.clock(-3), "0:00")
    }

    // MARK: - Daily limit

    private func limit(_ preset: DriftResponse, extraLeft: Int? = nil) -> LimitCopy {
        let extra = preset.overridePolicy.extraTime
        return LimitCopy(name: "youtube.com", preset: preset, minutesADay: 30, extraTime: extra,
                         extraLeft: extraLeft ?? extra.timesPerDay, reopensAt: ends)
    }

    func test_limit_standard_offersOneWaitedExtra() {
        let copy = limit(.standard)
        let time = MomentText.time(ends)
        XCTAssertEqual(copy.headline, "That's your youtube.com time for today.")
        XCTAssertEqual(copy.subtitle, "It opens again tomorrow at \(time). Everything else works as usual.")
        XCTAssertTrue(copy.offersExtraTime)
        XCTAssertEqual(copy.note, "Standard gives one extra 5 minutes a day, after a 5-second wait.")
        XCTAssertEqual(copy.footer, "Standard · youtube.com, 30 minutes a day · resets at \(time) ·")
        XCTAssertEqual(copy.editLink, "Edit limit")
    }

    func test_limit_gentle_countsWhatsLeft() {
        XCTAssertEqual(limit(.gentle, extraLeft: 2).note, "Gentle gives an extra 5 minutes up to 3 times a day. 2 left today.")
    }

    func test_limit_extraUsedUp_offersNone() {
        let copy = limit(.standard, extraLeft: 0)
        XCTAssertFalse(copy.offersExtraTime)
        XCTAssertNil(copy.note)
        XCTAssertTrue(copy.subtitle.hasPrefix("You've had today's extra time."))
    }

    func test_limit_strict_onlyChangesForTomorrow() {
        let copy = limit(.strict)
        XCTAssertFalse(copy.offersExtraTime)
        XCTAssertTrue(copy.subtitle.hasPrefix("Strict is on, so there's no extra time."))
        XCTAssertEqual(copy.note, "Want a different limit? In Strict you can change it for tomorrow.")
        XCTAssertEqual(copy.editLink, "Change for tomorrow")
    }

    // MARK: - Break

    func test_break_headlineFollowsTheSession() {
        XCTAssertEqual(BreakOverlayView.headline(after: FinishedSession(name: "Quiet Run", minutes: 50, focusPercent: 92)),
                       "Nice work. Let your eyes rest.")
        XCTAssertEqual(BreakOverlayView.headline(after: FinishedSession(name: "Comeback Marathon", minutes: 90, focusPercent: 81)),
                       "That was a long one. Rest properly.")
        XCTAssertEqual(BreakOverlayView.headline(after: nil), "Time to rest. Let your eyes wander.")
    }

    func test_break_pillDetail() {
        XCTAssertEqual(FinishedSession(name: "Locked-in Deep Dive", minutes: 50, focusPercent: 92).detail,
                       "· 50 min · 92% focused")
    }

    func test_break_tipsTakeTurns() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(BreakOverlayView.tip(at: start), BreakOverlayView.tips[0])
        XCTAssertEqual(BreakOverlayView.tip(at: start.addingTimeInterval(21)), BreakOverlayView.tips[1])
        XCTAssertEqual(BreakOverlayView.tip(at: start.addingTimeInterval(20 * Double(BreakOverlayView.tips.count))),
                       BreakOverlayView.tips[0])
    }
}
