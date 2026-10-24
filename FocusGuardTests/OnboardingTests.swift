import XCTest
@testable import FocusGuard

/// Onboarding's rules: a Pro blocking level starts the trial, the browser
/// extension never does, whole-Mac blocking waits, and what each step says.
@MainActor
final class OnboardingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// A fixed clock, as in EntitlementsTests.
    private var clock = Date(timeIntervalSince1970: 1_906_566_400)

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OnboardingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func make() -> Entitlements {
        Entitlements(defaults: defaults, reminder: nil, now: { [weak self] in self?.clock ?? .now })
    }

    // MARK: - Blocking level and the trial

    func test_pausingTheTab_isFree_andStartsNothing() {
        let entitlements = make()
        BlockingLevel.pauseTab.commit(entitlements)
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertTrue(entitlements.canStartTrial)
    }

    func test_blockingInTheBrowser_startsTheTrial() {
        let entitlements = make()
        XCTAssertTrue(BlockingLevel.browser.isAvailable(entitlements))
        BlockingLevel.browser.commit(entitlements)
        guard case .trial = entitlements.plan else { return XCTFail("expected the trial, got \(entitlements.plan)") }
        XCTAssertTrue(entitlements.isUnlocked(.blockInBrowser))
        XCTAssertEqual(BlockingLevel.initial(entitlements), .browser)
    }

    func test_wholeMacBlocking_isComingLater() {
        let entitlements = make()
        XCTAssertFalse(BlockingLevel.wholeMac.isAvailable(entitlements))
        BlockingLevel.wholeMac.commit(entitlements)
        XCTAssertEqual(entitlements.plan, .free, "picking a level that isn't built must not use up the trial")
    }

    func test_afterTheTrial_browserBlockingNeedsPro() {
        let entitlements = make()
        BlockingLevel.browser.commit(entitlements)
        clock = clock.addingTimeInterval(TimeInterval(Plan.trialDays + 1) * 86_400)
        entitlements.refresh()
        XCTAssertEqual(entitlements.plan, .free)
        XCTAssertFalse(BlockingLevel.browser.isAvailable(entitlements))
        XCTAssertEqual(BlockingLevel.initial(entitlements), .pauseTab)
        XCTAssertEqual(SetupStep.planNote(entitlements, now: clock), "Your free trial has been used, so the Pro levels need Pro.")
    }

    func test_planNote() {
        let entitlements = make()
        XCTAssertEqual(SetupStep.planNote(entitlements, now: clock),
                       "A Pro level starts a 14-day free trial. No card, and a reminder 2 days before it ends.")
        BlockingLevel.browser.commit(entitlements)
        XCTAssertEqual(SetupStep.planNote(entitlements, now: clock), "Your Pro trial has 14 days left.")
    }

    // MARK: - The extension step

    func test_extensionStep_neverPromisesATrial() {
        let entitlements = make()
        XCTAssertEqual(ExtensionStep.note(level: .pauseTab, plan: entitlements.plan),
                       "Free to add, and adding it never starts a trial.")
        XCTAssertEqual(ExtensionStep.note(level: .browser, plan: .trial(endsAt: clock)),
                       "Free to add, and adding it never starts a trial. Your Pro trial covers the extras.")
        XCTAssertEqual(entitlements.plan, .free)
    }

    func test_addToChrome_goesToAWebPage() throws {
        let url = try XCTUnwrap(ExtensionLinks.addToChrome)
        XCTAssertEqual(url.scheme, "https")
    }

    // MARK: - Permissions

    func test_browserAccess() {
        let ok = noErr, asked = BrowserAccess.notAsked, no = BrowserAccess.notPermitted
        XCTAssertEqual(BrowserAccess.state(answers: [], extensionConnected: true, deniedBefore: true), .allowed,
                       "the extension reads tabs without Apple Events")
        XCTAssertEqual(BrowserAccess.state(answers: [no, ok], extensionConnected: false, deniedBefore: false), .allowed)
        XCTAssertEqual(BrowserAccess.state(answers: [asked, no], extensionConnected: false, deniedBefore: false), .openSettings)
        XCTAssertEqual(BrowserAccess.state(answers: [asked], extensionConnected: false, deniedBefore: true), .openSettings)
        XCTAssertEqual(BrowserAccess.state(answers: [asked], extensionConnected: false, deniedBefore: false), .ask)
        XCTAssertEqual(BrowserAccess.state(answers: [], extensionConnected: false, deniedBefore: false), .asksOnUse,
                       "no browser open: macOS asks on first use")
    }

    // MARK: - Setup words

    func test_presetPreview() {
        XCTAssertEqual(SetupPanel.presetLine(.gentle), "Gentle: a nudge at 1:00, the block screen at 3:00.")
        XCTAssertEqual(SetupPanel.presetLine(.standard), "Standard: a nudge at 0:30, the block screen at 1:30.")
        XCTAssertTrue(SetupPanel.presetLine(.strict).hasPrefix("Strict: the block screen at once."))
        XCTAssertEqual(SetupPanel.presetLine(nil), "Your own timings from Settings.")
    }

    func test_onboardingHasFourSteps() {
        XCTAssertEqual(OnboardingView.Step.allCases.count, 4)
        XCTAssertEqual(OnboardingWindowController.size, NSSize(width: 960, height: 640))
    }
}
