import Foundation
import UserNotifications

/// The habits' notifications. `HabitsCoordinator` decides when; these
/// decide what they say and which buttons they have.
extension NotificationPresenter {
    /// "3 sessions today?" with "Plan them" and "Not today".
    func presentMorningPlan(_ plan: MorningPlan) {
        let request = Self.request(
            "morningPlan",
            title: plan.title,
            body: plan.body(),
            category: category(.morningPlan, [(.planThem, String(localized: "Plan them")), (.notToday, String(localized: "Not today"))]),
            info: [NotificationInfo.slots: plan.slots.map(\.timeIntervalSinceReferenceDate),
                   NotificationInfo.minutes: plan.sessionMinutes]
        )
        deliver(request, as: .general, moment: morningPlanMoment(plan))
    }

    /// A slot from the morning plan has come: "Time for your 14:00 session".
    func presentPlannedSession(at slot: Date, minutes: Int, plannedAt: Date? = nil) {
        let request = Self.request(
            "plannedSession",
            title: String(localized: "Time for your \(HabitFormat.time(slot)) session"),
            body: String(localized: "\(minutes) minutes, as you planned.", comment: "Plural on minutes: 1 minute, as you planned"),
            category: category(.plannedSession, [(.startSession, String(localized: "Start now", comment: "Button: start the planned session")),
                                                 (.skip, String(localized: "Skip this one"))]),
            info: [NotificationInfo.minutes: minutes, NotificationInfo.slot: slot.timeIntervalSinceReferenceDate]
        )
        deliver(request, as: .general, moment: plannedSessionMoment(at: slot, title: request.content.title, body: request.content.body, plannedAt: plannedAt))
    }

    /// "You've been in Xcode 5 minutes" with "Start 50 minutes" and "Not now".
    func presentAutoStartOffer(_ offer: AutoStartOffer, now: Date = .now) {
        let minutes = usualMinutes
        let request = Self.request(
            "autoStart",
            title: offer.title(now: now),
            body: offer.body(),
            category: category(.autoStart, [(.startSession, String(localized: "Start \(minutes) minutes", comment: "Plural on minutes: Start 1 minute")),
                                            (.notNow, String(localized: "Not now"))]),
            info: [NotificationInfo.since: offer.since.timeIntervalSinceReferenceDate,
                   NotificationInfo.minutes: minutes]
        )
        deliver(request, as: .general, moment: autoStartMoment(offer, usualMinutes: minutes, now: now))
    }

    /// The offer stopped being true (that work ended, or it was taken): the card goes.
    func withdrawAutoStartOffer() {
        island?.remove(key: "autoStart")
    }

    /// "Today: 3h 40m focused" with "See today"; with a tip for tomorrow,
    /// "Day done: goal met" with the tip's "Plan it for 15:00".
    func presentEveningWrapUp(_ wrapUp: EveningWrapUp) {
        let buttons: [(NotificationAction, String)] = wrapUp.tip.map { [(.planThem, $0.button)] } ?? [(.seeToday, String(localized: "See today"))]
        let request = Self.request(
            "dailySummary",
            title: wrapUp.title,
            body: wrapUp.body(),
            category: category(.wrapUp, buttons),
            info: wrapUp.tip.map { [NotificationInfo.slots: [$0.slot.timeIntervalSinceReferenceDate]] } ?? [:],
            level: .passive
        )
        deliver(request, as: .general, moment: wrapUpMoment(wrapUp))
    }
}
