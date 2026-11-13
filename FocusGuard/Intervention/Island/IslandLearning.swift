import Foundation

/// Learns from which cards get used. A kind the user lets go by 4 times in a
/// row shows at most once a day; after 8 it pauses for two weeks. Back from a
/// pause it's on probation: 2 more misses pause it for a month. Using it once
/// puts it back to normal. Only suggestions learn this way: cards the user
/// asked for, a drift they set to be caught, a limit, a tool's own word and
/// a finished session's result always show.
struct IslandLearning: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// In a row without being used.
        var streak = 0
        /// When it last showed, for once a day while resting.
        var lastShown: Date?
        var pausedUntil: Date?
        /// Back from a pause: two more misses pause it again, for longer.
        var onProbation = false
        /// How many times it's been paused, for the log and the longer pause.
        var pauses = 0
    }

    enum State: Equatable, Sendable {
        case on
        /// At most once a day.
        case resting(streak: Int)
        case paused(until: Date)
    }

    static let restAfter = 4
    static let pauseAfter = 8
    static let probationMisses = 2
    static let pauseDays = 14
    static let longPauseDays = 30

    /// The kinds that learn. The rest always show.
    static func learns(_ kind: IslandKind) -> Bool {
        switch kind {
        case .autoStart, .driftPrompt, .pickUp, .plannedSession, .morningPlan, .wrapUp, .weekReady: return true
        case .drift, .wait, .limit, .sessionFinished, .breakOver, .reminder, .trial, .sample: return false
        }
    }

    var entries: [String: Entry] = [:]

    func state(_ kind: IslandKind, now: Date) -> State {
        guard Self.learns(kind), let entry = entries[kind.rawValue] else { return .on }
        if let until = entry.pausedUntil, now < until { return .paused(until: until) }
        let rests = entry.onProbation ? entry.streak >= 1 : entry.streak >= Self.restAfter
        return rests ? .resting(streak: entry.streak) : .on
    }

    /// Whether a card of this kind may come now. Nil: yes; else why not.
    func holds(_ kind: IslandKind, now: Date, calendar: Calendar = .current) -> State? {
        switch state(kind, now: now) {
        case .on: return nil
        case .paused(let until): return .paused(until: until)
        case .resting(let streak):
            guard let last = entries[kind.rawValue]?.lastShown, calendar.isDate(last, inSameDayAs: now) else { return nil }
            return .resting(streak: streak)
        }
    }

    mutating func shown(_ kind: IslandKind, now: Date) {
        guard Self.learns(kind) else { return }
        var entry = entries[kind.rawValue] ?? Entry()
        // A pause that ran out: back, on probation.
        if let until = entry.pausedUntil, now >= until {
            entry.pausedUntil = nil
            entry.onProbation = true
            entry.streak = 0
        }
        entry.lastShown = now
        entries[kind.rawValue] = entry
    }

    /// It was used: back to normal. Nil when nothing changed.
    mutating func used(_ kind: IslandKind) {
        guard Self.learns(kind), entries[kind.rawValue] != nil else { return }
        entries[kind.rawValue] = nil
    }

    /// Closed, "Not now", or gone without an answer. Returns the new state
    /// when it changed: resting or paused.
    @discardableResult
    mutating func passed(_ kind: IslandKind, now: Date, calendar: Calendar = .current) -> State? {
        guard Self.learns(kind) else { return nil }
        let before = state(kind, now: now)
        var entry = entries[kind.rawValue] ?? Entry()
        entry.streak += 1
        let limit = entry.onProbation ? Self.probationMisses : Self.pauseAfter
        if entry.streak >= limit {
            let days = entry.onProbation ? Self.longPauseDays : Self.pauseDays
            entry.pausedUntil = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
            entry.pauses += 1
            entry.streak = 0
            entry.onProbation = true
        }
        entries[kind.rawValue] = entry
        let after = state(kind, now: now)
        switch (before, after) {
        case (.on, .resting), (.on, .paused), (.resting, .paused): return after
        default: return nil
        }
    }

    /// "Bring it back".
    mutating func bringBack(_ kind: IslandKind) {
        entries[kind.rawValue] = nil
    }

    /// The kinds held back now, resting or paused, in the card order.
    func heldBack(now: Date) -> [(kind: IslandKind, state: State)] {
        IslandKind.allCases.compactMap { kind in
            let state = state(kind, now: now)
            return state == .on ? nil : (kind, state)
        }
    }

    // MARK: What came before

    /// Learning began with build 211, but the log goes back further. Once,
    /// it learns from that too: the cards shown since each kind was last
    /// used count as let go by, so a kind never used doesn't get eight more
    /// chances first.
    mutating func catchUp(from log: [DecisionLog.Entry], now: Date, calendar: Calendar = .current) {
        for kind in IslandKind.allCases where Self.learns(kind) {
            let mine = log.filter { $0.kind == .island && $0.detail == kind.rawValue }.sorted { $0.at < $1.at }
            let lastUsed = mine.last { $0.outcome == "pressed" }?.at ?? .distantPast
            let shown = mine.filter { $0.outcome == "shown" && $0.at > lastUsed }
            var entry = entries[kind.rawValue] ?? Entry()
            guard shown.count > entry.streak else { continue }
            entry.streak = shown.count
            entry.lastShown = max(entry.lastShown ?? .distantPast, shown.last?.at ?? .distantPast)
            if entry.streak >= Self.pauseAfter, entry.pausedUntil == nil {
                entry.pausedUntil = calendar.date(byAdding: .day, value: Self.pauseDays, to: calendar.startOfDay(for: now))
                entry.pauses += 1
                entry.streak = 0
                entry.onProbation = true
            }
            entries[kind.rawValue] = entry
        }
    }

    static let caughtUpKey = "island.learning.caughtUp"

    // MARK: Kept on this Mac

    static let key = "island.learning"

    static func load(_ defaults: UserDefaults) -> IslandLearning {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(IslandLearning.self, from: $0) } ?? IslandLearning()
    }

    func save(_ defaults: UserDefaults) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
