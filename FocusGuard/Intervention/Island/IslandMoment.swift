import Foundation
import SwiftUI

/// What the island is showing. The order is `IslandRules.rank`'s.
enum IslandKind: String, CaseIterable, Codable {
    case drift, wait, limit, sessionFinished, pickUp, plannedSession, breakOver
    case autoStart, driftPrompt, morningPlan, wrapUp, weekReady, reminder, trial
    case sample

    /// About this moment only: once seen, it never comes back, even when
    /// something else pushed it off the island or a quiet time held it.
    var isMomentary: Bool {
        switch self {
        case .wait, .autoStart, .driftPrompt: return true
        default: return false
        }
    }

    /// Suggestions about a drift or a stretch of work. After one shows,
    /// the others keep away for a while (`IslandRules.betweenSuggestions`).
    var isSuggestion: Bool {
        switch self {
        case .wait, .autoStart, .driftPrompt, .pickUp: return true
        default: return false
        }
    }

    /// Whether it still means something after a quit and relaunch. A nudge is
    /// about this moment's drift, Pick up has its own card and coordinator, and
    /// an offer counts from a stretch of work the relaunch ended.
    var survivesRelaunch: Bool {
        switch self {
        case .drift, .wait, .pickUp, .autoStart, .sample: return false
        default: return true
        }
    }
}

/// The ring and its colour: orange when something needs the user back, violet otherwise.
enum IslandTone: String, Equatable, Codable {
    case attention, calm

    var color: Color {
        switch self {
        case .attention: return Color(red: 0xF7 / 255, green: 0xA0 / 255, blue: 0x4D / 255)
        case .calm:      return Color(red: 0xA7 / 255, green: 0x9F / 255, blue: 0xFF / 255)
        }
    }
}

/// One button on the card. Its command goes through the same route as the
/// macOS notification's button; nil just closes the card ("Not today").
struct IslandButton: Equatable, Identifiable, Codable {
    let title: String
    var command: NotificationCommand?

    var id: String { title }
}

/// The real time until something happens, shown as "0:58" with the ring emptying.
struct IslandCountdown: Equatable, Codable {
    let ends: Date
    /// The ring's full length: the time left when it first showed.
    var total: TimeInterval

    func secondsLeft(at now: Date) -> Int {
        max(0, Int(ends.timeIntervalSince(now).rounded(.up)))
    }

    func clock(at now: Date) -> String {
        let seconds = secondsLeft(at: now)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func fill(at now: Date) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(secondsLeft(at: now)) / total)
    }
}

/// Minutes that keep counting while a card waits: "These 5 minutes will count."
struct IslandCounting: Equatable, Codable {
    let since: Date
    /// The app on the pill; nil across several apps.
    var name: String?

    func minutes(at now: Date) -> Int {
        max(1, Int(now.timeIntervalSince(since) / 60))
    }
}

/// Friday's little chart: the week's bars, on the card and across a quit.
struct IslandWeekChart: Equatable, Codable {
    struct Part: Equatable, Codable {
        /// Which project colour; nil is Other.
        let slot: Int?
        let seconds: TimeInterval
    }

    struct Day: Equatable, Codable {
        let label: String
        /// Bottom of the bar first.
        let parts: [Part]
        var total: TimeInterval { parts.reduce(0) { $0 + $1.seconds } }
    }

    let days: [Day]
}

/// Everything one appearance of the island says. Site names only, never a
/// page's title: the screen may be visible to others.
struct IslandMoment: Equatable, Identifiable, Codable {
    let kind: IslandKind
    /// Repeats of the same thing share a key and update in place.
    var key: String
    var pillName: String
    var pillValue: String = ""
    var kicker: String
    var title: String
    /// The number at the card's right: "88%", "25/30".
    var value: String?
    var body: String
    var tone: IslandTone = .calm
    /// How full the ring is, 0 to 1.
    var fill: Double = 0
    var buttons: [IslandButton] = []
    var countdown: IslandCountdown?
    /// Opens as a card by itself instead of starting as a pill.
    var startsOpen = false
    /// The user asked for it just now: it waits for nothing, and stays through a call.
    var requested = false
    /// Sooner than the rules' expiry, when the moment itself knows.
    var expiresAt: Date?
    /// What the kicker says instead, when it was held until a natural pause.
    var kickerAtPause: String?
    /// It was: set when it shows.
    var shownAtPause = false
    /// Minutes the lines keep up with while it waits.
    var counting: IslandCounting?
    /// How the menu's Recent list names it, when the title needs the card around it.
    var recentTitle: String?
    /// Friday's card: its chart, above the lines.
    var weekChart: IslandWeekChart?
    /// Pick up's card: the card shows this instead of the lines above.
    var pickUp: PickUpCard?

