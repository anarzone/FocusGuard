import SwiftUI

/// The words for cards held back because they kept going by unused.
enum HeldCardsCopy {
    static func name(_ kind: IslandKind) -> String {
        switch kind {
        case .autoStart:      return String(localized: "Offers to start a session", comment: "Settings, cards you let pass: a kind of card")
        case .driftPrompt:    return String(localized: "What are you working on?", comment: "Settings, cards you let pass: a kind of card")
        case .pickUp:         return String(localized: "Back to where you were", comment: "Settings, cards you let pass: a kind of card")
        case .plannedSession: return String(localized: "Planned sessions", comment: "Settings, cards you let pass: a kind of card")
        case .morningPlan:    return String(localized: "Morning plan", comment: "Settings, cards you let pass: a kind of card")
        case .wrapUp:         return String(localized: "Evening wrap-up", comment: "Settings, cards you let pass: a kind of card")
        case .weekReady:      return String(localized: "Friday wrap-up", comment: "Settings, cards you let pass: a kind of card")
        default:              return kind.rawValue
        }
    }

    static func note(_ state: IslandLearning.State, entry: IslandLearning.Entry?, calendar: Calendar = .current,
                     locale: Locale = .autoupdatingCurrent) -> String {
        switch state {
        case .on:
            return ""
        case .resting(let streak):
            if entry?.onProbation == true {
                return String(localized: "Once a day for now: it came back from a pause and you let it go by again.",
                              comment: "Settings, cards you let pass")
            }
            let left = IslandLearning.pauseAfter - streak
            let lead = String(localized: "Once a day for now. You let the last \(streak) go by.", comment: "Settings, cards you let pass: how many")
            return lead + " " + (left == 1
                ? String(localized: "One more pauses it for two weeks.", comment: "Settings, cards you let pass")
                : String(localized: "\(left) more pause it for two weeks.", comment: "Settings, cards you let pass: how many more"))
        case .paused(let until):
            var style = Date.FormatStyle(locale: locale).weekday(.abbreviated).day().month(.abbreviated)
            style.timeZone = calendar.timeZone
            let date = until.formatted(style)
            if (entry?.pauses ?? 0) > 1 {
                return String(localized: "Paused until \(date). It came back once and went by unused again.",
                              comment: "Settings, cards you let pass: a date")
            }
            return String(localized: "Paused until \(date). You let the last \(IslandLearning.pauseAfter) go by.",
                          comment: "Settings, cards you let pass: a date, then how many")
        }
    }
}

/// "Cards you let pass": the kinds held back, each with a way back.
struct SettingsHeldCardsSection: View {
    let load: () -> IslandLearning
    let bringBack: (IslandKind) -> Void
    var now: () -> Date = { .now }
    @State private var learning = IslandLearning()

    var body: some View {
        let held = learning.heldBack(now: now())
        SettingsSection(String(localized: "Cards you let pass", comment: "Settings section: card kinds held back")) {
            if held.isEmpty {
                Text(String(localized: "Every card is on. One you let go by 4 times in a row shows at most once a day; after 8, it pauses for two weeks and shows up here.",
                            comment: "Settings, cards you let pass, when none are"))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
            ForEach(Array(held.enumerated()), id: \.element.kind) { index, item in
                if index > 0 { SettingsDivider() }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HeldCardsCopy.name(item.kind)).font(.system(size: 13))
                        Text(HeldCardsCopy.note(item.state, entry: learning.entries[item.kind.rawValue]))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(String(localized: "Bring it back", comment: "Settings button: show a held-back card kind again")) {
                        bringBack(item.kind)
                        learning = load()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        SettingsNote(text: String(localized: "Using a card once brings it back to normal. Cards you ask for, a drift you set to be caught, a limit, and a tool saying it’s done are never held back.",
                                  comment: "Settings, under cards you let pass"))
            .onAppear { learning = load() }
    }
}
