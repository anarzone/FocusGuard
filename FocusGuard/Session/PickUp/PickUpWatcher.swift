import Foundation

/// How long things have to last, and how often the card may come up.
enum PickUpRules {
    static let shortestCall: TimeInterval = 5 * 60
    static let shortestAway: TimeInterval = 5 * 60
    static let shortestDrift: TimeInterval = 2 * 60
    /// A microphone that comes back this soon is the same call.
    static let callSettle: TimeInterval = 10
    /// Focused work needed just before the interruption, and how far back it's looked for.
    static let enoughFocus: TimeInterval = 2 * 60
    static let focusLookback: TimeInterval = 30 * 60
    /// How far back a card looks for places.
    static let placesLookback: TimeInterval = 2 * 3600
    /// The card closes by itself after this.
    static let cardLifetime: TimeInterval = 2 * 60
    /// One return can't bring a second card on the heels of the first.
    static let gapBetweenCards: TimeInterval = 5 * 60

    /// Whether anything rules a card out at this moment.
    static func isHeldBack(_ moment: PickUpMoment) -> Bool {
        moment.isAway || moment.inCall || moment.screenUp
    }

    /// Whether the user is already back in one of the places.
    static func isBack(_ moment: PickUpMoment, in places: [PickUpPlace]) -> Bool {
        guard !moment.frontIsSelf, let front = moment.front else { return false }
        return places.contains { $0.isShown(by: front) }
    }

    /// Whether a return the watcher found gets a card.
    static func allows(_ moment: PickUpMoment, places: [PickUpPlace], focused: TimeInterval,
                       cardShowing: Bool, lastCardAt: Date?) -> Bool {
        guard !cardShowing, !isHeldBack(moment), !places.isEmpty, focused >= enoughFocus else { return false }
        if let lastCardAt, moment.now.timeIntervalSince(lastCardAt) < gapBetweenCards { return false }
        return !isBack(moment, in: places)
    }
}

/// What the watcher goes by, read from the tracker, the call detector and
/// the screens at each of the tracker's looks.
struct PickUpMoment {
    var now: Date
    var front: ActivitySnapshot?
    var frontIsSelf = false
    /// Nobody's at the Mac, or it's asleep or locked.
    var isAway = false
    /// When the user was last at the Mac.
    var lastActiveAt: Date?
    var callSince: Date?
    /// The block, daily-limit or break screen is up, or a break is on.
    var screenUp = false
    /// The user said what's in front is for work, for this session.
    var frontAllowed = false

    var inCall: Bool { callSince != nil }
}

/// The user came back to something: found once per return.
struct PickUpReturn: Equatable {
    enum Kind: Equatable {
        case call, away
        /// What they drifted to: "x.com".
        case drift(name: String)
    }

    let kind: Kind
    /// When the interruption began; the places are from before this.
    let since: Date
    /// How long it lasted.
    let seconds: TimeInterval
}

/// Notices the three returns.
///
/// After a drift the card comes only when the user leaves the distracting
/// site for something that's neither work nor another distraction. Going
/// straight back to work needs no card, staying is the nudges' and the block
/// screen's business, and a block screen coming up ends the count: its "Back
/// to work" already does this job.
struct PickUpWatcher: Equatable {
    private var awaySince: Date?
    private var callSince: Date?
    private var callEndedAt: Date?
    private var driftSince: Date?
    private var driftName: String?

    mutating func observe(_ moment: PickUpMoment) -> PickUpReturn? {
        if moment.isAway {
            if awaySince == nil { awaySince = moment.lastActiveAt ?? moment.now }
            noteCall(moment)
            driftSince = nil
            return nil
        }
        var found: PickUpReturn?
        if let since = awaySince {
            awaySince = nil
            let seconds = moment.now.timeIntervalSince(since)
            if seconds >= PickUpRules.shortestAway { found = PickUpReturn(kind: .away, since: since, seconds: seconds) }
        }
        if let call = callReturn(moment) { found = call }
        if let drift = driftReturn(moment) { found = found ?? drift }
        return found
    }

    private mutating func noteCall(_ moment: PickUpMoment) {
        if let since = moment.callSince {
            if callSince == nil { callSince = since }
            callEndedAt = nil
        } else if callSince != nil, callEndedAt == nil {
            callEndedAt = moment.now
        }
    }

    private mutating func callReturn(_ moment: PickUpMoment) -> PickUpReturn? {
        noteCall(moment)
        guard let since = callSince, let ended = callEndedAt,
              moment.now.timeIntervalSince(ended) >= PickUpRules.callSettle else { return nil }
        callSince = nil
        callEndedAt = nil
        let seconds = ended.timeIntervalSince(since)
        return seconds >= PickUpRules.shortestCall ? PickUpReturn(kind: .call, since: since, seconds: seconds) : nil
    }

    private mutating func driftReturn(_ moment: PickUpMoment) -> PickUpReturn? {
        // A screen up or a call: not drift, and whatever came before is over.
        guard !moment.screenUp, !moment.inCall else {
            driftSince = nil
            return nil
        }
        // FocusGuard's own window in front says nothing about the drift.
        guard !moment.frontIsSelf, let front = moment.front else { return nil }
        if front.classification == .distraction, !front.isPrivateWindow, !moment.frontAllowed {
            if driftSince == nil { driftSince = front.observedAt }
            driftName = Self.name(of: front)
            return nil
        }
        guard let since = driftSince, let name = driftName else { return nil }
        driftSince = nil
        let seconds = moment.now.timeIntervalSince(since)
        guard seconds >= PickUpRules.shortestDrift, Self.isSomewhereElse(front) else { return nil }
        return PickUpReturn(kind: .drift(name: name), since: since, seconds: seconds)
    }

    /// Neither work nor a paused tab, a browser's own page or a call.
    private static func isSomewhereElse(_ front: ActivitySnapshot) -> Bool {
        guard front.classification == .neutral, !MeetingApps.bundleIds.contains(front.bundleIdentifier),
              !MeetingApps.isCallSite(front.url) else { return false }
        guard BrowserTabReader.isBrowser(bundleIdentifier: front.bundleIdentifier) else { return true }
        return front.url.flatMap { URL(string: $0)?.scheme }.map { $0 == "http" || $0 == "https" } ?? false
    }

    private static func name(of front: ActivitySnapshot) -> String {
        guard let host = front.url.flatMap({ URL(string: $0)?.host }) else { return front.appName }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
