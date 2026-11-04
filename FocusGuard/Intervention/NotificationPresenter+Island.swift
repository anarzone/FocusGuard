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
                            pillValue: Self.driftingPillValue,
                            kicker: kicker, title: String(localized: "Still on \(place)?"),
                            body: countdown != nil ? (warning ?? body) : body,
                            tone: .attention, fill: 1, countdown: countdown, expiresAt: countdown?.ends)
    }

    func sessionFinishedMoment(name: String, minutes: Int, focusPercent: Int?, zoneMinutes: Int, longestThisWeek: Bool = false) -> IslandMoment {
        let percent = focusPercent.map { "\($0)%" }
        let zone = longestThisWeek ? String(localized: "\(zoneMinutes) min in the zone. Your longest stretch this week.")
                                   : String(localized: "\(zoneMinutes) min in the zone.")
        return IslandMoment(
            kind: .sessionFinished, key: "sessionComplete", pillName: name,
            pillValue: percent ?? String(localized: "\(minutes) min", comment: "Compact minutes"),
            kicker: String(localized: "Session complete · \(minutes) min"),
            title: name, value: percent,
            body: zoneMinutes > 0 ? zone : String(localized: "A good moment for a break."),
            fill: focusPercent.map { Double($0) / 100 } ?? 1, startsOpen: true
        )
    }

    func breakOverMoment(minutes: Int, breakMinutes: Int? = nil) -> IslandMoment {
        IslandMoment(kind: .breakOver, key: "breakOver",
                     pillName: String(localized: "Break over"), pillValue: String(localized: "Start?", comment: "On the small island: start a session?"),
                     kicker: String(localized: "Break over"),
                     title: String(localized: "Ready for another \(minutes) minutes?", comment: "Plural on minutes: 1 minute / 2 minutes"),
                     body: breakMinutes.map { String(localized: "You took a \($0)-minute break.") }
                        ?? String(localized: "Blocking comes back when you start."))
    }

    /// Beside the site's name on the small island, so shorter than the banner's words.
    private static var driftingPillValue: String {
        String(localized: "island.drifting", defaultValue: "Drifting?", comment: "On the small island, beside the site's name. Keep it short: 75 points at most")
    }

    func driftPromptMoment(host: String) -> IslandMoment {
        IslandMoment(kind: .driftPrompt, key: "driftPrompt-\(host)", pillName: host, pillValue: Self.driftingPillValue,
                     kicker: String(localized: "A few visits this hour"),
                     title: String(localized: "Drifting to \(host)?"),
                     body: String(localized: "A short session might help."),
                     tone: .attention, fill: 0.6)
    }

    func limitMoment(name: String, minutesLeft: Int, used: Int, minutesToday: Int, recentTitle: String, now: Date = .now) -> IslandMoment {
        IslandMoment(kind: .limit, key: "limitWarning-\(name)", pillName: name,
                     pillValue: String(localized: "\(minutesLeft) min left", comment: "On the small island: 5 min left"),
                     kicker: String(localized: "Daily limit"),
                     title: String(localized: "\(minutesLeft) minutes left today", comment: "Plural on minutes: 1 minute left today"),
                     value: "\(used)/\(minutesToday)",
                     body: String(localized: "It blocks at \(minutesToday) minutes and resets at midnight.", comment: "Plural on minutes. It: the site or app with a daily limit"),
                     tone: .attention, fill: minutesToday > 0 ? Double(used) / Double(minutesToday) : 0,
                     expiresAt: now.addingTimeInterval(TimeInterval(minutesLeft) * 60), recentTitle: recentTitle)
    }

    func experimentDoneMoment(title: String, body: String) -> IslandMoment {
        IslandMoment(kind: .reminder, key: "experimentDone",
                     pillName: String(localized: "Experiment"), pillValue: String(localized: "Done", comment: "On the small island: the experiment is done"),
                     kicker: String(localized: "Focus Analyzer"), title: title, body: body, fill: 1)
    }

    func morningPlanMoment(_ plan: MorningPlan) -> IslandMoment {
        IslandMoment(kind: .morningPlan, key: "morningPlan",
                     pillName: String(localized: "Your day"),
                     // Free only when the calendar could say so.
                     pillValue: plan.fromCalendar ? String(localized: "\(plan.slots.count) free slots", comment: "Plural on the count: 1 free slot / 3 free slots")
                                                  : String(localized: "\(plan.slots.count) slots", comment: "Plural on the count: 1 slot / 3 slots"),
                     kicker: String(localized: "Morning plan"), title: String(localized: "Plan your day"), body: plan.shortBody(),
                     fill: plan.goalMinutes > 0 ? min(1, Double(plan.focusedMinutes) / Double(plan.goalMinutes)) : 0)
    }

    /// - Parameter plannedAt: when the slot was planned, if that's known.
    func plannedSessionMoment(at slot: Date, title: String, body: String, plannedAt: Date? = nil, calendar: Calendar = .current) -> IslandMoment {
        IslandMoment(kind: .plannedSession, key: "plannedSession",
                     pillName: String(localized: "\(HabitFormat.time(slot)) session", comment: "On the small island: 10:00 session"),
                     pillValue: String(localized: "Now", comment: "On the small island: it's time for the session"),
                     kicker: Self.plannedKicker(slot: slot, plannedAt: plannedAt, calendar: calendar),
                     title: title, body: body)
    }

    /// "Planned this morning" only when it was: the evening tip plans for the next day.
    static func plannedKicker(slot: Date, plannedAt: Date?, calendar: Calendar = .current) -> String {
        if let plannedAt, calendar.isDate(plannedAt, inSameDayAs: slot), calendar.component(.hour, from: plannedAt) < 12 {
            return String(localized: "Planned this morning")
        }
        return String(localized: "Your plan", comment: "Notification title: the if-then plan of an Analyzer experiment")
    }

    func autoStartMoment(_ offer: AutoStartOffer, usualMinutes: Int, now: Date = .now) -> IslandMoment {
        let app = offer.appNames.count == 1 ? offer.appNames.first : nil
        let counting = IslandCounting(since: offer.since, name: app)
        return IslandMoment(kind: .autoStart, key: "autoStart",
                            pillName: String(localized: "Focused", comment: "On the small island: focused outside a session"),
                            pillValue: String(localized: "Start?", comment: "On the small island: start a session?"),
                            kicker: String(localized: "Focused since \(HabitFormat.time(offer.since))"),
                            title: String(localized: "Make it a session?"),
                            body: "",
                            fill: usualMinutes > 0 ? min(1, offer.focusSeconds(now: now) / 60 / Double(usualMinutes)) : 0,
                            kickerAtPause: String(localized: "At a natural pause", comment: "Why the card shows now: it waited for a moment that interrupts less"),
                            counting: counting)
    }

    func wrapUpMoment(_ wrapUp: EveningWrapUp) -> IslandMoment {
        IslandMoment(kind: .wrapUp, key: "dailySummary",
                     pillName: String(localized: "Today"), pillValue: FocusGoal.format(minutes: wrapUp.focusedMinutes),
                     kicker: String(localized: "Evening wrap-up"),
                     title: String(localized: "\(FocusGoal.format(minutes: wrapUp.focusedMinutes)) focused today"), body: wrapUp.body(),
                     fill: wrapUp.goalMinutes > 0 ? min(1, Double(wrapUp.focusedMinutes) / Double(wrapUp.goalMinutes)) : 0,
                     buttons: [IslandButton(title: String(localized: "Close"))])
    }

    func weekReadyMoment(_ week: WeekReady) -> IslandMoment {
        IslandMoment(kind: .weekReady, key: "weekReady",
                     pillName: String(localized: "Your week"),
                     pillValue: String(localized: "Written", comment: "On the small island, beside Your week. Keep it short"),
                     kicker: String(localized: "Friday wrap-up"), title: String(localized: "Your week is written"),
                     body: week.body, fill: 1,
                     buttons: [IslandButton(title: String(localized: "Later"))],
                     startsOpen: true, weekChart: week.chart)
    }

    /// - Parameter daysLeft: real days left: it can wait a while before it shows.
    func trialMoment(daysLeft: Int) -> IslandMoment {
        IslandMoment(kind: .trial, key: "trialEndingSoon",
                     pillName: String(localized: "island.proTrial", defaultValue: "Pro trial", comment: "On the small island, beside \"2 days left\". Keep it short: 80 points at most"),
                     pillValue: String(localized: "\(daysLeft) days left", comment: "Plural on the days: 1 day left / 2 days left"),
                     kicker: "FocusGuard Pro",
                     title: String(localized: "Your trial ends in \(daysLeft) days", comment: "Plural on the days: ends in 1 day"),
                     body: String(localized: "Free keeps your data and the basics."),
                     fill: Double(daysLeft) / Double(Plan.trialDays),
                     buttons: [IslandButton(title: String(localized: "Later"))])
    }

    /// Anything without a look of its own, such as the Analyzer's reminders.
    func reminderMoment(for request: UNNotificationRequest) -> IslandMoment {
        IslandMoment(kind: .reminder, key: "reminder-\(request.content.title)", pillName: request.content.title,
                     kicker: "FocusGuard", title: request.content.title, body: request.content.body,
                     buttons: [IslandButton(title: String(localized: "OK"))])
    }
}
