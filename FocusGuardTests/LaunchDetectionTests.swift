import XCTest
import AppKit
@testable import FocusGuard

@MainActor
final class LaunchDetectionTests: XCTestCase {
    private func openApplicationEvent(loginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if loginItem {
            event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                           forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    func testLoginItemEventIsALoginLaunch() {
        XCTAssertTrue(AppDelegate.isLoginItemLaunch(openApplicationEvent(loginItem: true),
                                                    loginItemEnabled: true, systemUptime: 10_000))
    }

    func testFinderLaunchIsNotALoginLaunch() {
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(openApplicationEvent(loginItem: false),
                                                     loginItemEnabled: true, systemUptime: 10_000))
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(nil, loginItemEnabled: false, systemUptime: 10_000))
    }

    func testJustBootedWithLaunchAtLoginCountsAsLoginLaunch() {
        XCTAssertTrue(AppDelegate.isLoginItemLaunch(nil, loginItemEnabled: true, systemUptime: 60))
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(nil, loginItemEnabled: false, systemUptime: 60))
    }
}
