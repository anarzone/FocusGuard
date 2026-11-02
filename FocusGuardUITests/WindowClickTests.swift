import AppKit
import XCTest

/// Clicks the window the way a person does: real mouse events through the
/// window server, so anything lying over a control or catching its clicks
/// shows up here. (Accessibility presses, which the unit tests and checks
/// by hand used, go straight to the control and miss that: a header that
/// ignored every real click passed them all.)
///
/// The app runs in UITestMode: its own in-memory store with sample data,
/// opened straight into the window, beside any real FocusGuard.
final class WindowClickTests: XCTestCase {
    private var app: XCUIApplication!
    private var window: XCUIElement { app.windows["FocusGuard"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-FocusGuardUITesting",
            // Never start a session from the Mac's real calendar.
            "-calendarAutostart.enabled", "NO",
            // These look for controls by their English labels.
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The window didn't open")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// A sidebar row; its label may carry a badge ("Work log, PRO").
    private func open(_ page: String) throws {
        try click(window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch)
    }

    /// A real mouse click at the element's centre. XCUITest's own `click()`
    /// first asks accessibility what's at that point, and for the page
    /// header it answers with the window's empty toolbar strip, so it
    /// refuses; a click there does reach the button, which is what this
    /// checks.
    ///
    /// The window is at least 1200 points wide; on a narrower screen (the
    /// CI runners' are 1024) the right of the header is off it, where no
    /// click can land, so those checks are skipped there.
    private func click(_ element: XCUIElement) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) is missing")
        let screenWidth = NSScreen.main?.frame.width ?? .greatestFiniteMagnitude
        try XCTSkipIf(element.frame.maxX > screenWidth,
                      "\(element.label) is past the edge of this \(Int(screenWidth))-point screen")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func waitFor(_ element: XCUIElement, _ message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), message)
    }

    private func waitForEither(_ one: XCUIElement, _ other: XCUIElement, _ message: String) {
        let shown = expectation(for: NSPredicate { _, _ in one.exists || other.exists }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, message)
    }

    private func text(containing words: String) -> XCUIElement {
        window.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", words, words)).firstMatch
    }

    // MARK: - Sidebar

    func testSidebarOpensEveryPage() throws {
        try open("Reports")
        waitFor(window.buttons["Share week"], "Reports didn't open")
        try open("Work log")
        // Unlocked it has a week stepper; on the free plan, its Pro page.
        waitForEither(window.buttons["Previous week"], text(containing: "FocusGuard Pro"), "Work log didn't open")
        try open("Apps & Sites")
        waitFor(window.buttons["Sort your apps"], "Apps & Sites didn't open")
        try open("Settings")
        waitFor(window.buttons["Integrations"], "Settings didn't open")
        try open("Today")
        waitFor(window.buttons["Previous day"], "Today didn't open")
    }

    // MARK: - Headers

    func testTodayDayArrows() throws {
        try open("Today")
        let next = window.buttons["Next day"]
        waitFor(next, "Today's day arrows are missing")
        XCTAssertFalse(next.isEnabled, "Next day should be off on today")

        try click(window.buttons["Previous day"])
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        waitFor(text(containing: yesterday.formatted(.dateTime.weekday(.wide))), "Previous day didn't go back a day")
        XCTAssertTrue(next.isEnabled, "Next day should be on for yesterday")

        try click(next)
        let backToToday = expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: next)
        wait(for: [backToToday], timeout: 5)
    }

    func testReportsWeekMonthAndArrows() throws {
        try open("Reports")
        waitFor(window.buttons["Month"], "Reports' period switch is missing")

        try click(window.buttons["Month"])
        let thisMonth = Date.now.formatted(.dateTime.month(.wide))
        waitFor(text(containing: thisMonth), "Month didn't switch the report")
        XCTAssertFalse(window.buttons["Share week"].exists, "Share week only belongs to a week")

        try click(window.buttons["Previous month"])
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: .now)!.formatted(.dateTime.month(.wide))
        waitFor(text(containing: lastMonth), "Previous month didn't go back a month")

        try click(window.buttons["Week"])
        waitFor(window.buttons["Share week"], "Week didn't switch back")
    }

    func testAppsUsedAndRules() throws {
        try open("Apps & Sites")
        let rules = window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rules'")).firstMatch
        waitFor(rules, "The Used | Rules switch is missing")
        try click(rules)
        waitFor(text(containing: "Rules decide how new activity is sorted"), "Rules didn't open")
        try click(window.buttons["Used"])
        waitFor(text(containing: "Decide what counts as focus"), "Used didn't come back")
    }

    // MARK: - Pages that fit don't scroll

    /// At the window's usual size, Today and both reports fit: scrolling
    /// moves nothing.
    func testPagesThatFitDontScroll() throws {
        try XCTSkipIf(window.frame.height < 700, "The screen is too small for the usual window size")
        try open("Today")
        // Without the app's permissions (as in CI) Today adds a banner
        // asking for them: more to see, so it may scroll then.
        if !text(containing: "FocusGuard needs").waitForExistence(timeout: 2) {
            assertStays(window.staticTexts["Your day"], "Today")
        }
        try open("Reports")
        assertStays(window.staticTexts["Focus and drift per day"], "Reports › Week")
        try click(window.buttons["Month"])
        assertStays(window.staticTexts["Daily goal"], "Reports › Month")
    }

    /// Scrolls both ways, so a page that does scroll moves one way or the other.
    private func assertStays(_ element: XCUIElement, _ page: String) {
        waitFor(element, "\(page) didn't show")
        let top = element.frame.minY
        for delta in [-300.0, 300.0] {
            element.scroll(byDeltaX: 0, deltaY: delta)
            XCTAssertEqual(element.frame.minY, top, accuracy: 1, "\(page) scrolled though it fits the window")
        }
    }
}
