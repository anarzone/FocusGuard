import AppKit
import Foundation
import SwiftData

/// The habits around the day: the morning plan, the evening wrap-up, the
/// offer to start a session after a few focused minutes, and holding nudges
/// during calls. Driven by the tracker's 1 s tick (`tick`); each habit has
/// a switch in `HabitSettings`.
@MainActor
@Observable
final class HabitsCoordinator {
    /// Sessions the user planned from this morning's notification, earliest first.
    private(set) var plannedSlots: [Date] = []
    /// Whether the user is in a call (with meeting awareness on).
    private(set) var inCall = false

    @ObservationIgnored private let sessions: SessionManager
    @ObservationIgnored private let breaks: BreakManager
    @ObservationIgnored private let tracker: ActivityTracker
    @ObservationIgnored private let presenter: NotificationPresenter
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var busyTimes = CalendarBusyTimes()
    @ObservationIgnored private var detector = AutoStartDetector()
    @ObservationIgnored private var calls = CallDetector()
    @ObservationIgnored private var callCheckedAt: Date = .distantPast
    @ObservationIgnored private var dayChecksAt: Date = .distantPast
    @ObservationIgnored private var lastOfferAt: Date = .distantPast
    @ObservationIgnored private var offersPausedUntil: Date = .distantPast

    /// At most one auto-start offer this often.
    nonisolated static let offerCooldown: TimeInterval = 30 * 60
    /// "Not now" on an offer: none for this long.
    nonisolated static let notNowPause: TimeInterval = 2 * 60 * 60
    /// The microphone is checked this often.
    nonisolated static let callCheckInterval: TimeInterval = 3

    private enum Key {
        static let morningPlanDay = "habits.morningPlan.lastDay"
        static let plannedSlots = "habits.morningPlan.slots"
    }

    init(sessions: SessionManager, breaks: BreakManager, tracker: ActivityTracker,
         presenter: NotificationPresenter, context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) {
        self.sessions = sessions
        self.breaks = breaks
        self.tracker = tracker
        self.presenter = presenter
        self.context = context
        self.defaults = defaults
        let saved = (defaults.array(forKey: Key.plannedSlots) as? [Double]) ?? []
        plannedSlots = saved.map(Date.init(timeIntervalSinceReferenceDate:)).filter { $0 > now }
    }

    func tick(now: Date = .now) {
        observeFocus(now: now, inCall: isInCall(now: now))
        offerPlannedSession(now: now)
        guard now.timeIntervalSince(dayChecksAt) >= 60 else { return }
        dayChecksAt = now
        sendMorningPlanIfDue(now: now)
        sendWrapUpIfDue(now: now)
    }

    // MARK: - Calls

