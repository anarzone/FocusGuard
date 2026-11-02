import Foundation
import Observation

/// Tells teammates you're focusing (Settings › Integrations › Status in
/// Slack and Discord, Pro). While a session runs, Slack shows "Focusing
/// until 19:32" and holds notifications until then, and Discord shows
/// "Focusing" under your name. "5 more min" and resuming from a pause move
/// the end; when the session ends, both come off.
///
/// Only what FocusGuard set is ever taken off, and only while it's still
/// up: Slack clears a status and ends a snooze at the time they were set
/// for, so a session that runs to its end leaves Slack alone. What was set
/// is kept across launches (`Posted`).
@MainActor
@Observable
final class StatusSync {
    static let shared = StatusSync()

    let slack: SlackAccount
    let discord: DiscordPresence

    /// The session as Slack and Discord see it.
    struct Focus: Equatable {
        let sessionID: UUID
        let start: Date
        /// The planned end; open-ended, the usual length from the start
        /// (as on the calendar).
        let end: Date
        let isOpenEnded: Bool
    }

    /// What FocusGuard set for the session it last showed.
    struct Posted: Codable, Equatable {
        var sessionID: UUID
        var end: Date
        /// The Slack status FocusGuard set; nil when it set none.
        var statusText: String?
        /// Slack's Do Not Disturb is FocusGuard's snooze.
        var snoozed = false
        var discord = false

        var isEmpty: Bool { statusText == nil && !snoozed && !discord }
    }

    /// What should show, with the switches and the plan as they are.
    struct Wants: Equatable {
        var status = false
        var snooze = false
        var discord = false
    }

    private(set) var posted: Posted?

    /// The session running now; `AppState` passes the session manager's.
    @ObservationIgnored var currentSession: () -> Session? = { nil }
    /// Whether the switch is on; tests turn it on before it ships.
    @ObservationIgnored var isShipped: Bool = FeatureFlags.statusSync
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let entitlements: Entitlements
    @ObservationIgnored private let clock: () -> Date
    /// Changes run one after another, in order.
    @ObservationIgnored private var queue: Task<Void, Never>?

    nonisolated static let postedKey = "integrations.status.posted"

    init(slack: SlackAccount? = nil, discord: DiscordPresence = DiscordPresence(), entitlements: Entitlements? = nil,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.slack = slack ?? SlackAccount(defaults: defaults)
        self.discord = discord
        self.entitlements = entitlements ?? .shared
        self.defaults = defaults
        self.clock = now
        posted = defaults.data(forKey: Self.postedKey).flatMap { try? JSONDecoder().decode(Posted.self, from: $0) }
    }

    /// The section shows once either app's ID is built in.
    var isAvailable: Bool { isShipped && (slack.isConfigured || discord.isConfigured) }

    /// Slack is built in, so FocusGuard may go online to it (the privacy note).
    nonisolated static var slackAvailable: Bool { FeatureFlags.statusSync && SlackAccount.bundledClientID != nil }

