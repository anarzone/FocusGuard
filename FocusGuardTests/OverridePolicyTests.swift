import XCTest
import SwiftData
@testable import FocusGuard

/// The override rules per preset, and how the escalation engine applies them.
@MainActor
final class OverridePolicyTests: XCTestCase {
    typealias StubOverlay = EscalationEngineTests.StubOverlay
    typealias RecordingPresenter = EscalationEngineTests.RecordingPresenter

    // MARK: - The policy

    func test_everyPassLastsTwoMinutes() {
        for preset in DriftResponse.allCases {
            XCTAssertEqual(preset.overridePolicy.passSeconds, 120, "\(preset)")
        }
    }

    func test_gentle_letsYouThroughRightAway() {
        let policy = DriftResponse.gentle.overridePolicy
        XCTAssertTrue(policy.allowsPass)
        XCTAssertEqual(policy.passWaitSeconds, 0)
        XCTAssertEqual(policy.forWorkWaitSeconds, 0)
        XCTAssertFalse(policy.locksDuringSession)
    }

    func test_standard_letsYouThroughAfterFiveSeconds() {
        let policy = DriftResponse.standard.overridePolicy
        XCTAssertTrue(policy.allowsPass)
        XCTAssertEqual(policy.passWaitSeconds, 5)
        XCTAssertEqual(policy.forWorkWaitSeconds, 0)
        XCTAssertFalse(policy.locksDuringSession)
    }

    func test_strict_neverLetsYouThrough_andForWorkWaitsTenSeconds() {
        let policy = DriftResponse.strict.overridePolicy
        XCTAssertFalse(policy.allowsPass)
        XCTAssertEqual(policy.forWorkWaitSeconds, 10)
        XCTAssertTrue(policy.locksDuringSession)
    }

    func test_extraTime_perPreset() {
        XCTAssertEqual(OverridePolicy.gentle.extraTime, .init(minutes: 5, timesPerDay: 3, waitSeconds: 0))
        XCTAssertEqual(OverridePolicy.standard.extraTime, .init(minutes: 5, timesPerDay: 1, waitSeconds: 5))
        XCTAssertFalse(OverridePolicy.strict.extraTime.isOffered)
        XCTAssertTrue(OverridePolicy.strict.limitChangesWaitForTomorrow)
        XCTAssertFalse(OverridePolicy.gentle.limitChangesWaitForTomorrow)
        XCTAssertFalse(OverridePolicy.standard.limitChangesWaitForTomorrow)
    }

    func test_policyRoundTripsAsJSON_forTheExtension() throws {
        let data = try JSONEncoder().encode(OverridePolicy.strict)
        XCTAssertEqual(try JSONDecoder().decode(OverridePolicy.self, from: data), .strict)
    }

    func test_handTunedThresholds_fallBackToStrictOrStandard() {
        XCTAssertEqual(DriftResponse.matching(silence: 20, notify: 60, block: 180, strict: false), .gentle)
        XCTAssertEqual(DriftResponse.matching(silence: 10, notify: 30, block: 90, strict: true), .strict)
        XCTAssertEqual(DriftResponse.matching(silence: 5, notify: 45, block: 120, strict: true), .strict)
        XCTAssertEqual(DriftResponse.matching(silence: 5, notify: 45, block: 120, strict: false), .standard)
    }

    // MARK: - The engine

    private var presenter: RecordingPresenter!
    private var overlay: StubOverlay!
    private var engine: EscalationEngine!

    override func setUp() async throws {
        try await super.setUp()
        presenter = RecordingPresenter()
        overlay = StubOverlay()
        engine = EscalationEngine(presenter: presenter, overlay: overlay)
        use(.standard)
    }

    private func use(_ preset: DriftResponse) {
        let v = preset.values
        engine.silenceThreshold = TimeInterval(v.silence)
        engine.notifyThreshold = TimeInterval(v.notify)
        engine.blockThreshold = TimeInterval(v.block)
        engine.strictMode = v.strict
    }

