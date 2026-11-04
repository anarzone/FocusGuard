import Foundation
import SwiftUI

/// What the island is showing. The order is `IslandRules.rank`'s.
enum IslandKind: CaseIterable {
    case drift, limit, sessionFinished, pickUp, plannedSession, breakOver
    case autoStart, driftPrompt, morningPlan, wrapUp, reminder, trial
    case sample
}

/// The ring and its colour: orange when something needs the user back, violet otherwise.
enum IslandTone: Equatable {
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
struct IslandButton: Equatable, Identifiable {
    let title: String
    var command: NotificationCommand?

    var id: String { title }
}

/// The real time until something happens, shown as "0:58" with the ring emptying.
struct IslandCountdown: Equatable {
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

/// Everything one appearance of the island says. Site names only, never a
/// page's title: the screen may be visible to others.
struct IslandMoment: Equatable, Identifiable {
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
    /// Pick up's card: the card shows this instead of the lines above.
    var pickUp: PickUpCard?

    var id: String { key }

    func shownPillValue(at now: Date) -> String { countdown?.clock(at: now) ?? pillValue }
    func shownValue(at now: Date) -> String? { countdown?.clock(at: now) ?? value }
    func shownFill(at now: Date) -> Double { countdown?.fill(at: now) ?? fill }

    /// What VoiceOver reads when it appears.
    var announcement: String {
        if let pickUp { return "\(pickUp.title). \(pickUp.sub)" }
        return "\(title). \(body)"
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

    /// Close to the design's cubic-bezier(.3, 1.32, .5, 1) over 0.42 s.
    var change: Animation {
        switch self {
        case .spring:    return .spring(response: 0.42, dampingFraction: 0.66)
        case .crossFade: return .easeOut(duration: 0.18)
        }
    }

    var contentFade: AnyTransition {
        switch self {
        case .spring:
            return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.24).delay(0.08)),
                               removal: .opacity.animation(.easeOut(duration: 0.1)))
        case .crossFade:
            return .opacity.animation(.easeOut(duration: 0.18))
        }
    }
}
