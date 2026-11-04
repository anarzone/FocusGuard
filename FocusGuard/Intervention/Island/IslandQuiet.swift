import AppKit
import AppIntents
import CoreGraphics
import Foundation

/// Notices screen sharing from the windows other apps put up while they share.
/// Best effort: macOS has no public way to ask, so this knows the signs of the
/// apps below and nothing else. Titles need Screen Recording; without it no
/// window has one, and this finds nothing.
enum ScreenShareDetector {
    struct WindowInfo: Equatable {
        let owner: String
        let title: String
        let height: CGFloat
    }

    /// What a sharing window looks like.
    struct Sign: Equatable {
        /// Part of the owning app's name; nil: any app.
        var owner: String?
        /// Part of the window's title.
        let title: String
        /// Tall windows don't count: a chat or a web page can be called anything.
        var onlySmall = true
    }

    /// A control bar is about this high at most. A real window hardly ever is.
    static let smallHeight: CGFloat = 200

    /// Every app it knows, in one place. Zoom's are in its app; the " is
    /// sharing " is in Chrome's, shown as "meet.google.com is sharing your
    /// screen." The hosts catch those bars when the browser isn't in English.
    static let signs: [Sign] = [
        Sign(owner: "zoom", title: "share toolbar", onlySmall: false),
        Sign(owner: "zoom", title: "share statusbar", onlySmall: false),
        Sign(owner: "teams", title: "sharing"),
        Sign(owner: "webex", title: "sharing"),
        Sign(title: " is sharing "),
        Sign(title: "meet.google.com"),
        Sign(title: "teams.microsoft.com"),
        Sign(title: "teams.live.com"),
        Sign(title: "webex.com"),
        Sign(title: "zoom.us"),
    ]

    static func isSharing(_ windows: [WindowInfo]) -> Bool {
        windows.contains { window in
            let owner = window.owner.lowercased(), title = window.title.lowercased()
            return signs.contains { sign in
                (sign.owner.map { owner.contains($0) } ?? true) && title.contains(sign.title)
                    && (!sign.onlySmall || window.height <= smallHeight)
            }
        }
    }

    /// What's on screen now, with titles when Screen Recording allows them.
    static func onScreenWindows() -> [WindowInfo] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windows.compactMap { window in
            guard let title = window[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            let bounds = (window[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            return WindowInfo(owner: window[kCGWindowOwnerName as String] as? String ?? "", title: title, height: bounds["Height"] ?? .infinity)
        }
    }
}

/// A Focus whose FocusGuard filter says "Keep cards quiet". The filter's
/// `perform` sets it on and off. A crash or a relaunch can miss the off, so a
/// hold is checked against the filter itself (`FocusGuardFocusFilter.current`)
/// and, if that can't say, ends on its own after a while.
struct FocusQuiet {
    var defaults: UserDefaults = .standard

    static let sinceKey = "focusFilter.keepCardsQuietSince"
    /// A hold nothing has confirmed for this long is over. A Focus still on
    /// has been confirmed long before: a card showing late is the lesser harm.
    static let longestUnconfirmed: TimeInterval = 12 * 60 * 60
    /// How often a hold is checked while cards are waiting on it.
    static let checkEvery: TimeInterval = 5 * 60

    /// What the Focus filter says right now.
    enum Reading: Equatable {
        case on, off
        /// The system didn't answer.
        case unknown
    }

    private var since: Date? { defaults.object(forKey: Self.sinceKey) as? Date }

    func set(_ on: Bool, now: Date) {
        if on {
            defaults.set(now, forKey: Self.sinceKey)
        } else {
            defaults.removeObject(forKey: Self.sinceKey)
        }
    }

    func isOn(now: Date) -> Bool {
        guard let since else { return false }
        // A clock that went backwards can't make it last forever either.
        let age = now.timeIntervalSince(since)
        guard age >= 0, age < Self.longestUnconfirmed else {
            set(false, now: now)
            return false
        }
        return true
    }

    /// Brings the hold in line with what the filter says. "Unknown" leaves
    /// it to run out by itself.
    func apply(_ reading: Reading, now: Date) {
        switch reading {
        case .on:      set(true, now: now)
        case .off:     set(false, now: now)
        case .unknown: break
        }
    }

    /// Asks the system for the filter in force. No filter in force is an answer too.
    @MainActor
    static func read() async -> Reading {
        do {
            return try await FocusGuardFocusFilter.current.keepCardsQuiet ? .on : .off
        } catch let error as SetFocusFilterIntentError where error == .notFound {
            return .off
        } catch {
            return .unknown
        }
    }
}
