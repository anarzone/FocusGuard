import Foundation

/// What's going on at a look, read fresh each second while the island has work.
struct IslandConditions {
    var now: Date
    /// The app in front. A change is a natural pause.
    var frontApp: String?
    var idleSeconds: TimeInterval = 0
    /// Respects "Stay quiet during calls".
    var inCall = false
    /// Respects "Stay quiet while sharing your screen" (`ScreenShareDetector`).
    var isSharingScreen = false
    /// A Focus whose FocusGuard filter says "Keep cards quiet" is on (`FocusQuiet`).
    var isFocusQuiet = false
    /// The block, daily-limit or break screen is up, or a break is on.
    var screenUp = false
    var isAsleepOrLocked = false
    var isAway = false
    /// The drift a nudge is about is still going.
    var isDrifting = true
}

/// When each moment may show. Only the drift nudge and the limit warning
/// interrupt; the rest wait for a natural pause, which costs far less
/// (Iqbal & Bailey), up to a maximum wait, and go away once they're stale.
enum IslandRules {
    struct Timing: Equatable {
        /// Shows without waiting for a pause.
        var atOnce = false
        /// The longest it waits for a pause. A quiet hold can make it longer.
        var maxWait: TimeInterval = 0
        /// From when it arrived. After this it never shows.
        var expiry: TimeInterval
        /// How long it stays up. Nil: until it's stale or closed.
        var onScreen: TimeInterval?
    }

    /// This much with no input counts as a pause.
    static let idleForPause: TimeInterval = 5
    /// A pause still counts this long after it happened, for what's waiting on the gap below.
    static let pauseLasts: TimeInterval = 3
    /// Breathing room between one closing and a waiting one showing.
    static let gapBetween: TimeInterval = 2
    /// Time on screen left after the pointer leaves, at least.
    static let afterHover: TimeInterval = 5
    /// Time on screen after opening it by a click or VoiceOver.
    static let afterOpening: TimeInterval = 60
    /// How long Friday's card stays as a pill after folding away.
    static let tuckedFor: TimeInterval = 30 * 60
    private static let minute: TimeInterval = 60

    static func timing(_ kind: IslandKind) -> Timing {
        switch kind {
        case .drift:           return Timing(atOnce: true, expiry: 2 * minute, onScreen: nil)  // or the block's time
        case .limit:           return Timing(atOnce: true, expiry: 5 * minute, onScreen: 20)
        case .sessionFinished: return Timing(maxWait: 30, expiry: 30 * minute, onScreen: 30)
        case .pickUp:          return Timing(atOnce: true, expiry: 60 * minute, onScreen: nil) // `PickUpRules` closes it
        case .plannedSession:  return Timing(maxWait: 2 * minute, expiry: 15 * minute, onScreen: 30)
        case .breakOver:       return Timing(maxWait: 1 * minute, expiry: 15 * minute, onScreen: 30)
        case .autoStart:       return Timing(maxWait: 5 * minute, expiry: 15 * minute, onScreen: 20)
        case .driftPrompt:     return Timing(maxWait: 2 * minute, expiry: 10 * minute, onScreen: 20)
        case .morningPlan:     return Timing(maxWait: 30 * minute, expiry: 4 * 60 * minute, onScreen: 30) // and midday
        case .wrapUp:          return Timing(maxWait: 30 * minute, expiry: 3 * 60 * minute, onScreen: 30)
        case .weekReady:       return Timing(maxWait: 30 * minute, expiry: 8 * 60 * minute, onScreen: 12)
        case .reminder:        return Timing(maxWait: 15 * minute, expiry: 2 * 60 * minute, onScreen: 30)
        case .trial:           return Timing(maxWait: 30 * minute, expiry: 24 * 60 * minute, onScreen: 30)
        case .sample:          return Timing(atOnce: true, expiry: minute, onScreen: minute)
        }
    }

    /// Lower goes first: drift, limit, a finished session, then the rest.
    static func rank(_ kind: IslandKind) -> Int {
        // The sample was just asked for, so nothing's more wanted.
        if kind == .sample { return -1 }
        return IslandKind.allCases.firstIndex(of: kind) ?? .max
    }

    /// When it stops mattering. The morning plan goes at midday, the wrap-up at midnight.
    static func expiry(of moment: IslandMoment, arrived: Date, calendar: Calendar = .current) -> Date {
        var end = arrived.addingTimeInterval(timing(moment.kind).expiry)
        if moment.kind == .morningPlan, let midday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: arrived) {
            end = min(end, midday)
        }
        if moment.kind == .wrapUp, let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: arrived)) {
            end = min(end, midnight)
        }
        return moment.expiresAt.map { min(end, $0) } ?? end
    }

    /// Whether a quiet time keeps this from showing. Nothing shows over a
    /// block screen or on a locked Mac, and what the user asked for doesn't
    /// wait for the end of a call.
    static func holds(_ moment: IslandMoment, _ conditions: IslandConditions) -> Bool {
        if conditions.isAsleepOrLocked || conditions.screenUp { return true }
        if moment.requested { return false }
        return conditions.inCall || conditions.isAway || conditions.isSharingScreen || conditions.isFocusQuiet
    }

    static func isQuiet(_ conditions: IslandConditions) -> Bool {
        conditions.isAsleepOrLocked || conditions.screenUp || conditions.inCall || conditions.isAway
            || conditions.isSharingScreen || conditions.isFocusQuiet
    }

    /// Waits at most `maxWait`, and at most half of what's left: one arriving
    /// just before its expiry still gets shown.
    static func hasWaitedLongEnough(_ moment: IslandMoment, arrived: Date, expires: Date, now: Date) -> Bool {
        let wait = min(timing(moment.kind).maxWait, expires.timeIntervalSince(arrived) / 2)
        return now.timeIntervalSince(arrived) >= wait
    }
}

