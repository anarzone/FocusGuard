import Foundation
import UserNotifications

/// How each notification looks on the island. The buttons from the code aren't
/// here: they come from the same category as the macOS notification's, so a
/// button means the same on both (`deliver`). The ones listed here only close
/// the card, or stand in for clicking a banner that has no buttons.
extension NotificationPresenter {
    /// The notification's own buttons, each with its command, for the card.
    func islandButtons(for request: UNNotificationRequest) -> [IslandButton] {
        let content = request.content
        return categoryActions(content.categoryIdentifier).map {
            IslandButton(title: $0.title, command: NotificationCommand(action: $0.identifier, category: content.categoryIdentifier, info: content.userInfo))
        }
    }

    /// Whether settings still let a card of this kind show, once it's waiting.
    func islandAllows(_ kind: IslandKind) -> Bool {
        switch kind {
        case .pickUp, .sample: return true
        case .drift:           return allows(.driftWarning) && IslandSettings.surface(defaults) == .cards
        default:               return allows(.general) && IslandSettings.surface(defaults) == .cards
        }
    }

    /// Settings' "Show a sample card": a real island whose buttons only close it.
    func presentSampleCard(now: Date = .now) {
        guard IslandSettings.surface(defaults) == .cards, let island else {
            presentTestNotification()
            return
        }
        let length = IslandRules.timing(.sample).expiry
        island.post(IslandMoment(
            kind: .sample, key: "sample", pillName: "x.com",
            kicker: String(localized: "A sample card"),
            title: String(localized: "Still on \("x.com")?"),
            body: String(localized: "A nudge looks like this. The buttons here only close it."),
            tone: .attention,
            buttons: [IslandButton(title: String(localized: "Back to work")),
                      IslandButton(title: String(localized: "It's for work"))],
            countdown: IslandCountdown(ends: now.addingTimeInterval(length), total: length),
            requested: true
        ))
    }

    func driftMoment(place: String, body: String, context: NudgeContext?, now: Date = .now) -> IslandMoment {
        let kicker: String
        switch (context?.sessionName, context?.minutesLeft) {
        case let (name?, minutes?): kicker = String(localized: "\(name) · \(minutes) min left", comment: "Session, then time left: Evening focus · 18 min left")
        case let (name?, nil):      kicker = name
        default:                    kicker = "FocusGuard"
        }
        // Only a real time: nothing counts down without a block coming.
        let countdown = context?.blockAt.flatMap { end -> IslandCountdown? in
            let left = end.timeIntervalSince(now)
            return left > 0 ? IslandCountdown(ends: end, total: left) : nil
        }
        let warning = context?.presetName.map { String(localized: "Your \($0) preset blocks it when this runs out.", comment: "The preset's name: Standard") }
        return IslandMoment(kind: .drift, key: "nudge", pillName: place,
                            pillValue: String(localized: "Drifting?"),
                            kicker: kicker, title: String(localized: "Still on \(place)?"),
                            body: countdown != nil ? (warning ?? body) : body,
                            tone: .attention, fill: 1, countdown: countdown, expiresAt: countdown?.ends)
    }

    func sessionFinishedMoment(name: String, minutes: Int, focusPercent: Int?, zoneMinutes: Int) -> IslandMoment {
        let percent = focusPercent.map { "\($0)%" }
        return IslandMoment(
            kind: .sessionFinished, key: "sessionComplete", pillName: name,
            pillValue: percent ?? String(localized: "\(minutes) min", comment: "Compact minutes"),
            kicker: String(localized: "Session complete · \(minutes) min"),
            title: name, value: percent,
            body: zoneMinutes > 0 ? String(localized: "\(zoneMinutes) min in the zone.") : String(localized: "A good moment for a break."),
            fill: focusPercent.map { Double($0) / 100 } ?? 1, startsOpen: true
        )
    }

    func breakOverMoment(minutes: Int) -> IslandMoment {
        IslandMoment(kind: .breakOver, key: "breakOver",
                     pillName: String(localized: "Break's over"), pillValue: String(localized: "Start?", comment: "On the small island: start a session?"),
                     kicker: String(localized: "Break's over"),
                     title: String(localized: "Ready for another \(minutes) minutes?", comment: "Plural on minutes: 1 minute / 2 minutes"),
                     body: String(localized: "Blocking comes back when you start."))
    }

    func driftPromptMoment(host: String) -> IslandMoment {
        IslandMoment(kind: .driftPrompt, key: "driftPrompt-\(host)", pillName: host, pillValue: String(localized: "Drifting?"),
                     kicker: String(localized: "A few visits in 10 minutes"),
                     title: String(localized: "Drifting to \(host)?"),
                     body: String(localized: "A short session might help."),
                     tone: .attention, fill: 0.6,
                     buttons: [IslandButton(title: String(localized: "Not now"))])
    }

