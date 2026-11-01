import Foundation

/// How often the tracker looks at what's in front when nothing tells it
/// something changed. Events do most of the work: an app coming to the
/// front, a window or its title changing (Accessibility, where allowed),
/// the browser extension reporting a tab. The timer covers what events
/// can't, at the slowest pace that still gives the same numbers.
enum TrackingCadence: Equatable {
    /// Every second, as before: something is timed to the second (a
    /// session, a break, a daily limit on what's in front) or FocusGuard's
    /// menu or window is on screen, showing live numbers.
    case everySecond
    /// Every few seconds: what's in front can only be read by asking — a
    /// window title with no Accessibility to announce changes, a browser's
    /// address over AppleScript — or the user is away and the tracker
    /// waits for them to come back.
    case polling
    /// A safety tick: events cover what's in front. It catches a title
    /// change an app didn't announce and notices the user leaving.
    case resting
    /// The Mac or its screens are asleep, the screen is locked or another
    /// user has it: nothing to record. A slow tick in case a wake-up was missed.
    case suspended

    var interval: TimeInterval {
        switch self {
        case .everySecond: return 1
        case .polling:     return 3
        case .resting:     return 10
        case .suspended:   return 60
        }
    }

    /// How late the timer may fire, so macOS can batch it with other work.
    /// Kept small every second: daily limits count the gap between ticks.
    var tolerance: TimeInterval {
        switch self {
        case .everySecond: return 0.1
        case .polling:     return 0.5
        case .resting:     return 2
        case .suspended:   return 10
        }
    }

    static func choose(secondTicks: Bool, suspended: Bool, polling: Bool) -> TrackingCadence {
        if secondTicks { return .everySecond }
        if suspended { return .suspended }
        return polling ? .polling : .resting
    }

    /// Whether tracking has to look every second: a session (running or
    /// paused), a break, a daily limit on what's in front, or FocusGuard on
    /// screen. Everything else follows events and the slower ticks.
    static func needsSecondTicks(inSession: Bool, onBreak: Bool, limitInFront: Bool, onScreen: Bool) -> Bool {
        inSession || onBreak || limitInFront || onScreen
    }

    /// Whether what's in front has to be polled: a browser with no extension
    /// report (its address comes over AppleScript), a window title that can
    /// be read but whose changes nothing announces, or someone away.
    static func needsPolling(away: Bool, browserWithoutExtension: Bool,
                             titlesReadable: Bool, titleChangesAnnounced: Bool) -> Bool {
        away || browserWithoutExtension || (titlesReadable && !titleChangesAnnounced)
    }
}

extension AppState {
    /// See `TrackingCadence.needsSecondTicks`. Read under observation by the
    /// tracker, so it speeds up the moment a session or break starts, a
    /// limited site comes to the front or the menu opens.
    var needsSecondTicks: Bool {
        TrackingCadence.needsSecondTicks(
            inSession: sessionManager.currentSession != nil,
            onBreak: breakManager.isOnBreak,
            limitInFront: tracker.currentSnapshot.map { limits.status(for: $0) != nil } ?? false,
            onScreen: OnScreen.shared.any
        )
    }
}