/// What's on the island and what's waiting, moved along by `step`. Time comes
/// in from outside, so the tests use a fake clock.
struct IslandQueue {
    struct Entry: Equatable {
        var moment: IslandMoment
        let arrived: Date
        var expires: Date
        var shownUntil: Date?
        var hoveredSince: Date?
        /// Opened by a click or VoiceOver, so it stays open until the pointer leaves.
        var openedByHand = false

        var isOpen: Bool { moment.startsOpen || hoveredSince != nil || openedByHand }
    }

    enum Change: Equatable {
        case none
        case showed(IslandMoment)
        case hid
    }

    /// What's kept across a quit: everything here, on screen or not, comes back waiting.
    struct Saved: Equatable, Codable {
        let moment: IslandMoment
        let arrived: Date
        let expires: Date
    }

    private(set) var current: Entry?
    private(set) var waiting: [Entry] = []
    /// Waited until it no longer mattered, since the last `takeTimedOut`.
    private var timedOut: [Saved] = []
    private var lastFront: String?
    private var lastPauseAt: Date?
    private var wasQuiet = false
    private var closedAt: Date?
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    var isEmpty: Bool { current == nil && waiting.isEmpty }
    var isOpen: Bool { current?.isOpen ?? false }

    // MARK: - Arriving and leaving

    /// Adds it, or updates the one already here for the same thing. True when
    /// that one is on screen.
    @discardableResult
    mutating func post(_ moment: IslandMoment, now: Date) -> Bool {
        if var entry = current, entry.moment.key == moment.key {
            entry.moment = Self.merged(moment, over: entry.moment)
            entry.expires = IslandRules.expiry(of: entry.moment, arrived: now, calendar: calendar)
            entry.shownUntil = IslandRules.timing(moment.kind).onScreen.map { now.addingTimeInterval($0) }
            current = entry
            return true
        }
        if let index = waiting.firstIndex(where: { $0.moment.key == moment.key }) {
            // It keeps its place: repeating doesn't make it wait any longer.
            waiting[index].moment = Self.merged(moment, over: waiting[index].moment)
            waiting[index].expires = IslandRules.expiry(of: waiting[index].moment, arrived: waiting[index].arrived, calendar: calendar)
            return false
        }
        if isEmpty { lastFront = nil }
        waiting.append(Entry(moment: moment, arrived: now,
                             expires: IslandRules.expiry(of: moment, arrived: now, calendar: calendar)))
        return false
    }

    /// A repeat of a countdown keeps the ring's length, or it'd jump back to full.
    private static func merged(_ new: IslandMoment, over old: IslandMoment) -> IslandMoment {
        var merged = new
        if let total = old.countdown?.total, old.countdown?.ends == new.countdown?.ends { merged.countdown?.total = total }
        return merged
    }

    /// True when it was on screen.
    @discardableResult
    mutating func remove(key: String, now: Date) -> Bool {
        waiting.removeAll { $0.moment.key == key }
        guard current?.moment.key == key else { return false }
        current = nil
        closedAt = now
        return true
    }

    // MARK: - Across a quit

    var saved: [Saved] {
        ([current].compactMap { $0 } + waiting)
            .filter { $0.moment.kind.survivesRelaunch }
            .map { Saved(moment: $0.moment, arrived: $0.arrived, expires: $0.expires) }
    }

    /// Brings back what was here at the last quit. It keeps its arrival and
    /// expiry: time passed while the app wasn't running still counts.
    mutating func restore(_ saved: [Saved], now: Date) {
        for item in saved where !waiting.contains(where: { $0.moment.key == item.moment.key }) {
            var moment = item.moment
            moment.shownAtPause = false
            if now >= item.expires {
                timedOut.append(item)
            } else {
                waiting.append(Entry(moment: moment, arrived: item.arrived, expires: item.expires))
            }
        }
    }

    mutating func takeTimedOut() -> [Saved] {
        defer { timedOut = [] }
        return timedOut
    }

    /// A session or break ended.
    mutating func notePause(now: Date) {
        if !waiting.isEmpty { lastPauseAt = now }
    }

    // MARK: - Hover

