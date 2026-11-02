import AppKit
import XCTest

/// Whole flows through the window with real mouse events: a session from
/// start to finish, renaming and deleting, reports, rules, the upgrade path,
/// settings. The app runs in UITestMode with sample data (see `UITestMode`)
/// and on a pretend plan, so nothing here touches a real trial.
///
/// These look for controls by their English labels, except the odd-states
/// tests at the end, which only open pages and look at what's on them.
final class FlowClickTests: XCTestCase {
    private var app: XCUIApplication!
    private var window: XCUIElement { app.windows["FocusGuard"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func launch(plan: String = "free", seed: String? = nil, language: String = "en", locale: String = "en_US",
                        extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [
            "-FocusGuardUITesting",
            "-calendarAutostart.enabled", "NO",
            "-plan.debugOverride", plan,
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        if let seed { app.launchArguments += ["-FocusGuardUITestSeed", seed] }
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The window didn't open")
    }

    // MARK: - Helpers

    private func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) is missing", file: file, line: line)
        let screenWidth = NSScreen.main?.frame.width ?? .greatestFiniteMagnitude
        try XCTSkipIf(element.frame.midX > screenWidth, "\(element.label) is past the edge of this \(Int(screenWidth))-point screen")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func open(_ page: String) throws {
        try click(window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch)
    }

    private func button(_ label: String) -> XCUIElement { window.buttons[label].firstMatch }

    private func buttonStarting(_ words: String) -> XCUIElement {
        window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    /// Whether `words` are on screen. Most text has a value; a heading can
    /// only be found whole, by subscript.
    private func isShown(_ words: String) -> Bool {
        window.staticTexts[words].exists
            || window.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@", words)).firstMatch.exists
    }

    private func waitForText(_ words: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = expectation(for: NSPredicate { _, _ in self.isShown(words) }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 6), .completed, message, file: file, line: line)
    }

    private func waitGoneText(_ words: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = expectation(for: NSPredicate { _, _ in !self.isShown(words) }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 6), .completed, message, file: file, line: line)
    }

    private func waitFor(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 6), message, file: file, line: line)
    }

    private func waitGone(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 6), .completed, message, file: file, line: line)
    }

    private func toggle(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "(elementType == %d OR elementType == %d OR elementType == %d) AND label BEGINSWITH %@",
                                  XCUIElement.ElementType.switch.rawValue, XCUIElement.ElementType.checkBox.rawValue,
                                  XCUIElement.ElementType.toggle.rawValue, title))
            .firstMatch
    }

    /// The element covers the whole row; the switch is at its right end.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).click()
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        if let on = toggle.value as? Bool { return on }
        if let on = toggle.value as? Int { return on != 0 }
        if let on = toggle.value as? String { return on == "1" || on == "true" }
        return false
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Every page

    func testEveryPageOpensOnFreeWithItsLockedPages() throws {
        launch()
        try open("Reports")
        waitFor(button("Share week"), "Reports didn't open")
        try open("Ask")
        waitForText("Questions about your own focus", "Ask's Pro page didn't open")
        try open("Work log")
        waitForText("Your week, written up for you", "Work log's Pro page didn't open")
        try open("Apps & Sites")
        waitFor(button("Sort your apps"), "Apps & Sites didn't open")
        try open("Settings")
        waitFor(button("Integrations"), "Settings didn't open")
        try open("Today")
        waitFor(button("Previous day"), "Today didn't open")
    }

    func testAskAndWorkLogWorkOnPro() throws {
        launch(plan: "pro")
        try open("Ask")
        let field = window.textFields["Your question"].firstMatch
        try click(field)
        field.typeText("When do I focus best?\r")
        waitFor(window.otherElements["You asked: When do I focus best?"], "The question didn't go in")
        // There's sample data, so the answer has a chart or says what it's based on.
        let answered = window.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'session' OR value CONTAINS[c] 'focus'"))
        XCTAssertTrue(answered.firstMatch.waitForExistence(timeout: 15), "No answer came")
        shoot("ask-answer")

        try open("Work log")
        waitFor(button("Previous week"), "Work log didn't open")
        try click(button("Previous week"))
        waitFor(button("Next week"), "The week didn't step")
    }

    // MARK: - A session

    func testASessionFromTodayFromStartToFinish() throws {
        launch()
        try open("Today")

        // The length choices change what Start starts.
        try click(button("90 min"))
        waitFor(button("Start 90 minutes of focus"), "90 min didn't take")
        try click(button("Open"))
        waitFor(button("Start an open session"), "Open didn't take")
        try click(button("25 min"))
        let start = button("Start 25 minutes of focus")
        waitFor(start, "25 min didn't take")

        // Start.
        try click(start)
        waitForText("Current session", "The session didn't start")
        waitForText("min left", "No time left shown")
        waitForText("Now", "Its Now row isn't in the list")
        waitFor(window.buttons["Pause session"], "The sidebar's card didn't change")
        shoot("session-running")

        // Pause and resume, from the card.
        try click(button("Pause"))
        waitFor(button("Resume"), "Pause didn't take")
        waitForText("Paused", "It doesn't say paused")
        waitFor(window.buttons["Resume session"], "The sidebar doesn't say it's paused")
        try click(button("Resume"))
        waitFor(button("Pause"), "Resume didn't take")
        waitForText("Current session", "It doesn't say it's running")

        // Extend, then end.
        try click(button("5 more min"))
        try click(button("End"))
        waitForText("Ready to focus", "End didn't end it")
        waitForText("Last one:", "No word on the last session")
        waitGoneText("Current session", "The session card stayed")
        waitFor(buttonStarting("Start 25 min focus"), "The sidebar's start button didn't come back with the same length")
    }

    func testAnOpenSessionFromTheSidebar() throws {
        launch()
        try open("Today")
        try click(button("Open"))
        waitFor(button("Start focus"), "The sidebar doesn't offer an open session")
        try click(button("Start focus"))
        waitForText("min in", "It doesn't count up")
        XCTAssertFalse(button("5 more min").exists, "an open session has no end to push out")
        try click(window.buttons["Pause session"])
        waitFor(window.buttons["Resume session"], "Pause from the sidebar didn't take")
        try click(window.buttons["Resume session"])
        waitFor(window.buttons["Pause session"], "Resume from the sidebar didn't take")
        try click(button("End"))
        waitForText("Ready to focus", "End didn't end it")
    }

    func testASessionSurvivesGoingRoundThePages() throws {
        launch()
        try open("Today")
        try click(button("25 min"))
        try click(button("Start 25 minutes of focus"))
        waitForText("Current session", "The session didn't start")
        for page in ["Reports", "Apps & Sites", "Settings", "Today"] {
            try open(page)
            waitFor(window.buttons["Pause session"], "The sidebar lost the session on \(page)")
        }
        waitForText("Current session", "Today lost the session")
    }

    // MARK: - Rename and delete

    /// A session's row: its time line ends in minutes.
    private var sessionRow: XCUIElement {
        window.staticTexts.matching(NSPredicate(format: "value MATCHES '.*[0-9]+ min$' AND value CONTAINS '·'")).firstMatch
    }

    func testRenameAndDeleteASession() throws {
        launch()
        try open("Today")
        waitFor(sessionRow, "The sample session isn't listed")

        // Rename: the buttons show on hover.
        sessionRow.hover()
        try click(button("Rename"))
        let field = window.textFields["Name"].firstMatch
        waitFor(field, "No field to rename in")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Tax return\r")
        waitForText("Tax return", "The new name didn't show")

        // Delete, confirmed: the row goes, the time stays.
        sessionRow.hover()
        try click(button("Delete"))
        let confirm = window.sheets.buttons["Delete Session"].firstMatch
        waitFor(confirm, "No confirmation")
        confirm.click()
        waitForText("No sessions yet", "The row stayed")
        waitGoneText("Tax return", "The row stayed")
        waitForText("Xcode", "Its activity should stay in top apps")
    }

    func testCancellingADeleteKeepsTheSession() throws {
        launch()
        try open("Today")
        waitFor(sessionRow, "The sample session isn't listed")
        sessionRow.hover()
        try click(button("Delete"))
        let cancel = window.sheets.buttons["Cancel"].firstMatch
        waitFor(cancel, "No confirmation")
        cancel.click()
        waitFor(sessionRow, "The session went without saying so")
    }

    // MARK: - Days

    func testDayArrowsReachYesterdayAndStopAtFreeHistory() throws {
        launch()
        try open("Today")
        let previous = button("Previous day")
        let next = button("Next day")
        waitFor(next, "No arrows")
        XCTAssertFalse(next.isEnabled, "Nothing after today")

        try click(previous)
        waitForText("The day in numbers", "An earlier day shows its numbers")
        XCTAssertTrue(next.isEnabled)
        try click(next)
        waitForText("Your day", "Back on today")

        // Free reaches back 30 days, today included.
        for _ in 0..<29 {
            guard previous.isEnabled else { break }
            try click(previous)
        }
        XCTAssertFalse(previous.isEnabled, "Free stops after 30 days")
    }

    // MARK: - Reports

    func testReportsMonthInReviewAndTrialFromIt() throws {
        // Months of data, so last month has a review to open.
        launch(seed: "big")
        try open("Reports")
        try click(button("Month"))
        waitForText("Month in review", "Month in review isn't offered")
        XCTAssertFalse(button("Share week").exists, "Share week belongs to a week")

        // Trying it starts the (pretend) trial, and the locked line goes.
        waitForText("what changed, how your experiments went", "Month in review should start locked")
        try click(button("Try Pro free"))
        waitGoneText("what changed, how your experiments went", "The trial didn't open it up")
        shoot("month-review-strip")
    }

    func testReportsStepBackAndForward() throws {
        launch()
        try open("Reports")
        let previous = button("Previous week")
        try click(previous)
        waitFor(button("Next week"), "No way forward")
        try click(button("Next week"))
        try click(button("Month"))
        try click(button("Previous month"))
        let last = Calendar.current.date(byAdding: .month, value: -1, to: .now)?.formatted(.dateTime.month(.wide)) ?? ""
        waitForText(last, "Didn't go back a month")
        try click(button("Week"))
        waitFor(button("Share week"), "Week didn't come back")
    }

    func testShareWeekOpensTheComposer() throws {
        launch()
        try open("Reports")
        try click(button("Share week"))
        let composer = app.windows.matching(NSPredicate(format: "title == 'Share your focus week'")).firstMatch
        waitFor(composer, "The share composer didn't open")
        shoot("share-composer")
        composer.typeKey("w", modifierFlags: .command)
        waitGone(composer, "The share composer didn't close")
    }

    func testExportOpensASavePanelAndCancels() throws {
        launch()
        try open("Today")
        try click(button("Export"))
        let save = app.buttons["Save"].firstMatch
        waitFor(save, "No save panel")
        shoot("export-panel")
        app.typeKey(.escape, modifierFlags: [])
        waitGone(save, "The save panel stayed")
    }

    // MARK: - Apps & Sites

    func testNewRuleSheetAddsARuleAndItCanBeDeleted() throws {
        launch()
        try open("Apps & Sites")
        try click(button("Add rule"))
        let sheet = window.sheets.firstMatch
        waitFor(sheet, "The sheet didn't open")

        // Cancel leaves nothing.
        try click(sheet.buttons["Cancel"].firstMatch)
        waitGone(sheet, "Cancel didn't close it")

        try click(button("Add rule"))
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        try click(sheet.radioButtons["Site"].firstMatch)
        let field = sheet.textFields.firstMatch
        try click(field)
        field.typeText("www.Example.org/some/page")
        // Nothing wrong with the default category; add it.
        try click(sheet.buttons["Add rule"].firstMatch)
        waitGone(sheet, "Add rule didn't close it")

        // It's on Rules, cleaned up to the host.
        try click(buttonStarting("Rules"))
        waitForText("example.org", "The rule isn't listed")
        try click(window.buttons["Delete rule example.org"].firstMatch)
        waitGoneText("example.org", "The rule didn't go")
    }

    func testChangingACategoryCountsAgainInTheFilters() throws {
        launch()
        try open("Apps & Sites")
        waitForText("Xcode", "No apps to sort")
        let distracting = buttonStarting("Distracting")
        waitFor(distracting, "No filters")
        let before = distracting.label
        // Xcode's row: its control is named for it.
        let control = window.groups["Xcode counts as"].firstMatch
        waitFor(control, "Xcode's category control is missing")
        try click(control.buttons["Distracting"].firstMatch)
        let changed = expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: distracting)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed, "The filter's count didn't follow")

        // The filter shows it, and search narrows it.
        try click(distracting)
        waitForText("Xcode", "Filtered out what it should show")
        let search = window.textFields["Search apps and sites"].firstMatch
        try click(search)
        search.typeText("no such app")
        waitForText("Nothing matches.", "Search didn't narrow it")
    }

    func testSortYourAppsOpens() throws {
        launch()
        try open("Apps & Sites")
        try click(button("Sort your apps"))
        waitGone(button("Add rule"), "Sort didn't take over the page")
        shoot("sort-apps")
        try open("Today")
        try open("Apps & Sites")
        waitFor(button("Add rule"), "Leaving Sort didn't leave it")
    }

    // MARK: - Upgrade, trial, licence

    func testUpgradeSheetLicenceSheetAndTheTrial() throws {
        launch()
        try open("Settings")
        try click(button("Pro & licence"))
        waitForText("It starts when you turn on a Pro feature", "The plan card should say how the trial starts")

        // The licence sheet turns a key down, and says why.
        try click(button("Enter a licence key…"))
        let key = window.sheets.textFields["Licence key"].firstMatch
        waitFor(key, "The licence sheet didn't open")
        try click(key)
        key.typeText("FG-NOT-A-REAL-KEY\r")
        waitForText("Licence keys aren't available yet.", "A bad key should say why")
        try click(window.sheets.buttons["Cancel"].firstMatch)
        waitGone(key, "Cancel didn't close it")

        // The upgrade sheet: nothing changes until the trial is asked for.
        XCTAssertTrue(buttonStarting("Work log").label.contains("Pro"), "Work log should be marked Pro before the trial")
        try click(button("Try Pro free for 14 days"))
        let start = window.sheets.buttons["Start the 14-day free trial"].firstMatch
        waitFor(start, "The upgrade sheet didn't open")
        shoot("upgrade-sheet")
        window.sheets.buttons["Close"].firstMatch.click()
        waitGone(start, "Close didn't close it")
        waitForText("It starts when you turn on a Pro feature", "Looking at the sheet started something")

        // The trial: the plan changes where it shows, and the Pro pages open.
        try click(button("Try Pro free for 14 days"))
        try click(start)
        waitGone(start, "The upgrade sheet stayed")
        waitForText("Pro trial", "The plan didn't change")
        waitForText("Ends on", "No end date")
        XCTAssertFalse(buttonStarting("Work log").label.contains("Pro"), "The badge should go with the trial")
        try open("Work log")
        waitFor(button("Previous week"), "Work log should open on the trial")
    }

    func testAskTrialButtonUnlocksThePageInPlace() throws {
        launch()
        try open("Ask")
        try click(button("Try Pro free for 14 days"))
        waitFor(window.textFields["Your question"].firstMatch, "Ask didn't open up on the trial")
    }

    // MARK: - Settings

    func testEverySettingsPaneOpens() throws {
        launch()
        try open("Settings")
        let panes: [(String, String)] = [
            ("Sessions", "how hard FocusGuard pushes back"),
            ("Blocking", "Levels add up"),
            ("Daily limits", "Counts in and out of sessions"),
            ("Notifications", "never with a sound"),
            ("Integrations", "working with your sessions"),
            ("Privacy & data", "how to take it all back"),
            ("Pro & licence", "Your plan, your trial"),
            ("General", "Changes save straight away"),
        ]
        for (pane, words) in panes {
            try click(button(pane))
            waitForText(words, "\(pane) didn't open")
            shoot("settings-\(pane)")
        }
        try click(button("About"))
        waitForText("FocusGuard", "About didn't open")
    }

    /// Flipped, gone to another pane and back, then the app quit and opened
    /// again: each switch holds. (Only ones that ask nothing of the system.)
    func testSwitchesPersist() throws {
        launch()
        try open("Settings")
        let switches: [(pane: String, title: String)] = [
            ("General", "Show time in the menu bar"),
            ("Sessions", "Strict breaks"),
            ("Sessions", "Weekends count toward the streak"),
            ("Notifications", "Morning plan"),
            ("Notifications", "Evening wrap-up"),
            ("Privacy & data", "Site icons"),
        ]
        var flipped: [String: Bool] = [:]
        for item in switches {
            try click(button(item.pane))
            let control = toggle(item.title)
            waitFor(control, "\(item.title) is missing")
            let before = isOn(control)
            flip(control)
            let changed = expectation(for: NSPredicate { _, _ in self.isOn(control) != before }, evaluatedWith: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 4), .completed, "\(item.title) didn't flip")
            flipped[item.title] = !before

            try click(button("About"))
            try click(button(item.pane))
            waitFor(toggle(item.title), "\(item.title) went missing")
            XCTAssertEqual(isOn(toggle(item.title)), !before, "\(item.title) didn't hold across panes")
        }

        app.terminate()
        launch()
        try open("Settings")
        for item in switches {
            try click(button(item.pane))
            waitFor(toggle(item.title), "\(item.title) went missing after a relaunch")
            XCTAssertEqual(isOn(toggle(item.title)), flipped[item.title], "\(item.title) didn't survive a relaunch")
            // Back as it was, for the tests after this one.
            flip(toggle(item.title))
        }
    }

    // MARK: - A short window

    /// The runners' screen leaves about 670 points above the Dock, under what
    /// the pages' content used to insist on: opening at all crashed. Every
    /// test here runs in that window; this one goes to its minimum height as
    /// well, by dragging its bottom edge, and round the pages there. (Its right
    /// edge is at the screen's, so there's no dragging that on this screen.)
    func testTheWindowOpensToFitAndDragsToItsMinimum() throws {
        launch()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        XCTAssertLessThanOrEqual(window.frame.height, max(visible.height, 640) + 1, "It should fit above the Dock")
        XCTAssertLessThanOrEqual(window.frame.maxX, visible.maxX + 1, "It should fit the screen")

        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 1))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: -300)))
        XCTAssertEqual(window.frame.height, 640, accuracy: 2, "The window's minimum height")
        for page in ["Reports", "Apps & Sites", "Settings", "Today"] {
            try open(page)
            shoot("minimum-\(page)")
        }
        waitForText("Your day", "Today should still show at the minimum")
    }

    // MARK: - First run

    func testFirstRunWithNoData() throws {
        launch(seed: "empty", extra: ["-window.sessionLength", "0"])
        waitForText("Day one.", "The first-day page didn't show")
        waitForText("Getting set up", "The first-day checklist didn't show")
        waitForText("No sessions yet", "The sessions card should be empty")
        waitForText("Nothing tracked yet today.", "Top apps should be empty")
        shoot("first-run-today")

        try open("Reports")
        waitForText("No goal days yet this week.", "Reports should say there's nothing yet")
        shoot("first-run-reports")
        try click(button("Month"))
        waitForText("No goal days yet this month.", "Reports' month should say so too")

        try open("Apps & Sites")
        shoot("first-run-apps")
        try open("Settings")
        try open("Today")

        // The first session ends the first-day page.
        try click(buttonStarting("Start 50 minutes"))
        waitForText("Current session", "The session didn't start")
        waitGoneText("Day one.", "Still on the first-day page")
        try click(button("End"))
        waitForText("Ready to focus", "End didn't end it")
        waitGoneText("Getting set up", "The checklist should go once there's a session")
    }

    // MARK: - Odd states

    /// Time labels in a list: one line each, whatever the language or the
    /// size of the number.
    private func wrappedTimes(_ pattern: String) -> [String] {
        let labels = window.staticTexts.matching(NSPredicate(format: "value MATCHES %@", pattern))
        return (0..<labels.count).compactMap { index in
            let label = labels.element(boundBy: index)
            return label.frame.height > 22 ? "\(label.value ?? "") (\(Int(label.frame.height)) high)" : nil
        }
    }

    private func pagesWithBigData(language: String, locale: String, pages: [String], previousDay: String, month: String,
                                  timePattern: String) throws -> [String] {
        launch(seed: "big", language: language, locale: locale)
        var wrapped: [String] = []
        try open(pages[0])
        sleep(2)
        shoot("big-\(language)-today")
        wrapped += wrappedTimes(timePattern)
        try click(button(previousDay))
        sleep(2)
        shoot("big-\(language)-yesterday")
        wrapped += wrappedTimes(timePattern)
        try open(pages[1])
        sleep(3)
        shoot("big-\(language)-reports-week")
        wrapped += wrappedTimes(timePattern)
        try click(button(month))
        sleep(3)
        shoot("big-\(language)-reports-month")
        try open(pages[2])
        sleep(3)
        shoot("big-\(language)-apps")
        wrapped += wrappedTimes(timePattern)
        print("Wrapped in \(language): \(wrapped)")
        return wrapped
    }

    func testThreeYearsAndLongNamesInEnglish() throws {
        let wrapped = try pagesWithBigData(language: "en", locale: "en_US",
                                           pages: ["Today", "Reports", "Apps & Sites"], previousDay: "Previous day", month: "Month",
                                           timePattern: "[0-9,]+h( [0-9]+m)?")
        XCTExpectFailure("Bug: TopAppRow (TodayPage.swift:358) gives the time 44 pt with no line limit: '11h 05m' wraps", strict: false) {
            XCTAssertEqual(wrapped, [])
        }
    }

    func testThreeYearsAndLongNamesInGerman() throws {
        let wrapped = try pagesWithBigData(language: "de", locale: "de_DE",
                                           pages: ["Heute", "Berichte", "Apps & Websites"], previousDay: "Vorheriger Tag", month: "Monat",
                                           timePattern: "[0-9.]+ Std( [0-9]+ Min)?")
        XCTExpectFailure("Bug: TopAppRow (TodayPage.swift:358): '11 Std 05 Min' wraps in its 44 pt", strict: false) {
            XCTAssertEqual(wrapped, [])
        }
    }

    func testThreeYearsAndLongNamesInAzerbaijani() throws {
        let wrapped = try pagesWithBigData(language: "az", locale: "az_AZ",
                                           pages: ["Bu gün", "Hesabatlar", "Tətbiqlər və saytlar"], previousDay: "Əvvəlki gün", month: "Ay",
                                           timePattern: "[0-9.]+ s( [0-9]+ dəq)?")
        XCTExpectFailure("Bug: TopAppRow (TodayPage.swift:358): '11 s 05 dəq' wraps in its 44 pt", strict: false) {
            XCTAssertEqual(wrapped, [])
        }
    }
}