    /// Pick up's card stays out: it never outlives its coordinator (`IslandKind.survivesRelaunch`).
    private enum CodingKeys: String, CodingKey {
        case kind, key, pillName, pillValue, kicker, title, value, body, tone, fill, buttons
        case countdown, startsOpen, requested, expiresAt, kickerAtPause, shownAtPause, counting, recentTitle, weekChart
    }

    var id: String { key }

    var shownKicker: String { shownAtPause ? kickerAtPause ?? kicker : kicker }
    func shownPillValue(at now: Date) -> String { countdown?.clock(at: now) ?? pillValue }
    func shownValue(at now: Date) -> String? { countdown?.clock(at: now) ?? value }
    func shownFill(at now: Date) -> Double { countdown?.fill(at: now) ?? fill }

    /// "Xcode · 5 min" on an offer: up to date, however long it waited.
    func shownPillName(at now: Date) -> String {
        guard let counting else { return pillName }
        let minutes = String(localized: "\(counting.minutes(at: now)) min", comment: "Compact minutes")
        return "\(counting.name ?? pillName) · \(minutes)"
    }

    /// "These 5 minutes will count." on an offer.
    func shownBody(at now: Date) -> String {
        guard let counting else { return body }
        return String(localized: "These \(counting.minutes(at: now)) minutes will count.", comment: "Plural on minutes: This 1 minute will count. The session counts from when the work began")
    }

    /// What VoiceOver reads when it appears.
    func announcement(at now: Date) -> String {
        if let pickUp { return "\(pickUp.title). \(pickUp.sub)" }
        return "\(title). \(shownBody(at: now))"
    }
}

extension IslandMoment {
    /// Key of Pick up's moment: there's one card at a time.
    static let pickUpKey = "pickUp"

    /// Pick up's card on the island. A return starts as a pill like everything
    /// else; what the user asked for, or needs to know after pressing, opens.
    static func pickUp(_ card: PickUpCard) -> IslandMoment {
        let place = card.places.first
        let asked = card.kind == .menu || card.kind == .failed
        return IslandMoment(
            kind: .pickUp, key: pickUpKey,
            pillName: place.map { $0.host ?? $0.appName } ?? card.title,
            pillValue: card.primary == nil ? "" : String(localized: "Pick up", comment: "Button: go back to what you were doing"),
            kicker: card.top, title: card.title, body: card.sub,
            tone: card.kind == .failed ? .attention : .calm,
            startsOpen: asked, requested: asked, pickUp: card
        )
    }
}

/// How the island moves: a spring, or with Reduce Motion a cross-fade only.
enum IslandMotion: Equatable {
    case spring, crossFade

    static func choose(reduceMotion: Bool) -> IslandMotion { reduceMotion ? .crossFade : .spring }

    /// CSS's `ease`, which the design's fades use.
    private static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.25, 0.1, 0.25, 1, duration: duration)
    }

    /// The design's cubic-bezier(.3, 1.32, .5, 1) over 0.42 s.
    var change: Animation {
        switch self {
        case .spring:    return .timingCurve(0.3, 1.32, 0.5, 1, duration: 0.42)
        case .crossFade: return Self.ease(0.18)
        }
    }

    /// The whole island fading in and out.
    var fade: Animation { Self.ease(0.18) }

    var contentFade: AnyTransition {
        switch self {
        case .spring:
            return .asymmetric(insertion: .opacity.combined(with: .offset(y: 3)).animation(Self.ease(0.24).delay(0.08)),
                               removal: .opacity.animation(Self.ease(0.1)))
        case .crossFade:
            return .opacity.animation(Self.ease(0.18))
        }
    }
}
