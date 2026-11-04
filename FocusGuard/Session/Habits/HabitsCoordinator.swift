import AppKit
import Foundation
import SwiftData

/// The habits around the day: the morning plan, the evening wrap-up, the
/// offer to start a session after a few focused minutes, and holding nudges
/// during calls. Driven by the tracker's tick (`tick`): every second in a
/// session or on a break, every few seconds otherwise (`TrackingCadence`).
/// Each habit has a switch in `HabitSettings`.
/// The call in progress, for the menu.
struct CallInfo: Equatable {
    /// "Zoom", "FaceTime", "Google Meet".
    let appName: String
    /// Nil for a call in the browser.
    let bundleId: String?
    let since: Date
}

@MainActor
@Observable
final class HabitsCoordinator {
    /// Sessions the user planned from this morning's notification, earliest first.
    private(set) var plannedSlots: [Date] = []
    /// The offer to start a session from work already under way, from the
    /// moment it's made until a session starts, that work ends, or it's
    /// dismissed. The menu shows it beside the notification.
    private(set) var autoStartOffer: AutoStartOffer?
    /// The call in progress; nil with meeting awareness off.
    private(set) var currentCall: CallInfo?
    /// "Pause till it ends": the session resumes when the call does.
    private(set) var resumesAfterCall = false