    private func snap(_ url: String, at: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: "com.apple.Safari", appName: "Safari", windowTitle: nil,
                         url: url, classification: .distraction, observedAt: at)
    }

    /// Drifts to `url` long enough to bring the block screen up.
    private func blockOn(_ url: String, at t0: Date) {
        engine.observe(snapshot: snap(url, at: t0), isInSession: true)
        engine.observe(snapshot: snap(url, at: t0.addingTimeInterval(engine.blockThreshold + 1)), isInSession: true)
    }

    func test_engineFollowsThePreset() {
        XCTAssertEqual(engine.policy, .standard)
        use(.gentle)
        XCTAssertEqual(engine.policy, .gentle)
        use(.strict)
        XCTAssertEqual(engine.policy, .strict)
    }

    func test_blockScreenCarriesThePresetsPolicy() {
        blockOn("https://x.com/home", at: Date())
        XCTAssertEqual(overlay.current?.reason, .drift(.standard))
        XCTAssertEqual(overlay.current?.host, "x.com")
    }

    func test_pass_holdsTheBlockForTwoMinutes_thenBlocksStraightAway() {
        let t0 = Date()
        blockOn("https://x.com/home", at: t0)
        overlay.letMeThrough()
        XCTAssertEqual(engine.activePass?.name, "x.com")
        XCTAssertEqual(engine.activePass?.remaining(now: Date()) ?? 0, 120, accuracy: 2)

        let passStart = Date()
        engine.observe(snapshot: snap("https://x.com/explore", at: passStart.addingTimeInterval(110)), isInSession: true)
        XCTAssertFalse(overlay.presented)
        XCTAssertEqual(presenter.distractionCalls.count, 0, "no nudges during a pass")

        // The pass runs out while still on x.com: no new 90 s wait.
        engine.observe(snapshot: snap("https://x.com/explore", at: passStart.addingTimeInterval(121)), isInSession: true)
        XCTAssertTrue(overlay.presented)
        XCTAssertNil(engine.activePass)
    }

    func test_pass_onlyCoversTheSiteItWasFor() {
        let t0 = Date()
        blockOn("https://x.com/home", at: t0)
        overlay.letMeThrough()

        let t1 = Date()
        engine.observe(snapshot: snap("https://reddit.com", at: t1), isInSession: true)
        engine.observe(snapshot: snap("https://reddit.com", at: t1.addingTimeInterval(engine.blockThreshold + 1)), isInSession: true)
        XCTAssertTrue(overlay.presented)
        XCTAssertEqual(overlay.current?.host, "reddit.com")
    }

    func test_gentle_alsoGivesTwoMinutes() {
        use(.gentle)
        blockOn("https://x.com/home", at: Date())
        overlay.letMeThrough()
        XCTAssertEqual(engine.activePass?.remaining(now: Date()) ?? 0, 120, accuracy: 2)
    }

    func test_strict_refusesAPass() {
        use(.strict)
        let t0 = Date()
        engine.observe(snapshot: snap("https://x.com/home", at: t0), isInSession: true)
        XCTAssertEqual(overlay.current?.reason, .drift(.strict))
        overlay.letMeThrough()
        XCTAssertNil(engine.activePass)
        engine.observe(snapshot: snap("https://x.com/home", at: t0.addingTimeInterval(1)), isInSession: true)
        XCTAssertTrue(overlay.presented)
    }

    func test_sessionEnd_clearsThePass_butLeavesALimitsBlock() {
        blockOn("https://x.com/home", at: Date())
        overlay.letMeThrough()
        overlay.present(BlockRequest(appName: "Safari", bundleId: "com.apple.Safari", host: "youtube.com",
                                     reason: .dailyLimit(LimitBlock(limitID: UUID(), name: "youtube.com", minutesToday: 30,
                                                                    extraTime: OverridePolicy.standard.extraTime, extraLeft: 1))))
        engine.resetForSessionEnd()
        XCTAssertNil(engine.activePass)
        XCTAssertTrue(overlay.presented, "a daily limit blocks all day, not just in sessions")
    }

    func test_sessionEnd_takesDownADriftBlock() {
        blockOn("https://x.com/home", at: Date())
        engine.resetForSessionEnd()
        XCTAssertFalse(overlay.presented)
    }

    // MARK: - Strict's lock

    func test_strictLock_keepsBlockedSitesBlocked() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let classifier = Classifier(context: container.mainContext)
        XCTAssertTrue(classifier.setOverride(host: "x.com", classification: .distraction))

        classifier.isBlockListLocked = { true }
        XCTAssertFalse(classifier.setOverride(host: "x.com", classification: .focus))
        XCTAssertFalse(classifier.setOverride(host: "m.x.com", classification: .neutral), "nor through a subdomain")
        XCTAssertTrue(classifier.setOverride(host: "reddit.com", classification: .distraction), "adding to the list is fine")
        XCTAssertTrue(classifier.setOverride(host: "github.com", classification: .focus), "what isn't blocked can change")
        XCTAssertEqual(classifier.classify(bundleId: "com.apple.Safari", windowTitle: nil, url: "https://x.com/home"), .distraction)

        classifier.isBlockListLocked = { false }
        XCTAssertTrue(classifier.setOverride(host: "x.com", classification: .focus))
    }
}
