import Foundation
import SwiftData

/// Notifications the daily limits send.
@MainActor
protocol LimitNotifying: AnyObject {
    /// A limit is about to run out while the user is on it. `minutesToday`
    /// is today's whole allowance, extra time included.
    func presentLimitWarning(name: String, minutesLeft: Int, minutesToday: Int)
}

/// Today's numbers for one daily limit.
struct LimitStatus: Equatable, Identifiable {
    let id: UUID
    let target: String
    let isSite: Bool
    let name: String
    /// Today's limit, before extra time.
    let minutes: Int
    /// Extra minutes taken today.
    let extraMinutes: Int
    /// Seconds used today.
    let used: TimeInterval
    /// Extra-time grants left today on the current preset.
    let extraLeft: Int
    /// A change that waits for tomorrow.
    let pending: DailyLimit.PendingChange?
    /// Off for now: beyond what the plan keeps. It isn't counted and doesn't block.
    var isPaused = false
    /// Strict was on today, so it goes by Strict's rules until tomorrow,
    /// whichever preset is on now.
    var changesWaitForTomorrow = false

    /// Today's allowance in seconds, extra time included.
    var allowance: TimeInterval { TimeInterval((minutes + extraMinutes) * 60) }
    var remaining: TimeInterval { max(0, allowance - used) }
    var isUsedUp: Bool { used >= allowance }
}

/// When a change to a limit takes effect.
enum LimitChange: Equatable {
    case now
    /// Strict: limits can only change from tomorrow.
    case fromTomorrow
}

/// Counts time on sites and apps that have a daily limit, all day, in
/// sessions and out, and blocks them the same way as a session once the
/// limit runs out. Everything resets at 00:00.
///
/// - Time is counted per tracker tick, so it follows what the tracker sees:
///   nothing while FocusGuard is frontmost, the Mac is idle or locked.
/// - Usage for today is read back from the store at launch and at midnight,
///   so a relaunch doesn't reset it.
/// - A warning goes out 5 minutes before a limit runs out.
/// - Extra time and same-day changes follow the preset (`OverridePolicy`).
///
/// Free keeps one limit, the oldest, in force (`activeCap`). The others stay,
/// paused, and come back with Pro; if the one in force goes, the next oldest
/// takes over. Adding more is the UI's to refuse, through `LimitGate`.
///
/// Strict's rules hold for the rest of a day Strict was on at any point, so
/// switching preset doesn't get round "only for tomorrow".
@MainActor
@Observable
final class DailyLimitsEngine {
    /// Warn this long before a limit runs out.
    static let warnBefore: TimeInterval = 5 * 60
    /// Longest gap between two ticks that still counts; a longer one means
    /// the Mac slept or tracking stopped.
    static let maxTickGap: TimeInterval = 2

    /// Every limit with today's numbers, oldest first.
    private(set) var statuses: [LimitStatus] = []

    private let context: ModelContext
    private let notifier: LimitNotifying
    private let overlay: BlockOverlayPresenting
    private let policy: () -> OverridePolicy
    /// How many limits are in force, oldest first; nil means all.
    private let activeCap: () -> Int?
    private let calendar: Calendar

    /// Start of the day being counted.
    @ObservationIgnored private var day: Date
    @ObservationIgnored private var limits: [DailyLimit] = []
    @ObservationIgnored private var used: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var warned: Set<UUID> = []
    @ObservationIgnored private var lastTickAt: Date?
    /// Limits the user was on at the last tick; the time until the next tick is theirs.
    @ObservationIgnored private var lastMatched: Set<UUID> = []

    init(context: ModelContext, notifier: LimitNotifying, overlay: BlockOverlayPresenting,
         policy: @escaping () -> OverridePolicy, activeCap: @escaping () -> Int? = { nil },
         calendar: Calendar = .current, now: Date = .now) {
        self.context = context
        self.notifier = notifier
        self.overlay = overlay
        self.policy = policy
        self.activeCap = activeCap
        self.calendar = calendar
        self.day = calendar.startOfDay(for: now)
        overlay.onExtraTime = { [weak self] id in self?.takeExtraTime(for: id) }
        applyPendingChanges()
        reload()
        used = usageToday(of: limits, now: now)
        refreshStatuses()
    }

    // MARK: - Tick

