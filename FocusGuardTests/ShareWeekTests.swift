import XCTest
import SwiftData
@testable import FocusGuard

@MainActor
final class ShareWeekTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    private func sampleWeek() -> FocusWeek {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let minutes = [250, 220, 275, 260, 185, 75, 30]
        let days = minutes.enumerated().map { index, m in
            FocusWeek.Day(date: calendar.date(byAdding: .day, value: index, to: start)!, focus: TimeInterval(m * 60),
                          isWeekend: index >= 5)
        }
        let focus = TimeInterval(minutes.reduce(0, +) * 60)
        return FocusWeek(interval: DateInterval(start: start, duration: 7 * 86_400), days: days, focus: focus,
                         drift: focus * 0.16 / 0.84, longestZone: 72 * 60, sessions: 23, goalMinutes: 240,
                         names: [.init(name: "Steady Sprint", count: 11)], places: ["Xcode"])
    }

    func testImagesAreExactlyTheirSizeInSRGB() throws {
        for size in ShareOptions.Size.allCases {
            for look in ShareOptions.Look.allCases {
                let image = try XCTUnwrap(ShareImageExporter(week: sampleWeek(), options: ShareOptions(size: size, look: look),
                                                             icon: nil).render())
                XCTAssertEqual(CGFloat(image.width), size.pixels.width)
                XCTAssertEqual(CGFloat(image.height), size.pixels.height)
                XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
                XCTAssertEqual(image.bitsPerComponent, 8)
            }
        }
    }

    func testNumbersAndWords() {
        let week = sampleWeek()
        XCTAssertEqual(week.focusPercent, 84)
        XCTAssertEqual(week.goalDays, 3)
        XCTAssertEqual(FocusWeek.duration(week.focus), "21h 35m")
        XCTAssertEqual(week.rangeLabel(calendar: calendar), "12–18 Oct")
        XCTAssertEqual(week.rangeLabel(wideMonth: true, calendar: calendar), "12–18 October")
    }

    func testAppsAndSitesAreOffByDefault() {
        XCTAssertFalse(ShareOptions().topPlaces)
        XCTAssertTrue(ShareOptions().timePerDay)
        XCTAssertTrue(ShareOptions().sessionNames)
    }

    func testOnlyAutomaticNamesAndFocusedPlacesAreCollected() throws {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!

        let named = Session(startedAt: day, label: "Tax return for Mum")
        named.endedAt = day.addingTimeInterval(1800)
        named.autoName = "Steady Run"
        let plain = Session(startedAt: day.addingTimeInterval(7200))
        plain.endedAt = day.addingTimeInterval(9000)
        plain.autoName = "Steady Run"
        context.insert(named)
        context.insert(plain)

        func event(_ app: String, url: String? = nil, _ c: Classification, minutes: Double, at offset: Double) {
            let e = ActivityEvent(startedAt: day.addingTimeInterval(offset), endedAt: day.addingTimeInterval(offset + minutes * 60),
                                  bundleIdentifier: app, appName: app, url: url)
            e.classification = c
            context.insert(e)
        }
        event("Xcode", .focus, minutes: 40, at: 0)
        event("Chrome", url: "https://www.github.com/x", .focus, minutes: 20, at: 3000)
        event("Chrome", url: "https://youtube.com", .distraction, minutes: 90, at: 5000)
        try context.save()

        let week = FocusWeek.build(weekOf: day, context: context, now: day.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertEqual(week.names, [.init(name: "Steady Run", count: 2)])
        XCTAssertEqual(week.places, ["Xcode", "github.com"])
        XCTAssertEqual(week.sessions, 2)
        XCTAssertEqual(week.days.count, 7)
    }
}
