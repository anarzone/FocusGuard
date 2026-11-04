import Foundation

/// Settings for "Pick up where you left off" (Settings › Sessions).
enum PickUpSettings {
    static let afterCall = "pickUp.afterCall"
    static let afterAway = "pickUp.afterAway"
    static let afterDrift = "pickUp.afterDrift"
    static let shortcut = "pickUp.shortcut"
    /// How many apps Pick up brings back, 1 to 3.
    static let bringBack = "pickUp.bringBack"
    /// "Forget my last places": nothing from before this counts.
    static let forgetBefore = "pickUp.forgetBefore"

    /// Everything's on until it's switched off.
    static func isOn(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func bringBackCount(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: bringBack) as? Int ?? PickUpPlaces.most
        return min(max(stored, 1), PickUpPlaces.most)
    }

    static func forgottenBefore(_ defaults: UserDefaults = .standard) -> Date? {
        (defaults.object(forKey: forgetBefore) as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    static func forget(now: Date = .now, _ defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: forgetBefore)
    }
}

/// A tracked stretch of activity as plain values, read off the main thread
/// (`StatsStore.pickUpEvents`). Nothing is stored for this feature.
struct PickUpEvent: Equatable, Sendable {
    let bundleId: String
    let appName: String
    let title: String?
    let url: String?
    let startedAt: Date
    let endedAt: Date
    let classification: Classification?
    /// The goal of the session it belongs to.
    var sessionGoal: String?

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

/// Somewhere worth going back to: one app, with what was open in it.
struct PickUpPlace: Equatable, Identifiable, Sendable {
    let bundleId: String
    let appName: String
    /// Nil when the app's titles are opted out, or there was none.
    let title: String?
    /// A web page, for a browser.
    let url: String?
    /// When the user was last there.
    let at: Date
    var sessionGoal: String?

    var id: String { bundleId }

    var host: String? {
        guard let host = url.flatMap({ URL(string: $0)?.host }) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The window's own name: "AuthSession.swift" from "AuthSession.swift — FocusGuard".
    var shortTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != appName else { return nil }
        // A page's title is all its own; an app's usually ends in the project or app.
        guard url == nil else { return trimmed }
        for separator in [" — ", " – ", " - "] {
            if let range = trimmed.range(of: separator) { return String(trimmed[..<range.lowerBound]) }
        }
        return trimmed
    }

    /// The grey line beside the app: "AuthSession.swift". For a web page the
    /// site alone: "github.com". A page's title can change by the second and
    /// shouldn't be on a screen others may see.
    var what: String? { host ?? shortTitle }

    /// "Chrome", for "Back to Chrome": the maker's name adds nothing on a button.
    var shortAppName: String {
        for maker in ["Google ", "Microsoft ", "Mozilla "] where appName.hasPrefix(maker) {
            return String(appName.dropFirst(maker.count))
        }
        return appName
    }

    /// Whether what's in front is this place: the same app, and for a
    /// browser the same site.
    func isShown(by front: ActivitySnapshot) -> Bool {
        guard front.bundleIdentifier == bundleId else { return false }
        guard let host else { return true }
        return front.url.flatMap { URL(string: $0)?.host }.map { $0 == host || $0 == "www." + host } ?? false
    }
}

/// Works the places out from the activity already tracked.
enum PickUpPlaces {
    /// Three at most, on the card and in the menu.
    static let most = 3
    /// "Last places" go back this far.
    static let keptFor: TimeInterval = 7 * 24 * 3600
    /// Shorter than this is passing through, not being somewhere.
    static let shortestStay: TimeInterval = 15

    /// Newest first, one per app. Only focused work counts; calls and
    /// FocusGuard never do. Private windows are left out: a browser event
    /// with no address is one the extension couldn't see (or a browser's own
    /// page), and the tracker writes down no page or title for the ones it
    /// knows are private. Opted-out titles aren't shown, even from before
    /// the opt-out.
    static func choose(_ events: [PickUpEvent], optedOut: Set<String>, forgetBefore: Date?, now: Date,
                       limit: Int = most, selfBundleId: String = ActivityTracker.selfBundleId) -> [PickUpPlace] {
        var seen = Set<String>()
        var places: [PickUpPlace] = []
        for event in events.sorted(by: { $0.endedAt > $1.endedAt }) where places.count < limit {
            guard counts(event, forgetBefore: forgetBefore, now: now, selfBundleId: selfBundleId),
                  event.duration >= shortestStay, !seen.contains(event.bundleId) else { continue }
            seen.insert(event.bundleId)
            places.append(PickUpPlace(bundleId: event.bundleId, appName: event.appName,
                                      title: optedOut.contains(event.bundleId) ? nil : event.title,
                                      url: webAddress(event.url), at: event.endedAt, sessionGoal: event.sessionGoal))
        }
        return places
    }

    /// Focused seconds in the half hour before `moment`: enough of it makes
    /// the place worth going back to.
    static func focusedSeconds(before moment: Date, in events: [PickUpEvent], forgetBefore: Date?, now: Date,
                               selfBundleId: String = ActivityTracker.selfBundleId) -> TimeInterval {
        let from = moment.addingTimeInterval(-PickUpRules.focusLookback)
        return events.reduce(0) { total, event in
            guard counts(event, forgetBefore: forgetBefore, now: now, selfBundleId: selfBundleId) else { return total }
            return total + max(0, min(event.endedAt, moment).timeIntervalSince(max(event.startedAt, from)))
        }
    }

    /// A private window, or what may be one, came after the newest place.
    static func hadPrivateWindow(in events: [PickUpEvent], after place: PickUpPlace?) -> Bool {
        events.contains { event in
            guard isBrowserLike(event.bundleId), event.duration >= shortestStay,
                  event.endedAt > (place?.at ?? .distantPast) else { return false }
            return looksPrivate(event) || (BrowserTabReader.isBrowser(bundleIdentifier: event.bundleId) && event.url == nil)
        }
    }

    private static func counts(_ event: PickUpEvent, forgetBefore: Date?, now: Date, selfBundleId: String) -> Bool {
        guard event.classification == .focus, event.bundleId != selfBundleId,
              !MeetingApps.bundleIds.contains(event.bundleId), !MeetingApps.isCallSite(event.url),
              now.timeIntervalSince(event.endedAt) <= keptFor, !looksPrivate(event) else { return false }
        if let forgetBefore, event.startedAt < forgetBefore { return false }
        if BrowserTabReader.isBrowser(bundleIdentifier: event.bundleId), webAddress(event.url) == nil { return false }
        return true
    }

    /// http and https only: nothing else gets opened from a stored address.
    private static func webAddress(_ url: String?) -> String? {
        guard let url, let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Browsers name private windows in their titles, Firefox always and
    /// Chromium's sometimes. Covers events from before the tracker knew.
    private static func looksPrivate(_ event: PickUpEvent) -> Bool {
        guard isBrowserLike(event.bundleId), let title = event.title?.lowercased() else { return false }
        return ["incognito", "inprivate", "private browsing"].contains { title.contains($0) }
    }

    private static func isBrowserLike(_ bundleId: String) -> Bool {
        BrowserTabReader.isBrowser(bundleIdentifier: bundleId) || bundleId.hasPrefix("org.mozilla.")
    }
}
