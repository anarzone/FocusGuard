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
            category: category(.morningPlan, [(.planThem, "Plan them"), (.notToday, "Not today")]),
            info: [NotificationInfo.slots: plan.slots.map(\.timeIntervalSinceReferenceDate),
                   NotificationInfo.minutes: plan.sessionMinutes]
        )
        deliver(request, as: .general)
    }

    /// A slot from the morning plan has come: "Time for your 14:00 session".
    func presentPlannedSession(at slot: Date, minutes: Int) {
        let request = Self.request(
            "plannedSession",
            title: "Time for your \(HabitFormat.time(slot)) session",
            body: "\(Self.plural(minutes, "minute")), as you planned this morning.",
            category: category(.plannedSession, [(.startSession, "Start \(Self.plural(minutes, "minute"))"),
                                                 (.skip, "Skip this one")]),
            info: [NotificationInfo.minutes: minutes]
        )
        deliver(request, as: .general)
    }

    /// "You've been in Xcode 5 minutes" with "Start 50 minutes" and "Not now".
    func presentAutoStartOffer(_ offer: AutoStartOffer, now: Date = .now) {
        let minutes = usualMinutes
        let request = Self.request(
            "autoStart",
            title: offer.title(now: now),
            body: offer.body(),
            category: category(.autoStart, [(.startSession, "Start \(Self.plural(minutes, "minute"))"),
                                            (.notNow, "Not now")]),
            info: [NotificationInfo.since: offer.since.timeIntervalSinceReferenceDate,
                   NotificationInfo.minutes: minutes]
        )
        deliver(request, as: .general)
    }

    /// "Today: 3h 40m focused" with "See today".
    func presentEveningWrapUp(_ wrapUp: EveningWrapUp) {
        let request = Self.request(
            "dailySummary",
            title: wrapUp.title,
            body: wrapUp.body(),
            category: category(.wrapUp, [(.seeToday, "See today")]),
            level: .passive
        )
        deliver(request, as: .general)
    }
}