    /// An Info.plist value filled from a build setting; nil while it's empty.
    nonisolated static func infoValue(_ key: String, in bundle: Bundle = .main) -> String? {
        let value = (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    // MARK: - Keeping up with the session

    /// Brings Slack and Discord in line with the session running now, or
    /// with none: on start, "5 more min", pause and resume, end, after
    /// connecting, and when a setting changes.
    func update() {
        guard !UITestMode.isOn else { return }
        var focus = currentSession().flatMap { Self.sessionFocus($0, usualMinutes: FocusActions.usualMinutes(defaults)) }
        // An open-ended session keeps the end it was shown with.
        if let shown = focus, shown.isOpenEnded, let posted, posted.sessionID == shown.sessionID {
            focus = Focus(sessionID: shown.sessionID, start: shown.start, end: posted.end, isOpenEnded: true)
        }
        enqueue { await self.apply(focus) }
    }

    /// Slack's answer from the browser, then the running session shows.
    func finishSlackSignIn(code: String?, state: String?, error: String?) {
        enqueue { await self.slack.finishConnect(code: code, state: state, error: error) }
        update()
    }

    /// "Disconnect": what FocusGuard set in Slack comes off first.
    func disconnectSlack() {
        enqueue {
            if var posted = self.posted {
                await self.takeDownSlack(posted, now: self.clock())
                posted.statusText = nil
                posted.snoozed = false
                self.keep(posted)
            }
            await self.slack.disconnect()
        }
    }

    /// At launch: a quiet month doesn't sign Slack out.
    func keepAlive() {
        enqueue { await self.slack.keepAlive() }
    }

    /// Waits for every change asked for so far; for tests.
    func settle() async {
        while let task = queue {
            await task.value
            if queue == task { queue = nil }
        }
        await discord.settle()
    }

    nonisolated static func sessionFocus(_ session: Session, usualMinutes: Int) -> Focus? {
        guard session.endedAt == nil else { return nil }
        let minutes = session.plannedDurationMinutes ?? usualMinutes
        // Time paused pushes the end out; a pause going on now counts once it's over.
        let end = session.startedAt.addingTimeInterval(session.pausedSeconds + TimeInterval(minutes * 60))
        return Focus(sessionID: session.id, start: session.startedAt, end: end,
                     isOpenEnded: session.plannedDurationMinutes == nil)
    }

    func wants() -> Wants {
        guard isShipped, entitlements.isUnlocked(.statusSync) else { return Wants() }
        let slackOn = slack.isConnected && StatusSettings.isOn(StatusSettings.slack, defaults)
        return Wants(status: slackOn && StatusSettings.isOn(StatusSettings.slackStatus, defaults),
                     snooze: slackOn && StatusSettings.isOn(StatusSettings.slackSnooze, defaults),
                     discord: discord.isConfigured && StatusSettings.isOn(StatusSettings.discord, defaults))
    }

    // MARK: - Applying

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func apply(_ focus: Focus?) async {
        let now = clock()
        if let old = posted, old.sessionID != focus?.sessionID {
            await takeDownSlack(old, now: now)
            keep(nil)
        }
        guard let focus else {
            discord.show(nil)
            return
        }
        let want = wants()
        var next = posted ?? Posted(sessionID: focus.sessionID, end: focus.end)
        let shownUntil = next.end
        let moved = next.end != focus.end
        next.end = focus.end

        if want.status {
            let text = StatusText.render(StatusSettings.text(defaults), end: focus.end)
            if next.statusText != text || moved, focus.end > now,
               await slack.setStatus(text, emoji: StatusSettings.emoji, expires: focus.end) {
                next.statusText = text
            }
        } else if next.statusText != nil {
            if now < shownUntil { _ = await slack.clearStatus() }
            next.statusText = nil
        }

        if want.snooze {
            if !next.snoozed || moved, let minutes = Self.snoozeMinutes(until: focus.end, now: now),
               await slack.snooze(minutes: minutes) {
                next.snoozed = true
            }
        } else if next.snoozed {
            if now < shownUntil { _ = await slack.endSnooze() }
            next.snoozed = false
        }

        discord.show(want.discord ? Self.activity(for: focus) : nil)
        next.discord = want.discord
        keep(next)
    }

    /// Takes off what's still up in Slack from `posted`. Past its end,
    /// Slack has already.
    private func takeDownSlack(_ posted: Posted, now: Date) async {
        guard now < posted.end else { return }
        if posted.statusText != nil { _ = await slack.clearStatus() }
        if posted.snoozed { _ = await slack.endSnooze() }
    }

    /// Remembers what's set; with nothing set, nothing is kept.
    private func keep(_ next: Posted?) {
        posted = next?.isEmpty == false ? next : nil
        if let posted, let data = try? JSONEncoder().encode(posted) {
            defaults.set(data, forKey: Self.postedKey)
        } else {
            defaults.removeObject(forKey: Self.postedKey)
        }
    }

    /// Minutes of Do Not Disturb to reach `end`; nil once it's passed.
    nonisolated static func snoozeMinutes(until end: Date, now: Date) -> Int? {
        guard end > now else { return nil }
        return max(1, Int((end.timeIntervalSince(now) / 60).rounded()))
    }

    /// The time left; open-ended, the time so far.
    nonisolated static func activity(for focus: Focus) -> DiscordIPC.Activity {
        let details = String(localized: "Focusing", comment: "A session is running; also what Discord shows under the user's name")
        return focus.isOpenEnded
            ? DiscordIPC.Activity(details: details, start: focus.start)
            : DiscordIPC.Activity(details: details, end: focus.end)
    }

    /// When a session started now would end, for the settings' preview.
    func previewEnd() -> Date {
        if let session = currentSession(), let focus = Self.sessionFocus(session, usualMinutes: FocusActions.usualMinutes(defaults)) {
            return focus.end
        }
        return clock().addingTimeInterval(TimeInterval(FocusActions.usualMinutes(defaults) * 60))
    }
}

/// The settings for Status in Slack and Discord. Slack's sign-in is in the
/// Keychain (`SlackAccount`).
enum StatusSettings {
    /// Slack follows sessions once connected; on by default.
    static let slack = "integrations.slack.enabled"
    /// Slack shows the status text below; on by default.
    static let slackStatus = "integrations.slack.setStatus"
    /// The status, with `{end}` for the session's end time.
    static let slackText = "integrations.slack.statusText"
    /// Slack's Do Not Disturb until the session ends; on by default.
    static let slackSnooze = "integrations.slack.pauseNotifications"
    /// Discord shows "Focusing"; waits to be turned on.
    static let discord = "integrations.discord.enabled"

    static let defaultText = String(localized: "Focusing until {end}", comment: "Slack status. Keep {end} as it is: it becomes the session's end time, as in 19:32")
    static let emoji = ":headphones:"

    static func isOn(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? (key != discord)
    }

    static func text(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: slackText) ?? defaultText
    }
}

/// The Slack status as teammates read it.
enum StatusText {
    /// Slack takes no more.
    static let limit = 100

    /// "Focusing until 19:32": `{end}` becomes the end time, in this Mac's
    /// time format.
    static func render(_ template: String, end: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
        let text = (trimmed.isEmpty ? StatusSettings.defaultText : trimmed).replacingOccurrences(of: "{end}", with: time)
        return String(text.prefix(limit))
    }
}
