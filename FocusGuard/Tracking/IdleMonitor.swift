import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Notices when nobody is at the Mac. The tracker used to only skip the lock
/// screen and screensaver, so a browser tab left in front overnight counted
/// as hours of activity.
enum IdleMonitor {
    /// No keyboard, mouse or trackpad input for this long means away.
    static let awayAfter: TimeInterval = 5 * 60

    /// Seconds since the last input event of any kind.
    static func secondsSinceInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// True while something is keeping the display awake — a video playing,
    /// a call, a presentation. Reading along with a video isn't "away".
    static func displayKeptAwake() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&unmanaged) == kIOReturnSuccess,
              let status = unmanaged?.takeRetainedValue() as? [String: Any] else { return false }
        let count = status[kIOPMAssertPreventUserIdleDisplaySleep as String] as? Int ?? 0
        return count > 0
    }

    /// The decision, kept pure so it can be tested.
    static func isAway(idleSeconds: TimeInterval, displayKeptAwake: Bool) -> Bool {
        idleSeconds >= awayAfter && !displayKeptAwake
    }
}