    var inCall: Bool { currentCall != nil }

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
    /// Who's recording, given the page in front. Tests pass their own.
    @ObservationIgnored var readMicrophone: (String?) -> CallDetector.Reading = { frontURL in
        let recording = MicrophoneActivity.recordingProcesses()
        return CallDetector.Reading(
            recording: recording,
            microphoneInUse: recording.map { !$0.isEmpty } ?? MicrophoneActivity.isInUse(),
            runningApps: recording == nil
                ? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) : [],
            frontURL: frontURL
        )
    }

    /// At most one auto-start offer this often.
    nonisolated static let offerCooldown: TimeInterval = 30 * 60
    /// "Not now" on an offer: none for this long.
    nonisolated static let notNowPause: TimeInterval = 2 * 60 * 60
    /// The microphone is checked this often.
    nonisolated static let callCheckInterval: TimeInterval = 3

    private enum Key {
        static let morningPlanDay = "habits.morningPlan.lastDay"
        static let plannedSlots = "habits.morningPlan.slots"
        /// When each planned slot was planned, by the slot's time.
        static let plannedAt = "habits.morningPlan.plannedAt"
        /// The morning plan's session before the first call: [start, minutes].
        static let warmUp = "habits.morningPlan.warmUp"
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
        let calling = isInCall(now: now)
        resumeAfterCallIfDue(calling: calling)
        observeFocus(now: now, inCall: calling)
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
            if currentCall != nil { currentCall = nil }
            return false
        }
        guard now.timeIntervalSince(callCheckedAt) >= Self.callCheckInterval else { return inCall }
        callCheckedAt = now
        let call = calls.update(readMicrophone(tracker.isFrontmostSelf ? nil : tracker.currentSnapshot?.url))
        if call?.name != currentCall?.appName || call?.bundleId != currentCall?.bundleId {
            currentCall = call.map { CallInfo(appName: $0.name, bundleId: $0.bundleId, since: now) }
        }
        return call != nil
    }

    /// "Pause till it ends", from the menu: pauses the running session,
    /// and `tick` resumes it when the call is over.
    func pauseUntilCallEnds() {
        guard inCall, let session = sessions.currentSession, session.pausedAt == nil else { return }
        sessions.pauseSession()
        resumesAfterCall = true
    }

    private func resumeAfterCallIfDue(calling: Bool) {
        guard resumesAfterCall else { return }
        // The user resumed or ended the session themselves meanwhile.
        guard let session = sessions.currentSession, session.pausedAt != nil else {
            resumesAfterCall = false
            return
        }
        guard !calling else { return }
        resumesAfterCall = false
        sessions.resumeSession()
    }

    // MARK: - Auto-start offer

    private func observeFocus(now: Date, inCall: Bool) {
        guard let snapshot = tracker.currentSnapshot else { return detector.reset() }
        let eligible = HabitSettings.isOn(HabitSettings.autoStartOffer, defaults)
            && sessions.currentSession == nil && !breaks.isOnBreak && !tracker.isAway && !inCall
        // FocusGuard's own windows show the last app's snapshot; they're a blip.
        let sample = AutoStartDetector.Sample(appName: snapshot.appName, bundleId: snapshot.bundleIdentifier,
                                              classification: tracker.isFrontmostSelf ? .neutral : snapshot.classification,
                                              at: now, eligible: eligible)
        let offer = detector.observe(sample)
        if let current = autoStartOffer, !detector.isOngoing(since: current.since) {
            autoStartOffer = nil
            presenter.withdrawAutoStartOffer()
        }
        guard let offer, Self.mayOffer(now: now, lastOfferAt: lastOfferAt, pausedUntil: offersPausedUntil) else { return }
        lastOfferAt = now
        autoStartOffer = offer
        presenter.presentAutoStartOffer(offer, now: now)
    }

    nonisolated static func mayOffer(now: Date, lastOfferAt: Date, pausedUntil: Date) -> Bool {
        now >= pausedUntil && now.timeIntervalSince(lastOfferAt) >= offerCooldown
    }

    /// "Not now", in the menu or the notification: no offers for a while.
    func dismissAutoStartOffer(now: Date = .now) {
        autoStartOffer = nil
        offersPausedUntil = now.addingTimeInterval(Self.notNowPause)
    }

    /// "Stop offering", in the menu: turns the habit off.
    func stopOfferingAutoStart() {
        defaults.set(false, forKey: HabitSettings.autoStartOffer)
        autoStartOffer = nil
        detector.reset()
    }

    /// Where a session started from the offer begins: when that focus
    /// began, while it's still going; otherwise now (nil). The offer is
    /// taken either way.
    func takeAutoStartOffer(since: Date) -> Date? {
        autoStartOffer = nil
        return detector.isOngoing(since: since) ? since : nil
    }

    // MARK: - Morning plan

    /// "Plan them", or the evening tip's "Plan it": each slot gets a
    /// notification when it comes. Slots planned earlier stay, unless one of
    /// these is within a few minutes of them.
    func plan(_ slots: [Date], now: Date = .now) {
        let added = slots.filter { $0 > now }
        let kept = plannedSlots.filter { old in old > now && !added.contains { abs($0.timeIntervalSince(old)) < 5 * 60 } }
        var times = plannedTimes
        for slot in added { times[String(slot.timeIntervalSinceReferenceDate)] = now.timeIntervalSinceReferenceDate }
        replacePlanned(with: kept + added, times: times)
    }

    private var plannedTimes: [String: Double] {
        defaults.dictionary(forKey: Key.plannedAt) as? [String: Double] ?? [:]
    }

    private func replacePlanned(with slots: [Date], times: [String: Double]? = nil) {
        plannedSlots = slots.sorted()
        defaults.set(plannedSlots.map(\.timeIntervalSinceReferenceDate), forKey: Key.plannedSlots)
        let keys = Set(plannedSlots.map { String($0.timeIntervalSinceReferenceDate) })
        defaults.set((times ?? plannedTimes).filter { keys.contains($0.key) }, forKey: Key.plannedAt)
    }

    private func offerPlannedSession(now: Date) {
        guard let first = plannedSlots.first, first <= now else { return }
        let due = plannedSlots.filter { $0 <= now }
        let times = plannedTimes
        replacePlanned(with: plannedSlots.filter { $0 > now })
        guard let slot = due.last, now.timeIntervalSince(slot) < HabitSchedule.plannedSessionGrace,
              sessions.currentSession == nil, !breaks.isOnBreak else { return }
        presenter.presentPlannedSession(at: slot, minutes: plannedMinutes(at: slot),
                                        plannedAt: times[String(slot.timeIntervalSinceReferenceDate)].map(Date.init(timeIntervalSinceReferenceDate:)))
    }

    /// The usual length, or the shorter one of the session before the first call.
    private func plannedMinutes(at slot: Date) -> Int {
        guard let warmUp = defaults.array(forKey: Key.warmUp) as? [Double], warmUp.count == 2,
              warmUp[0] == slot.timeIntervalSinceReferenceDate else { return presenter.usualMinutes }
        return FocusActions.clamp(Int(warmUp[1]))
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
        guard let plan = MorningPlan.make(now: now, focusedMinutes: Int(focused / 60),
                                          goalMinutes: FocusGoal.minutes(on: now, defaults, calendar: calendar),
                                          sessionMinutes: presenter.usualMinutes,
                                          busy: busyTimes.busy(from: now, to: dayEnd),
                                          warmUpMinutes: CoachRules.sessionBeforeFirstCall(at: now, defaults, calendar: calendar),
                                          calendar: calendar) else { return }
        if let warmUp = plan.warmUp {
            defaults.set([warmUp.start.timeIntervalSinceReferenceDate, Double(warmUp.minutes)], forKey: Key.warmUp)
        } else {
            defaults.removeObject(forKey: Key.warmUp)
        }
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
        Task { [weak self] in
            guard let self else { return }
            presenter.presentEveningWrapUp(await withTip(wrapUp, now: now))
        }
    }

    /// The wrap-up with today's focus rate and a tip for tomorrow, from two
    /// weeks of tracked time read off the main thread.
    func withTip(_ wrapUp: EveningWrapUp, now: Date = .now) async -> EveningWrapUp {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -13, to: dayStart) ?? dayStart
        let recent = await CoachDataReader.read(context.container, interval: DateInterval(start: from, end: max(now, from)))
        let today = recent.clipped(to: DateInterval(start: dayStart, end: max(now, dayStart)))
        let tally = CoachData.tally(today.events)
        var tipped = wrapUp
        tipped.focusPercent = tally.focus + tally.drift >= 60
            ? Int((FocusRate.of(focused: tally.focus, drifted: tally.drift) * 100).rounded()) : nil
        tipped.tip = EveningTip.choose(today: today, recent: recent, gapMinutes: wrapUp.goalMinutes - wrapUp.focusedMinutes,
                                       tomorrowStart: wrapUp.tomorrowStart, sessionMinutes: presenter.usualMinutes,
                                       morningHour: HabitSchedule.morningStartHour(defaults), now: now,
                                       weekendsCount: defaults.bool(forKey: SettingsKeys.Goal.weekendsCount),
                                       shown: EveningTipMemory.recent(defaults, now: now), calendar: calendar)
        if let tip = tipped.tip { EveningTipMemory.remember(tip, defaults, now: now) }
        return tipped
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
        let goal = FocusGoal.minutes(on: now, defaults, calendar: calendar)
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
