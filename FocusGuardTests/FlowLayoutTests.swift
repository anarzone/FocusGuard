import AppKit
import SwiftUI
import XCTest
@testable import FocusGuard

/// Values in fixed-width frames: a label sized for "45m" when the value can
/// grow, or for English when German and Azerbaijani run longer. (The "100%"
/// that wrapped was one of these.) Each case measures the view's own font
/// and width with the real translations, for the largest value it can show.
/// The views are private to their pages, so the fonts and widths are copied
/// here with a pointer to where they're from.
@MainActor
final class FlowLayoutTests: XCTestCase {
    /// A translated format from the built app, for `lang`.
    private func tr(_ key: String, _ lang: String) throws -> String {
        guard lang != "en" else { return key }
        let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"), "no \(lang) in the app")
        let bundle = try XCTUnwrap(Bundle(path: path))
        let value = bundle.localizedString(forKey: key, value: "\u{1F}", table: nil)
        XCTAssertNotEqual(value, "\u{1F}", "no \(lang) for \(key)")
        return value
    }

    /// "12h 05m", in each language, the way `WindowFormat.hm` writes it.
    private func hm(_ hours: Int, _ minutes: Int, _ lang: String) throws -> String {
        String(format: try tr("%lldh %@m", lang), hours, String(format: "%02d", minutes) as NSString)
    }

    /// "12h 5m", the way `formatDuration` writes it.
    private func short(_ hours: Int, _ minutes: Int, _ lang: String) throws -> String {
        String(format: try tr("%lldh %lldm", lang), hours, minutes)
    }

    private func width(_ text: String, _ font: Font) -> CGFloat {
        NSHostingView(rootView: Text(text).font(font).lineLimit(1).fixedSize()).fittingSize.width
    }

    /// Whether `text` stays on one line and whole in `limit` points.
    private func fits(_ text: String, _ font: Font, _ limit: CGFloat) -> Bool {
        width(text, font) <= limit
    }