    /// The pointer came in or went out. Time on screen stands still in between.
    mutating func setHover(_ inside: Bool, now: Date) {
        guard var entry = current else { return }
        if inside {
            if entry.hoveredSince == nil { entry.hoveredSince = now }
        } else {
            if let since = entry.hoveredSince, let until = entry.shownUntil {
                entry.shownUntil = max(until.addingTimeInterval(now.timeIntervalSince(since)),
                                       now.addingTimeInterval(IslandRules.afterHover))
            }
            entry.hoveredSince = nil
            entry.openedByHand = false
        }
        current = entry
    }

    /// A click on the pill, or VoiceOver's action.
    mutating func openByHand(now: Date) {
        guard var entry = current else { return }
        entry.openedByHand = true
        if let until = entry.shownUntil { entry.shownUntil = max(until, now.addingTimeInterval(IslandRules.afterOpening)) }
        current = entry
    }

    /// "Later" on Friday's card: back to a pill for a while. Hovering or a
    /// click opens it again.
    mutating func tuck(now: Date) {
        guard var entry = current else { return }
        entry.moment.startsOpen = false
        entry.hoveredSince = nil
        entry.openedByHand = false
        entry.shownUntil = now.addingTimeInterval(IslandRules.tuckedFor)
        current = entry
    }

    // MARK: - Moving along

    /// Drops what's stale, holds what must wait, and picks what shows.
    mutating func step(_ conditions: IslandConditions, allowed: (IslandKind) -> Bool = { _ in true }) -> Change {
        let now = conditions.now
        let before = current?.moment.key
        notePauseSignals(conditions)

        func isStale(_ entry: Entry) -> Bool {
            now >= entry.expires || !allowed(entry.moment.kind)
                || (entry.moment.kind == .drift && !conditions.isDrifting)
        }
        timedOut += waiting.filter { now >= $0.expires }.map { Saved(moment: $0.moment, arrived: $0.arrived, expires: $0.expires) }
        waiting.removeAll(where: isStale)
        // Friday's card folds to its pill rather than going, so it can still be read.
        if let entry = current, !isStale(entry), isDone(entry, now: now), entry.moment.kind == .weekReady, entry.moment.startsOpen {
            tuck(now: now)
        }
        if let entry = current, isStale(entry) || isDone(entry, now: now) {
            current = nil
            closedAt = now
        }
        if let entry = current, IslandRules.holds(entry.moment, conditions) {
            waitAgain(entry)
            current = nil
        }

        if let next = nextReady(conditions) {
            if let entry = current {
                if IslandRules.rank(next.moment.kind) < IslandRules.rank(entry.moment.kind) {
                    waitAgain(entry)
                    show(next, now: now)
                }
            } else if IslandRules.timing(next.moment.kind).atOnce || next.moment.requested || !isInGap(now: now) {
                show(next, now: now)
            }
        }

        if let moment = current?.moment, moment.key != before { return .showed(moment) }
        return current == nil && before != nil ? .hid : .none
    }

    private func isDone(_ entry: Entry, now: Date) -> Bool {
        guard entry.hoveredSince == nil, let until = entry.shownUntil else { return false }
        return now >= until
    }

    private func isInGap(now: Date) -> Bool {
        closedAt.map { now.timeIntervalSince($0) < IslandRules.gapBetween } ?? false
    }

    private mutating func waitAgain(_ entry: Entry) {
        var entry = entry
        entry.shownUntil = nil
        entry.hoveredSince = nil
        entry.openedByHand = false
        waiting.append(entry)
    }

    private mutating func show(_ entry: Entry, now: Date) {
        var entry = entry
        waiting.removeAll { $0.moment.key == entry.moment.key }
        // It really was held: one that came during a pause only happened to.
        entry.moment.shownAtPause = isPause(now: now) && now > entry.arrived
        entry.shownUntil = IslandRules.timing(entry.moment.kind).onScreen.map { now.addingTimeInterval($0) }
        current = entry
    }

    /// An app switch, a few seconds with no input, or the end of a quiet time.
    private mutating func notePauseSignals(_ conditions: IslandConditions) {
        let now = conditions.now
        if let front = conditions.frontApp {
            if let lastFront, lastFront != front { lastPauseAt = now }
            lastFront = front
        }
        if conditions.idleSeconds >= IslandRules.idleForPause { lastPauseAt = now }
        let quiet = IslandRules.isQuiet(conditions)
        if wasQuiet, !quiet { lastPauseAt = now }
        wasQuiet = quiet
    }

    private func isPause(now: Date) -> Bool {
        lastPauseAt.map { now.timeIntervalSince($0) <= IslandRules.pauseLasts } ?? false
    }

    private func nextReady(_ conditions: IslandConditions) -> Entry? {
        let now = conditions.now
        let pause = isPause(now: now)
        return waiting
            .filter { entry in
                guard !IslandRules.holds(entry.moment, conditions) else { return false }
                return entry.moment.requested || IslandRules.timing(entry.moment.kind).atOnce || pause
                    || IslandRules.hasWaitedLongEnough(entry.moment, arrived: entry.arrived, expires: entry.expires, now: now)
            }
            .min { first, second in
                let ranks = (IslandRules.rank(first.moment.kind), IslandRules.rank(second.moment.kind))
                return ranks.0 == ranks.1 ? first.arrived < second.arrived : ranks.0 < ranks.1
            }
    }
}