    /// Called every tracker tick with what's on screen. `counting` is false
    /// while FocusGuard is frontmost or nobody's at the Mac.
    /// - Parameter awaySince: the last input, once the tracker says nobody's
    ///   there. It can only tell after a few quiet minutes, which were counted
    ///   as they went by; they come back off here, as they're not in the record.
    func observe(snapshot: ActivitySnapshot?, counting: Bool, awaySince: Date? = nil, now: Date = .now) {
        rollOverIfNeeded(now: now)

        if let last = lastTickAt, !lastMatched.isEmpty {
            let delta = min(max(0, now.timeIntervalSince(last)), Self.maxTickGap)
            for id in lastMatched { used[id, default: 0] += delta }
            if let awaySince {
                let quiet = max(0, now.timeIntervalSince(awaySince))
                for id in lastMatched { used[id] = max(0, (used[id] ?? 0) - quiet) }
            }
        }
        lastTickAt = now

        let matched = counting ? snapshot.map(limits(matching:)) ?? [] : []
        lastMatched = Set(matched.map(\.id))
        refreshStatuses()
        guard let snapshot, !matched.isEmpty else { return }

        for limit in matched {
            guard let status = status(for: limit.id) else { continue }
            if status.isUsedUp {
                if !overlay.isPresenting {
                    overlay.present(BlockRequest(snapshot: snapshot, reason: .dailyLimit(block(for: status))))
                }
                return
            }
            if status.remaining <= Self.warnBefore, !warned.contains(limit.id) {
                warned.insert(limit.id)
                notifier.presentLimitWarning(name: limit.name, minutesLeft: Int((status.remaining / 60).rounded(.up)),
                                             minutesToday: status.minutes + status.extraMinutes)
            }
        }
    }

    private func block(for status: LimitStatus) -> LimitBlock {
        LimitBlock(limitID: status.id, name: status.name, minutesToday: status.minutes + status.extraMinutes,
                   extraTime: policy(for: status).extraTime, extraLeft: status.extraLeft)
    }

    /// The plan changed: limits beyond it have just gone off or come back.
    func planChanged(now: Date = .now) {
        // Time on a limit that was off wasn't counted.
        used = usageToday(of: limits, now: now)
        lastMatched.formIntersection(active.map(\.id))
        refreshStatuses()
        if case .dailyLimit(let block) = overlay.current?.reason, status(for: block.limitID)?.isPaused == true {
            overlay.dismiss()
        }
    }

    /// At 00:00: usage, extra time and warnings start over, changes saved
    /// for tomorrow apply, and a limit's block screen comes down.
    private func rollOverIfNeeded(now: Date) {
        let today = calendar.startOfDay(for: now)
        guard today != day else { return }
        day = today
        warned = []
        lastMatched = []
        applyPendingChanges()
        reload()
        used = usageToday(of: limits, now: now)
        if case .dailyLimit = overlay.current?.reason { overlay.dismiss() }
    }

    // MARK: - Reading

    func status(for id: UUID) -> LimitStatus? {
        statuses.first { $0.id == id }
    }

    /// The limits in force now.
    var activeStatuses: [LimitStatus] { statuses.filter { !$0.isPaused } }

    /// The rules for this limit today: Strict's, for the rest of a day Strict was on.
    func policy(for status: LimitStatus) -> OverridePolicy {
        status.changesWaitForTomorrow ? .strict : policy()
    }

    /// The limits in force, oldest first.
    private var active: [DailyLimit] {
        activeCap().map { Array(limits.prefix(max(0, $0))) } ?? limits
    }

    private func policy(for limit: DailyLimit) -> OverridePolicy {
        limit.strictDay == day ? .strict : policy()
    }

    /// Notes that Strict is on today, on each limit, for the rest of the day.
    private func noteStrict() {
        guard policy().limitChangesWaitForTomorrow else { return }
        var changed = false
        for limit in limits where limit.strictDay != day {
            limit.strictDay = day
            changed = true
        }
        if changed { Persistence.save(context) }
    }

    /// The limit on what this snapshot shows, if any (a site's first, then the app's).
    func status(for snapshot: ActivitySnapshot) -> LimitStatus? {
        limits(matching: snapshot).first.flatMap { status(for: $0.id) }
    }

    private func limits(matching snapshot: ActivitySnapshot) -> [DailyLimit] {
        let host = snapshot.url.flatMap { URL(string: $0)?.host?.lowercased() }
        let inForce = active
        let sites = inForce.filter { limit in limit.isSite && host.map { Classifier.host($0, matches: limit.target) } == true }
        let apps = inForce.filter { !$0.isSite && $0.target == snapshot.bundleIdentifier }
        return sites + apps
    }

    private func extraTaken(_ limit: DailyLimit) -> Int {
        limit.extraDay == day ? limit.extraGrants : 0
    }

    private func refreshStatuses() {
        noteStrict()
        let inForce = Set(active.map(\.id))
        let next = limits.map { limit in
            let taken = extraTaken(limit)
            let extra = policy(for: limit).extraTime
            return LimitStatus(id: limit.id, target: limit.target, isSite: limit.isSite, name: limit.name,
                               minutes: limit.minutes, extraMinutes: taken * extra.minutes,
                               used: used[limit.id] ?? 0, extraLeft: max(0, extra.timesPerDay - taken),
                               pending: limit.pendingChange, isPaused: !inForce.contains(limit.id),
                               changesWaitForTomorrow: limit.strictDay == day)
        }
        if next != statuses { statuses = next }
    }

    // MARK: - Changing limits

