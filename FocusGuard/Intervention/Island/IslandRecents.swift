import Foundation
import Observation

/// One island moment today, for the menu's Recent list.
struct IslandRecent: Equatable, Identifiable, Codable {
    let key: String
    var title: String
    /// When it showed, or stopped mattering if it never did.
    var at: Date
    /// Its main button, while that may still make sense.
    var button: IslandButton?
    /// When it stopped mattering by the rules.
    var expires: Date
    /// The user already answered it.
    var answered = false

    var id: String { key }
}

/// Today's island moments, those that timed out too, so nothing that came and
/// went is lost. Kept on this Mac only and gone the next day.
@MainActor
@Observable
final class IslandRecents {
    static let key = "island.recents"
    /// More than the menu shows, but not a log.
    static let keep = 12
    static let shownInMenu = 3

    private(set) var items: [IslandRecent] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([IslandRecent].self, from: data) {
            items = saved
        }
    }

    /// It showed. A repeat of the same thing replaces the earlier one. The
    /// sample and Pick up don't count: one is just a sample, and the menu has
    /// "Where you left off".
    func note(_ moment: IslandMoment, at now: Date, expires: Date? = nil) {
        guard moment.kind != .sample, moment.kind != .pickUp else { return }
        forgetOtherDays(now: now)
        items.removeAll { $0.key == moment.key }
        items.insert(IslandRecent(key: moment.key, title: moment.recentTitle ?? moment.title, at: now,
                                  button: moment.buttons.first,
                                  expires: expires ?? IslandRules.expiry(of: moment, arrived: now, calendar: calendar)),
                     at: 0)
        trimAndSave()
    }

    /// It waited until it stopped mattering, at `expired`. If that was another
    /// day it's not today's. One that had already shown keeps its row and time.
    func noteTimedOut(_ moment: IslandMoment, expired: Date, now: Date) {
        guard moment.kind != .sample, moment.kind != .pickUp, calendar.isDate(expired, inSameDayAs: now) else { return }
        forgetOtherDays(now: now)
        if let index = items.firstIndex(where: { $0.key == moment.key }) {
            items[index].expires = min(items[index].expires, expired)
            save()
            return
        }
        items.append(IslandRecent(key: moment.key, title: moment.recentTitle ?? moment.title, at: expired,
                                  button: moment.buttons.first, expires: expired))
        items.sort { $0.at > $1.at }
        trimAndSave()
    }

    private func trimAndSave() {
        items = Array(items.prefix(Self.keep))
        save()
    }

    /// A button was pressed or it was closed: nothing's left to offer.
    func noteAnswered(key: String) {
        guard let index = items.firstIndex(where: { $0.key == key }), !items[index].answered else { return }
        items[index].answered = true
        save()
    }

    /// Today's, newest first.
    func today(now: Date) -> [IslandRecent] {
        items.filter { calendar.isDate($0.at, inSameDayAs: now) }
    }

    /// A new day starts with an empty list.
    func forgetOtherDays(now: Date) {
        let kept = today(now: now)
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

    /// The button to offer, if answering it now still makes sense.
    /// - Parameter busy: a session or a break is running.
    static func button(for item: IslandRecent, now: Date, busy: Bool) -> IslandButton? {
        guard !item.answered, var button = item.button, let command = button.command else { return nil }
        switch command {
        case .openToday, .openPlans, .openAnalyzer:
            return button
        case .startSession, .takeBreak, .startFromOffer:
            return !busy && now < item.expires ? button : nil
        case .planSessions(let slots):
            // Past the morning, the afternoon's slots are still worth planning.
            let ahead = slots.filter { $0 > now }
            guard !ahead.isEmpty else { return nil }
            button.command = .planSessions(ahead)
            return button
        case .backToWork, .allowForSession, .snoozeAutoStart, .skipPlannedSession:
            return nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }
}
