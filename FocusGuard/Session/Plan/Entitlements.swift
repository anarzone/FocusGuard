import AppKit
import Observation
import OSLog

/// Sends the reminder two days before the trial ends.
@MainActor
protocol TrialReminding: AnyObject {
    func presentTrialEndingSoon(endsAt: Date)
}

/// Which plan this Mac is on, and what that unlocks.
///
/// The 14-day trial needs no card. It starts the first time someone turns
/// on a Pro feature, runs once, and never starts from installing the
/// browser extension, which is free. A reminder goes out two days before
/// it ends; after that the plan is Free again.
@MainActor
@Observable
final class Entitlements {
    static let shared = Entitlements(reminder: NotificationPresenter())

    /// Changes when the trial starts or runs out, and when a licence is
    /// added or removed.
    private(set) var plan: Plan = .free

    private var trialEndsAt: Date?
    private var licenceKey: String?
    /// Debug builds' stand-in plan. Always nil in release builds.
    private var overridePlan: Plan?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let verifier: LicenceVerifier
    @ObservationIgnored private let reminder: TrialReminding?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private enum Key {
        static let trialEndsAt = "plan.trialEndsAt"
        static let trialReminded = "plan.trialReminded"
        static let licenceKey = "plan.licenceKey"
        static let debugOverride = "plan.debugOverride"
    }

    private static let logger = Logger(subsystem: "com.anar.focusguard", category: "plan")

    /// - Parameters:
    ///   - defaults: where the trial and licence are kept; tests pass their own.
    ///   - reminder: sends the trial reminder; nil sends none.
    ///   - now: the clock; tests move it.
    init(defaults: UserDefaults = .standard,
         verifier: LicenceVerifier = PlaceholderLicenceVerifier(),
         reminder: TrialReminding? = nil,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.verifier = verifier
        self.reminder = reminder
        self.now = now
        trialEndsAt = defaults.object(forKey: Key.trialEndsAt) as? Date
        licenceKey = defaults.string(forKey: Key.licenceKey)
        #if DEBUG
        overridePlan = Self.decodeOverride(defaults.string(forKey: Key.debugOverride), now: now())
        #endif
        // Timers don't count time asleep, so look at the clock again on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        if licenceKey != nil { Task { await recheckLicence() } }
    }

    // MARK: - Features

    /// Whether `feature` can be used right now.
    func isUnlocked(_ feature: ProFeature) -> Bool {
        plan.unlocksPro(at: now())
    }

    /// Whether the trial can still start. It runs once, ever.
    var canStartTrial: Bool {
        if let overridePlan { return overridePlan == .free }
        return trialEndsAt == nil && licenceKey == nil
    }

    /// Call when someone turns on a Pro feature. Starts the 14-day trial the
    /// first time; does nothing during the trial, on Pro, or once the trial
    /// has run. Installing the browser extension isn't a Pro feature, so it
    /// never calls this.
    func startTrialIfNeeded(for feature: ProFeature) {
        guard canStartTrial else { return }
        let start = now()
        let endsAt = Calendar.current.date(byAdding: .day, value: Plan.trialDays, to: start)
            ?? start.addingTimeInterval(TimeInterval(Plan.trialDays) * 86_400)
        #if DEBUG
        if overridePlan != nil {
            // Try the flow without using up the real trial.
            setOverride(.trial(endsAt: endsAt))
            return
        }
        #endif
        trialEndsAt = endsAt
        defaults.set(endsAt, forKey: Key.trialEndsAt)
        Self.logger.info("trial started by \(feature.rawValue, privacy: .public)")
        refresh()
    }

    /// The first day Reports may show: 30 days back on Free, nil (all of
    /// it) with full history.
    func historyStart(calendar: Calendar = .current) -> Date? {
        guard !isUnlocked(.fullHistory) else { return nil }
        return calendar.date(byAdding: .day, value: 1 - Plan.freeHistoryDays, to: calendar.startOfDay(for: now()))
    }

    /// How many daily limits can be set; nil means no cap.
    var dailyLimitCap: Int? {
        isUnlocked(.unlimitedLimits) ? nil : Plan.freeDailyLimits
    }

    // MARK: - Licence