    /// Whether a call is on. Checks the microphone at most every few
    /// seconds; always false with meeting awareness off.
    func isInCall(now: Date = .now) -> Bool {
        guard HabitSettings.isOn(HabitSettings.meetingAwareness, defaults) else {
            if inCall { inCall = false }
            return false
        }
        guard now.timeIntervalSince(callCheckedAt) >= Self.callCheckInterval else { return inCall }
        callCheckedAt = now
        let recording = MicrophoneActivity.recordingProcesses()
        let reading = CallDetector.Reading(
            recording: recording,
            microphoneInUse: recording.map { !$0.isEmpty } ?? MicrophoneActivity.isInUse(),
            runningApps: recording == nil
                ? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) : [],
            frontURL: tracker.isFrontmostSelf ? nil : tracker.currentSnapshot?.url
        )
        let next = calls.update(reading)
        if next != inCall { inCall = next }
        return next
    }

    // MARK: - Auto-start offer

    private func observeFocus(now: Date, inCall: Bool) {
        guard let snapshot = tracker.currentSnapshot else { return detector.reset() }
        let eligible = HabitSettings.isOn(HabitSettings.autoStartOffer, defaults)
            && sessions.currentSession == nil && !breaks.isOnBreak && !tracker.isAway && !inCall
        // FocusGuard's own windows show the last app's snapshot; they're a blip.
        let sample = AutoStartDetector.Sample(appName: snapshot.appName,
                                              classification: tracker.isFrontmostSelf ? .neutral : snapshot.classification,
                                              at: now, eligible: eligible)
        guard let offer = detector.observe(sample),
              Self.mayOffer(now: now, lastOfferAt: lastOfferAt, pausedUntil: offersPausedUntil) else { return }
        lastOfferAt = now
        presenter.presentAutoStartOffer(offer)
    }

    nonisolated static func mayOffer(now: Date, lastOfferAt: Date, pausedUntil: Date) -> Bool {
        now >= pausedUntil && now.timeIntervalSince(lastOfferAt) >= offerCooldown
    }

    /// "Not now": no offers for a while.
    func pauseOffers(now: Date = .now) {
        offersPausedUntil = now.addingTimeInterval(Self.notNowPause)
    }

    /// Where a session started from the offer begins: when that focus
    /// began, while it's still going; otherwise now (nil).
    func offerStart(since: Date) -> Date? {
        detector.isOngoing(since: since) ? since : nil
    }

    // MARK: - Morning plan

    /// "Plan them": each slot gets a notification when it comes.
    func plan(_ slots: [Date], now: Date = .now) {
        plannedSlots = slots.filter { $0 > now }.sorted()
        defaults.set(plannedSlots.map(\.timeIntervalSinceReferenceDate), forKey: Key.plannedSlots)
    }

    private func offerPlannedSession(now: Date) {
        guard let first = plannedSlots.first, first <= now else { return }
        let due = plannedSlots.filter { $0 <= now }
        plan(plannedSlots.filter { $0 > now }, now: now)
        guard let slot = due.last, now.timeIntervalSince(slot) < HabitSchedule.plannedSessionGrace,
              sessions.currentSession == nil, !breaks.isOnBreak else { return }
        presenter.presentPlannedSession(at: slot, minutes: presenter.usualMinutes)
    }

    private func sendMorningPlanIfDue(now: Date) {
        guard Self.morningPlanDue(now: now, lastSentDay: defaults.string(forKey: Key.morningPlanDay),
                                  enabled: HabitSettings.isOn(HabitSettings.morningPlan, defaults),
                                  available: !tracker.isAway && sessions.currentSession == nil && !breaks.isOnBreak,
                                  weekendsCount: defaults.bool(forKey: SettingsKeys.Goal.weekendsCount)) else { return }
        defaults.set(HabitFormat.dayKey(now), forKey: Key.morningPlanDay)
        let calendar = Calendar.current
        let focused = ReportBuilder(context: context).breakdown(from: calendar.startOfDay(for: now), to: now).focus
        let dayEnd = calendar.date(bySettingHour: HabitSchedule.dayEndHour, minute: 0, second: 0, of: now) ?? now
        guard let plan = MorningPlan.make(now: now, focusedMinutes: Int(focused / 60), goalMinutes: FocusGoal.dailyMinutes,
                                          sessionMinutes: presenter.usualMinutes,
                                          busy: busyTimes.busy(from: now, to: dayEnd)) else { return }
        presenter.presentMorningPlan(plan)
    }

    /// Once a day between 09:00 and noon, when the user is at the Mac and
    /// not in a session or on a break. Weekends only when they count
    /// toward the streak (Settings › Sessions).
    nonisolated static func morningPlanDue(now: Date, lastSentDay: String?, enabled: Bool, available: Bool,
                               weekendsCount: Bool, calendar: Calendar = .current) -> Bool {
        guard enabled, available, lastSentDay != HabitFormat.dayKey(now, calendar: calendar),
              HabitSchedule.morningHours.contains(calendar.component(.hour, from: now)) else { return false }
        return weekendsCount || !calendar.isDateInWeekend(now)
    }

    // MARK: - Evening wrap-up

    private func sendWrapUpIfDue(now: Date) {
        var latest = FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.endedAt, order: .reverse)])
        latest.fetchLimit = 1
        guard Self.wrapUpDue(now: now, lastSentDay: defaults.string(forKey: SettingsKeys.Goal.lastSummaryDayKey),
                             enabled: HabitSettings.isOn(HabitSettings.eveningWrapUp, defaults),
                             lastActivity: Persistence.fetch(context, latest).first?.endedAt) else { return }
        defaults.set(HabitFormat.dayKey(now), forKey: SettingsKeys.Goal.lastSummaryDayKey)
        guard let wrapUp = wrapUp(now: now) else { return }
        presenter.presentEveningWrapUp(wrapUp)
    }

    /// Once a day after 21:00, when nothing has been tracked for half an
    /// hour, so the day looks done.
    nonisolated static func wrapUpDue(now: Date, lastSentDay: String?, enabled: Bool, lastActivity: Date?,
                          calendar: Calendar = .current) -> Bool {
        guard enabled, calendar.component(.hour, from: now) >= HabitSchedule.wrapUpHour,
              lastSentDay != HabitFormat.dayKey(now, calendar: calendar) else { return false }
        let quiet = TimeInterval(HabitSchedule.wrapUpQuietMinutes * 60)
        return now.timeIntervalSince(lastActivity ?? .distantPast) >= quiet
    }

    /// Today's wrap-up; nil when nothing was focused today.
    func wrapUp(now: Date = .now) -> EveningWrapUp? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let focused = Int(ReportBuilder(context: context).breakdown(from: dayStart, to: now).focus / 60)
        guard focused > 0 else { return nil }
        let goal = FocusGoal.dailyMinutes
        let streak = focused >= goal ? StreakCalculator(context: context).currentStreak(now: now, calendar: calendar) + 1 : 0
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow.addingTimeInterval(86_400)
        let start = EveningWrapUp.bestStart(peakHour: InsightsBuilder(context: context).peakFocusHour(calendar: calendar),
                                            tomorrowBusy: busyTimes.busy(from: tomorrow, to: dayAfter),
                                            sessionMinutes: presenter.usualMinutes, now: now, calendar: calendar)
        return EveningWrapUp(focusedMinutes: focused, goalMinutes: goal, streak: streak,
                             best: bestStretch(since: dayStart), tomorrowStart: start)
    }

    /// The session since `dayStart` with the most focused time (a minute at least).
    private func bestStretch(since dayStart: Date) -> EveningWrapUp.Stretch? {
        let finished = Persistence.fetch(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= dayStart && $0.endedAt != nil }
        ))
        let scored = finished.map { session in
            (session, session.events.filter { $0.classification == .focus }.reduce(0) { $0 + $1.duration })
        }
        guard let (session, focus) = scored.max(by: { $0.1 < $1.1 }), focus >= 60,
              let end = session.endedAt else { return nil }
        return EveningWrapUp.Stretch(name: session.displayName, start: session.startedAt, end: end)
    }
}