    func limitMoment(name: String, minutesLeft: Int, used: Int, minutesToday: Int, title: String, body: String, now: Date = .now) -> IslandMoment {
        IslandMoment(kind: .limit, key: "limitWarning-\(name)", pillName: name,
                     pillValue: String(localized: "\(minutesLeft) min left", comment: "On the small island: 5 min left"),
                     kicker: String(localized: "Daily limit"), title: title, value: "\(used)/\(minutesToday)", body: body,
                     tone: .attention, fill: minutesToday > 0 ? Double(used) / Double(minutesToday) : 0,
                     // A banner without buttons opened Today when clicked.
                     buttons: [IslandButton(title: String(localized: "See today"), command: .openToday),
                               IslandButton(title: String(localized: "OK"))],
                     expiresAt: now.addingTimeInterval(TimeInterval(minutesLeft) * 60))
    }

    func morningPlanMoment(_ plan: MorningPlan) -> IslandMoment {
        IslandMoment(kind: .morningPlan, key: "morningPlan",
                     pillName: String(localized: "Your day"),
                     pillValue: String(localized: "\(plan.slots.count) free slots", comment: "Plural on the count: 1 free slot / 3 free slots"),
                     kicker: String(localized: "Morning plan"), title: plan.title, body: plan.body(),
                     fill: plan.goalMinutes > 0 ? min(1, Double(plan.focusedMinutes) / Double(plan.goalMinutes)) : 0)
    }

    func plannedSessionMoment(at slot: Date, title: String, body: String) -> IslandMoment {
        IslandMoment(kind: .plannedSession, key: "plannedSession",
                     pillName: String(localized: "\(HabitFormat.time(slot)) session", comment: "On the small island: 10:00 session"),
                     pillValue: String(localized: "Now", comment: "On the small island: it's time for the session"),
                     kicker: String(localized: "Your plan", comment: "Notification title: the if-then plan of an Analyzer experiment"),
                     title: title, body: body)
    }

    func autoStartMoment(_ offer: AutoStartOffer, usualMinutes: Int, now: Date = .now) -> IslandMoment {
        let app = offer.appNames.count == 1 ? offer.appNames.first : nil
        return IslandMoment(kind: .autoStart, key: "autoStart",
                            pillName: app ?? String(localized: "Focused", comment: "On the small island: focused outside a session"),
                            pillValue: String(localized: "Start?", comment: "On the small island: start a session?"),
                            kicker: String(localized: "Focused since \(HabitFormat.time(offer.since))"),
                            title: String(localized: "Make it a session?"),
                            body: String(localized: "It counts from when you began."),
                            fill: usualMinutes > 0 ? min(1, offer.focusSeconds(now: now) / 60 / Double(usualMinutes)) : 0)
    }

    func wrapUpMoment(_ wrapUp: EveningWrapUp) -> IslandMoment {
        IslandMoment(kind: .wrapUp, key: "dailySummary",
                     pillName: String(localized: "Today"), pillValue: FocusGoal.format(minutes: wrapUp.focusedMinutes),
                     kicker: String(localized: "Evening wrap-up"), title: wrapUp.title, body: wrapUp.body(),
                     fill: wrapUp.goalMinutes > 0 ? min(1, Double(wrapUp.focusedMinutes) / Double(wrapUp.goalMinutes)) : 0,
                     buttons: [IslandButton(title: String(localized: "Close"))])
    }

    func trialMoment(title: String, body: String) -> IslandMoment {
        IslandMoment(kind: .trial, key: "trialEndingSoon",
                     pillName: "Pro",
                     pillValue: String(localized: "\(Plan.trialReminderDays) days left", comment: "Plural on the days: 1 day left / 2 days left"),
                     kicker: "FocusGuard Pro", title: title, body: body,
                     fill: Double(Plan.trialReminderDays) / Double(Plan.trialDays),
                     buttons: [IslandButton(title: String(localized: "Later"))])
    }

    /// Anything without a look of its own, such as the Analyzer's reminders.
    func reminderMoment(for request: UNNotificationRequest) -> IslandMoment {
        IslandMoment(kind: .reminder, key: "reminder-\(request.content.title)", pillName: request.content.title,
                     kicker: "FocusGuard", title: request.content.title, body: request.content.body,
                     buttons: [IslandButton(title: String(localized: "OK"))])
    }
}
