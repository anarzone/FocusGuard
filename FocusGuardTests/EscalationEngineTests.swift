import XCTest
@testable import FocusGuard

@MainActor
final class EscalationEngineTests: XCTestCase {

    // MARK: - Stubs

    /// Records calls so we can assert on what the engine triggered.
    final class RecordingPresenter: DistractionNotifier {
        var distractionCalls: [(appName: String, url: String?)] = []
        func presentDistractionWarning(appName: String, currentURL: String?) {
            distractionCalls.append((appName, currentURL))
        }
    }

    final class StubOverlay: BlockOverlayPresenting {
        var presented = false
        var onOverride: (() -> Void)?
        var isPresenting: Bool { presented }
        func present(distractionAppName: String, urlHost: String?, overrideSeconds: Int) {
            presented = true
        }
        func dismiss() { presented = false; onOverride?() }
    }

    var presenter: RecordingPresenter!
    var overlay: StubOverlay!
    var engine: EscalationEngine!

    override func setUp() async throws {
        try await super.setUp()
        presenter = RecordingPresenter()
        overlay = StubOverlay()
        engine = EscalationEngine(presenter: presenter, overlay: overlay)
        engine.silenceThreshold = 10
        engine.notifyThreshold = 30
        engine.blockThreshold = 60
        engine.notifyCooldown = 60
    }

    private func snap(at: Date, kind: Classification = .distraction, app: String = "Twitter", url: String? = nil) -> ActivitySnapshot {
        ActivitySnapshot(
            bundleIdentifier: "com.example",
            appName: app,
            windowTitle: nil,
            url: url,
            classification: kind,
            observedAt: at
        )
    }

    // MARK: - Streak basics

    func test_silentBeforeNotifyThreshold() {
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(15)), isInSession: true)

        XCTAssertEqual(presenter.distractionCalls.count, 0)
        XCTAssertFalse(overlay.presented)
    }

    func test_notificationFiresAtNotifyThreshold() {
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(35)), isInSession: true)

        XCTAssertEqual(presenter.distractionCalls.count, 1)
        XCTAssertEqual(presenter.distractionCalls.first?.appName, "Twitter")
    }

    func test_notificationCooldownPreventsRepeat() {
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(35)), isInSession: true)
        // Another tick within cooldown — must NOT fire again.
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(40)), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(50)), isInSession: true)

        XCTAssertEqual(presenter.distractionCalls.count, 1)
    }

    func test_blockOverlayFiresAtBlockThreshold() {
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(70)), isInSession: true)

        XCTAssertTrue(overlay.presented)
    }

    // MARK: - Reset paths

    func test_streakResetsOnFocusActivity() {
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(20)), isInSession: true)
        // User goes back to focus → streak resets.
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(25), kind: .focus, app: "PhpStorm"), isInSession: true)
        // Distraction starts fresh — needs 30s again.
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(30)), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(40)), isInSession: true)

        XCTAssertEqual(presenter.distractionCalls.count, 0)
    }

    func test_observeNoOpOutsideSession() {
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: false)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(120)), isInSession: false)

        XCTAssertEqual(presenter.distractionCalls.count, 0)
        XCTAssertFalse(overlay.presented)
    }

    func test_resetForSessionEndDismissesOverlay() {
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: true)
        engine.observe(snapshot: snap(at: t0.addingTimeInterval(70)), isInSession: true)
        XCTAssertTrue(overlay.presented)

        engine.resetForSessionEnd()
        XCTAssertFalse(overlay.presented)
    }

    // MARK: - Strict mode

    func test_strictModeBlocksImmediately() {
        engine.strictMode = true
        let t0 = Date()
        engine.observe(snapshot: snap(at: t0), isInSession: true)

        XCTAssertTrue(overlay.presented)
        XCTAssertEqual(presenter.distractionCalls.count, 0)
    }
}