    /// Adds a limit on a site (a host or a URL) or an app (a bundle id), or
    /// changes the existing one. Today's earlier time on it counts. Nil when
    /// the input isn't a site or the minutes aren't positive.
    @discardableResult
    func addLimit(target input: String, isSite: Bool, name: String? = nil, minutes: Int, now: Date = .now) -> DailyLimit? {
        guard minutes > 0, let target = isSite ? Self.siteTarget(input) : Self.appTarget(input) else { return nil }
        if let existing = limits.first(where: { $0.target == target && $0.isSite == isSite }) {
            setMinutes(minutes, for: existing.id)
            return existing
        }
        let limit = DailyLimit(target: target, isSite: isSite, name: name ?? target, minutes: minutes, createdAt: now)
        context.insert(limit)
        Persistence.save(context)
        reload()
        used.merge(usageToday(of: [limit], now: now)) { $1 }
        refreshStatuses()
        return limit
    }

    /// Changes a limit's minutes: now, or from tomorrow on a day Strict was on.
    @discardableResult
    func setMinutes(_ minutes: Int, for id: UUID) -> LimitChange? {
        guard minutes > 0, let limit = limits.first(where: { $0.id == id }) else { return nil }
        noteStrict()
        if policy(for: limit).limitChangesWaitForTomorrow {
            limit.pendingMinutes = minutes
            limit.pendingFrom = tomorrow
            Persistence.save(context)
            refreshStatuses()
            return .fromTomorrow
        }
        limit.minutes = minutes
        limit.pendingMinutes = nil
        limit.pendingFrom = nil
        Persistence.save(context)
        refreshStatuses()
        return .now
    }

    /// Removes a limit: now, or from tomorrow on a day Strict was on. `evenOnStrict`
    /// removes it now on any preset (the weekly coach's limit, once its week is over).
    @discardableResult
    func removeLimit(_ id: UUID, evenOnStrict: Bool = false) -> LimitChange? {
        guard let limit = limits.first(where: { $0.id == id }) else { return nil }
        noteStrict()
        if policy(for: limit).limitChangesWaitForTomorrow && !evenOnStrict {
            limit.pendingMinutes = 0
            limit.pendingFrom = tomorrow
            Persistence.save(context)
            refreshStatuses()
            return .fromTomorrow
        }
        context.delete(limit)
        Persistence.save(context)
        if case .dailyLimit(let block) = overlay.current?.reason, block.limitID == id { overlay.dismiss() }
        reload()
        used[id] = nil
        // On Free the next oldest has just come into force, with today's time on it.
        used = usageToday(of: limits, now: .now).merging(used) { max($0, $1) }
        refreshStatuses()
        return .now
    }

    /// "5 more minutes" on a limit that ran out, while the preset allows it.
    @discardableResult
    func takeExtraTime(for id: UUID) -> Bool {
        guard let limit = active.first(where: { $0.id == id }) else { return false }
        noteStrict()
        let taken = extraTaken(limit)
        guard taken < policy(for: limit).extraTime.timesPerDay else { return false }
        limit.extraGrants = taken + 1
        limit.extraDay = day
        Persistence.save(context)
        refreshStatuses()
        return true
    }

    // MARK: - Store

    private var tomorrow: Date {
        calendar.startOfDay(1, from: day)
    }

    private func reload() {
        limits = Persistence.fetch(context, FetchDescriptor<DailyLimit>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    /// Changes saved for tomorrow (Strict) whose day has come.
    private func applyPendingChanges() {
        let today = day
        let due = Persistence.fetch(context, FetchDescriptor<DailyLimit>(
            predicate: #Predicate { $0.pendingFrom != nil }
        )).filter { ($0.pendingFrom ?? .distantFuture) <= today }
        guard !due.isEmpty else { return }
        for limit in due {
            if let minutes = limit.pendingMinutes, minutes > 0 {
                limit.minutes = minutes
                limit.pendingMinutes = nil
                limit.pendingFrom = nil
            } else {
                context.delete(limit)
            }
        }
        Persistence.save(context)
    }

    /// Time already recorded on these limits today, by limit id.
    private func usageToday(of limits: [DailyLimit], now: Date) -> [UUID: TimeInterval] {
        guard !limits.isEmpty else { return [:] }
        let dayStart = day
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= dayStart }
        )).map { (start: $0.startedAt, end: $0.endedAt, bundleId: $0.bundleIdentifier, url: $0.url) }
        return Dictionary(uniqueKeysWithValues: limits.map {
            ($0.id, Self.usage(of: $0.target, isSite: $0.isSite, in: events, from: dayStart, to: now))
        })
    }

    /// Seconds of these events on a site or app between `start` and `end`.
    static func usage(of target: String, isSite: Bool,
                      in events: [(start: Date, end: Date, bundleId: String, url: String?)],
                      from start: Date, to end: Date) -> TimeInterval {
        events.reduce(0) { total, event in
            let matches = isSite
                ? event.url.flatMap { URL(string: $0)?.host }.map { Classifier.host($0, matches: target) } == true
                : event.bundleId == target
            guard matches else { return total }
            return total + max(0, min(event.end, end).timeIntervalSince(max(event.start, start)))
        }
    }

    /// "youtube.com" from "https://www.youtube.com/watch?v=…", "YouTube.com" or "m.youtube.com/".
    nonisolated static func siteTarget(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")?.host ?? trimmed
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard clean.contains("."), !clean.contains(" ") else { return nil }
        return clean
    }

    nonisolated static func appTarget(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains(" ") ? nil : trimmed
    }
}