    private func assertFits(_ texts: [String], _ font: Font, _ limit: CGFloat, _ place: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertTrue(fits(text, font, limit), "\(place): \"\(text)\" is \(width(text, font)) wide in \(limit)", file: file, line: line)
        }
    }

    private let languages = ["en", "de", "az"]

    // MARK: - Fits today

    func testValuesThatHaveRoom() throws {
        let body = Font.system(size: 12).monospacedDigit()
        // Apps & Sites' Time column (AppsSitesPage.swift:362), for 30 days of one app.
        try assertFits([hm(720, 5, "en"), hm(720, 5, "az"), hm(9, 5, "de")], body, 80, "Apps time column")
        // Rules' limit column (AppsSitesPage.swift:291) and the table's (:378).
        try assertFits(languages.map { String(format: try tr("%lld min", $0), 240) }, body, 58, "Apps limit column")
        // The sessions' count in a month's patterns (ReportCharts.swift:492).
        XCTAssertTrue(fits("99", .system(size: 12, weight: .semibold).monospacedDigit(), 22))
    }

    /// AppsSitesPage.swift:362 again: in German, ten hours is enough to wrap,
    /// and the page opens on the last 7 days.
    func testAppsTimeColumnInGermanPastTenHours() throws {
        let body = Font.system(size: 12).monospacedDigit()
        XCTExpectFailure("Bug: the Apps & Sites table (AppsSitesPage.swift:362) gives the time 80 pt with no line limit; German '10 Std 05 Min' is 81 wide and wraps") {
            assertFits([try! hm(10, 5, "de")], body, 80, "Apps time column")
        }
    }

    // MARK: - The Today page's top apps

    /// TodayPage.swift:355: `Text(hm).font(11, monospaced).frame(width: 44)`,
    /// no line limit, in a row 29 points high.
    func testTodaysTopAppsTimeFitsAWorkingDay() throws {
        let font = Font.system(size: 11).monospacedDigit()
        XCTAssertTrue(fits(try hm(9, 5, "en"), font, 44), "a single-digit hour in English")
        XCTExpectFailure("Bug: TopAppRow (TodayPage.swift:358) gives the time 44 pt with no line limit. '10h 05m', and every hour in German ('3 Std 05 Min') and Azerbaijani ('3 s 05 dəq') wrap onto two lines in a 29 pt row") {
            assertFits([try! hm(10, 5, "en"), try! hm(3, 5, "de"), try! hm(3, 5, "az")], font, 44, "Today top apps")
        }
    }

    // MARK: - The menu

    /// InsightsPane.swift:212: 12 pt in 52, no line limit.
    func testTheMenusInsightsTimeFits() throws {
        let font = Font.system(size: 12).monospacedDigit()
        XCTAssertTrue(fits(try short(9, 5, "en"), font, 52))
        XCTExpectFailure("Bug: InsightsPane (InsightsPane.swift:212) gives the time 52 pt with no line limit: German '3 Std 5 Min' and Azerbaijani '3 s 5 dəq' wrap, and so does an hours-long week's total in English ('100h 5m')") {
            assertFits([try! short(3, 5, "de"), try! short(3, 5, "az"), try! short(100, 5, "en")], font, 52, "Menu insights")
        }
    }

    /// InsightsPane.swift:323: 12 pt in 48, no line limit.
    func testTheMenusSecondListTimeFits() throws {
        let font = Font.system(size: 12).monospacedDigit()
        XCTExpectFailure("Bug: InsightsPane (InsightsPane.swift:323) gives the time 48 pt with no line limit: '10h 5m' and German or Azerbaijani hours wrap") {
            assertFits([try! short(10, 5, "en"), try! short(3, 5, "de"), try! short(3, 5, "az")], font, 48, "Menu insights list")
        }
    }

    /// MenuPanes.swift:234: 11 pt in 50, one line: it cuts rather than wraps.
    func testTheMenusUsageRowTimeFits() throws {
        let font = Font.system(size: 11).monospacedDigit()
        XCTAssertTrue(fits(try short(10, 5, "en"), font, 50))
        XCTExpectFailure("Bug: the usage row (MenuPanes.swift:234) gives the time 50 pt on one line, so German '3 Std 5 Min' and Azerbaijani '3 s 5 dəq' show cut off") {
            assertFits([try! short(3, 5, "de"), try! short(3, 5, "az")], font, 50, "Menu usage row")
        }
    }

    // MARK: - Words in narrow columns

    /// ReportCharts.swift:487: a session pattern's name, 12 pt in 74, one line.
    func testPatternNamesFitTheMonthsList() throws {
        let font = Font.system(size: 12)
        var cut: [String] = []
        for pattern in SessionNamer.Pattern.allCases {
            for lang in languages {
                let name = try tr(pattern.rawValue, lang)
                if !fits(name, font, 74) { cut.append("\(lang): \(name) (\(Int(width(name, font))))") }
            }
        }
        XCTExpectFailure("Bug: PatternList (ReportCharts.swift:487) gives the name 74 pt on one line: German 'Abschweifend' and Azerbaijani 'Gec başlayan' are cut off") {
            XCTAssertTrue(cut.isEmpty, "\(cut)")
        }
    }

    /// WorkLogPage.swift:210: "100% focus rate", 11 pt in 112, one line.
    func testTheWorkLogsRateFits() throws {
        let font = Font.system(size: 11)
        var cut: [String] = []
        for lang in languages {
            for key in ["%lld%% focus rate", "%lld%% so far"] {
                let text = String(format: try tr(key, lang), 100)
                if !fits(text, font, 112) { cut.append("\(lang): \(text) (\(Int(width(text, font))))") }
            }
        }
        XCTAssertTrue(cut.isEmpty, "\(cut)")
    }

    /// SettingsBlockingPane.swift:139: a preset's name, 12 pt semibold in 70.
    func testPresetNamesFitTheirColumn() throws {
        let font = Font.system(size: 12, weight: .semibold)
        for preset in ["Gentle", "Standard", "Strict"] {
            try assertFits(languages.map { try tr(preset, $0) }, font, 70, "Preset column")
        }
    }

    /// ReportCharts.swift:175: a weekday in the heat map, 10 pt in 28.
    func testWeekdaysFitTheHeatMap() {
        let font = Font.system(size: 10)
        for identifier in ["en", "de", "az"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: identifier)
            for name in calendar.shortWeekdaySymbols {
                XCTAssertTrue(fits(name, font, 28), "\(identifier): \(name) is \(width(name, font))")
            }
        }
    }

    // MARK: - The window on small screens

    func testTheWindowOpensToFitTheScreen() {
        // A big screen: the usual size.
        XCTAssertEqual(MainWindowSize.fitting(visible: NSRect(x: 0, y: 0, width: 2560, height: 1400)), MainWindowSize.usual)
        // No screen to go by.
        XCTAssertEqual(MainWindowSize.fitting(visible: nil), MainWindowSize.usual)
        // The runners', and a MacBook Air on its largest text.
        XCTAssertEqual(MainWindowSize.fitting(visible: NSRect(x: 0, y: 70, width: 1024, height: 668)),
                       NSSize(width: 1024, height: 668))
        // Under the minimum, the minimum: AppKit then keeps it on the screen.
        XCTAssertEqual(MainWindowSize.fitting(visible: NSRect(x: 0, y: 0, width: 800, height: 500)), MainWindowSize.minimum)
    }

    /// Why a short window can happen without anyone asking for it: AppKit
    /// won't keep a window taller than the screen it's on.
    func testAppKitCutsATallWindowToItsScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let tall = NSRect(x: 0, y: 0, width: 400, height: screen.frame.height * 3)
        XCTAssertLessThanOrEqual(window.constrainFrameRect(tall, to: screen).height, screen.frame.height)
    }

    // MARK: - Formats at their extremes

    func testDurationsAreReadableAtTheExtremes() {
        XCTAssertEqual(WindowFormat.hm(0), "0m")
        XCTAssertEqual(WindowFormat.hm(-5), "0m")
        XCTAssertEqual(WindowFormat.hm(59), "0m")
        XCTAssertEqual(WindowFormat.hm(3600), "1h")
        XCTAssertEqual(WindowFormat.hm(3660), "1h 01m")
        XCTAssertEqual(formatDuration(3660), "1h 1m")
        XCTAssertEqual(AppState.minutesRoundedUp(0), 0)
        XCTAssertEqual(AppState.minutesRoundedUp(0.1), 1)
        XCTAssertEqual(StatusLabel(minutes: 24, dimmed: false, kind: .sessionLeft).text, "24m", "the menu-bar label")
        XCTAssertEqual(StatusLabel(minutes: 125, dimmed: false, kind: .sessionElapsed).text, "2h 5m")
        XCTAssertEqual(StatusLabel(minutes: 0, dimmed: true, kind: .sessionLeft).text, "0m")
    }

    func testHeadlinesSurviveExtremeGoals() {
        // Far past the goal.
        let past = TodayHeadline.make(.init(focused: 100 * 3600, goal: 3600, isToday: true, nextLength: 50))
        XCTAssertTrue(past.lead.contains("100h"), past.lead)
        // A one-minute session against a long goal.
        let long = TodayHeadline.make(.init(focused: 0, goal: 12 * 3600, isToday: true, nextLength: 1))
        XCTAssertFalse(long.lead.isEmpty)
        XCTAssertTrue(long.rest.contains("720"), long.rest)
        // Nothing at all on a past day.
        let empty = TodayHeadline.make(.init(focused: 0, goal: 3600, isToday: false, nextLength: 50, hasActivity: false))
        XCTAssertEqual(empty.rest, "")
    }
}