    /// Checks `key` and, if it's good, switches to Pro.
    func activateLicence(_ key: String) async -> LicenceCheck {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .invalid(reason: "Enter a licence key.") }
        let result = await verifier.verify(key)
        if result == .valid {
            licenceKey = key
            defaults.set(key, forKey: Key.licenceKey)
            refresh()
        }
        return result
    }

    func removeLicence() {
        licenceKey = nil
        defaults.removeObject(forKey: Key.licenceKey)
        refresh()
    }

    /// Checks the saved key again (at launch) and drops it if it's no
    /// longer good.
    func recheckLicence() async {
        guard let key = licenceKey else { return }
        if await verifier.verify(key) != .valid, licenceKey == key {
            Self.logger.info("saved licence key was turned down")
            removeLicence()
        }
    }

    // MARK: - Clock

    /// Catches up with the clock: ends a trial that has run out and sends
    /// the reminder when it's due. Runs on its own from a timer and on wake.
    func refresh() {
        let now = now()
        let current = currentPlan(at: now)
        if current != plan { plan = current }
        remindIfDue(at: now)
        scheduleNextCheck(after: now)
    }

    /// When the reminder is due for a trial ending at `endsAt`.
    static func reminderDate(for endsAt: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -Plan.trialReminderDays, to: endsAt)
            ?? endsAt.addingTimeInterval(-TimeInterval(Plan.trialReminderDays) * 86_400)
    }

    private func currentPlan(at now: Date) -> Plan {
        if let overridePlan {
            if case .trial(let endsAt) = overridePlan, now >= endsAt { return .free }
            return overridePlan
        }
        if licenceKey != nil { return .pro }
        if let trialEndsAt, now < trialEndsAt { return .trial(endsAt: trialEndsAt) }
        return .free
    }

    private var reminded: Bool { defaults.bool(forKey: Key.trialReminded) }

    private func remindIfDue(at now: Date) {
        guard overridePlan == nil, case .trial(let endsAt) = plan,
              now >= Self.reminderDate(for: endsAt), !reminded else { return }
        defaults.set(true, forKey: Key.trialReminded)
        reminder?.presentTrialEndingSoon(endsAt: endsAt)
    }

    /// One timer at the next moment something changes: the reminder, then
    /// the end of the trial.
    private func scheduleNextCheck(after now: Date) {
        timer?.invalidate()
        timer = nil
        guard case .trial(let endsAt) = plan else { return }
        let remindAt = Self.reminderDate(for: endsAt)
        let next = overridePlan == nil && !reminded && remindAt > now ? remindAt : endsAt
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    #if DEBUG
    // MARK: - Debug override

    /// A plan to pretend to be on in debug builds, so every screen can be
    /// tried without a licence.
    enum DebugPlan: Hashable {
        case free
        case trial(daysLeft: Int)
        case pro
    }

    /// Nil uses the real plan. It survives relaunch, and can be set at
    /// launch with `-plan.debugOverride pro` (or `free`, `trial`, `trial:2`).
    /// The real trial and licence are never touched.
    var debugOverride: DebugPlan? {
        get {
            switch overridePlan {
            case nil: return nil
            case .free: return .free
            case .pro: return .pro
            case .trial: return .trial(daysLeft: overridePlan?.daysLeft(at: now()) ?? 0)
            }
        }
        set {
            setOverride(newValue.map { debugPlan in
                switch debugPlan {
                case .free: return .free
                case .pro: return .pro
                case .trial(let daysLeft): return .trial(endsAt: now().addingTimeInterval(TimeInterval(daysLeft) * 86_400))
                }
            })
        }
    }

    private func setOverride(_ plan: Plan?) {
        overridePlan = plan
        defaults.set(plan.map { Self.encodeOverride($0, now: now()) }, forKey: Key.debugOverride)
        refresh()
    }

    private static func encodeOverride(_ plan: Plan, now: Date) -> String {
        switch plan {
        case .free: return "free"
        case .pro: return "pro"
        case .trial: return "trial:\(plan.daysLeft(at: now) ?? 0)"
        }
    }

    static func decodeOverride(_ raw: String?, now: Date) -> Plan? {
        guard let raw = raw?.lowercased() else { return nil }
        switch raw {
        case "free": return .free
        case "pro": return .pro
        case "trial": return .trial(endsAt: now.addingTimeInterval(TimeInterval(Plan.trialDays) * 86_400))
        default:
            guard raw.hasPrefix("trial:"), let days = Int(raw.dropFirst("trial:".count)) else { return nil }
            return .trial(endsAt: now.addingTimeInterval(TimeInterval(days) * 86_400))
        }
    }
    #endif
}
