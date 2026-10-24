import XCTest
@testable import FocusGuard

@MainActor
final class MenuStateTests: XCTestCase {
    func testPausedPageHostComesFromTheFragment() {
        let url = "file:///Applications/FocusGuard.app/Contents/Resources/paused.html#id=ab12&host=youtube.com&state=limit&minutes=30"
        XCTAssertEqual(AppState.pausedPageHost(url), "youtube.com")
        XCTAssertNil(AppState.pausedPageHost("https://youtube.com/#host=x.com"))
        XCTAssertNil(AppState.pausedPageHost("file:///tmp/other.html#host=x.com"))
        XCTAssertNil(AppState.pausedPageHost("file:///tmp/paused.html#id=ab12&state=paused"))
    }

    func testOfferNamesItsApps() {
        let now = Date.now
        func offer(_ names: [String]) -> AutoStartOffer {
            AutoStartOffer(since: now.addingTimeInterval(-(12 * 60 + 40)), appNames: names, bundleId: nil)
        }
        XCTAssertEqual(offer(["Xcode", "Terminal"]).appList, "Xcode and Terminal")
        XCTAssertEqual(offer(["Xcode", "Terminal", "Safari"]).appList, "Xcode, Terminal and Safari")
        XCTAssertEqual(offer(["Xcode"]).appList, "Xcode")
        XCTAssertEqual(offer([]).appList, "focus apps")
        XCTAssertEqual(offer(["Xcode"]).focusMinutes(now: now), 12)
    }
}
