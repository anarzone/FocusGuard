import Foundation

/// A change by the hour that the weekly coach put in place: a shorter
/// default length, or a stricter preset, while some hours last. There's no
/// setting for these elsewhere, so the coach keeps them here and the menu,
/// Shortcuts and the drift engine read them.
struct CoachRule: Codable, Equatable, Identifiable, Sendable {
    enum Change: Codable, Equatable, Sendable {
        case sessionMinutes(Int)
        case preset(DriftResponse)
    }

    var id = UUID()
    let hours: CoachHours
    let change: Change
    /// When it stops by itself: the end of the experiment's week. Nil once kept.
    var until: Date?

    func isInForce(at now: Date, calendar: Calendar = .current) -> Bool {
        (until.map { now < $0 } ?? true) && hours.contains(now, calendar: calendar)
    }
}

enum CoachRules {
    static let key = "coach.rules"

    static func all(_ defaults: UserDefaults = .standard) -> [CoachRule] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CoachRule].self, from: data)) ?? []
    }

    static func save(_ rules: [CoachRule], _ defaults: UserDefaults = .standard) {
        if rules.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: key)
        }
    }

    static func add(_ rule: CoachRule, _ defaults: UserDefaults = .standard) {
        save(all(defaults) + [rule], defaults)
    }

    static func remove(_ id: UUID, _ defaults: UserDefaults = .standard) {
        save(all(defaults).filter { $0.id != id }, defaults)
    }

    /// Makes a rule stay after its week.
    static func keep(_ id: UUID, _ defaults: UserDefaults = .standard) {
        save(all(defaults).map { rule in
            var rule = rule
            if rule.id == id { rule.until = nil }
            return rule
        }, defaults)
    }

    /// Drops rules whose week is over.
    static func pruneExpired(now: Date, _ defaults: UserDefaults = .standard) {
        let rules = all(defaults)
        let live = rules.filter { $0.until.map { now < $0 } ?? true }
        if live.count != rules.count { save(live, defaults) }
    }

    /// The default session length right now, if a coach rule sets one.
    static func sessionMinutes(at now: Date = .now, _ defaults: UserDefaults = .standard,
                               calendar: Calendar = .current) -> Int? {
        all(defaults).lazy.filter { $0.isInForce(at: now, calendar: calendar) }.compactMap { rule -> Int? in
            if case .sessionMinutes(let minutes) = rule.change { return minutes }
            return nil
        }.first
    }

    /// The preset a coach rule asks for right now, if any. The drift engine
    /// uses it only when it's stricter than the one in Settings.
    static func preset(at now: Date = .now, _ defaults: UserDefaults = .standard,
                       calendar: Calendar = .current) -> DriftResponse? {
        all(defaults).filter { $0.isInForce(at: now, calendar: calendar) }.compactMap { rule -> DriftResponse? in
            if case .preset(let preset) = rule.change { return preset }
            return nil
        }.max { $0.strictness < $1.strictness }
    }
}
