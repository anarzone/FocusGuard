import Foundation

/// State machine that tracks consecutive distraction time during an active
/// session and fires escalating responses:
/// - 0..silenceThreshold: log only (no action)
/// - silenceThreshold..notifyThreshold: still silent
/// - >= notifyThreshold: send a motivational notification (throttled)
/// - >= blockThreshold: show the block overlay
///
/// Streak resets the moment the user goes back to a non-distraction activity
/// or stops the session.
@MainActor
@Observable
final class EscalationEngine {
    /// Below this many seconds of continuous distraction we do nothing.
    var silenceThreshold: TimeInterval = 10
    /// At this many seconds we send a notification (once per cooldown).
    var notifyThreshold: TimeInterval = 30
    /// At this many seconds we show the block overlay.
    var blockThreshold: TimeInterval = 90
    /// Minimum seconds between notifications for the same streak.
    var notifyCooldown: TimeInterval = 60

    /// Strict mode: any distraction during a session triggers the block overlay
    /// IMMEDIATELY, bypassing silence and notify thresholds. Lenient (default):
    /// silence → notify → block as configured.
    var strictMode: Bool = false

    /// What the block screen lets you do, from the preset these settings match.
    var policy: OverridePolicy {
        DriftResponse.matching(silence: Int(silenceThreshold), notify: Int(notifyThreshold),
                               block: Int(blockThreshold), strict: strictMode).overridePolicy
    }

    /// A "Let me through" in progress: one site or app, for `policy.passSeconds`.
    /// The time still counts as drift; it only holds the block screen back.
    struct Pass: Equatable {
        /// URL host, else bundle id (see `allowKey`).
        let key: String
        /// What the menu bar shows: "x.com", or the app's name.
        let name: String
        let expiresAt: Date

        func remaining(now: Date = .now) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }
    }

    private(set) var activePass: Pass?
    private(set) var currentStreakStartedAt: Date?
    /// Sites / apps the user said are "for work" during this session. Never
    /// escalated until the session ends. Keyed by URL host, else bundle id.
    private(set) var allowedThisSession: Set<String> = []
    private var lastNotifiedAt: Date?
    /// What the block screen was put up for, so "Let me through" knows what to let through.
    private var blocked: ActivitySnapshot?
    /// A pass ran out while the user was still there: block again straight away.
    private var reblockKey: String?

    private let presenter: DistractionNotifier
    private let overlay: BlockOverlayPresenting

    init(presenter: DistractionNotifier, overlay: BlockOverlayPresenting? = nil) {
        self.presenter = presenter
        self.overlay = overlay ?? BlockOverlayController()
        self.overlay.onOverride = { [weak self] in self?.takePass() }
    }

    /// Called every tracker tick. `isInSession` should be true only when the
    /// user has explicitly started a focus session — escalation is a no-op
    /// outside sessions.
    func observe(snapshot: ActivitySnapshot, isInSession: Bool) {
        let now = snapshot.observedAt
        let key = Self.allowKey(for: snapshot)

        // Honor an in-flight "let me through" pass for this site.
        if let pass = activePass {
            if now >= pass.expiresAt {
                activePass = nil
                if key == pass.key { reblockKey = key }
            } else if key == pass.key {
                currentStreakStartedAt = nil
                lastNotifiedAt = nil
                return
            }
        }

        guard isInSession, snapshot.classification == .distraction,
              !allowedThisSession.contains(key) else {
            // Reset the streak on focus / neutral / no session.
            currentStreakStartedAt = nil
            lastNotifiedAt = nil
            reblockKey = nil
            return
        }

        if currentStreakStartedAt == nil {
            currentStreakStartedAt = now
        }

        guard let start = currentStreakStartedAt else { return }
        let elapsed = now.timeIntervalSince(start)

        // Block stage takes precedence — once the overlay is up, no more
        // notifications. Strict skips the silence/notify ladder, and a pass
        // that just ran out brings the block screen straight back.
        if strictMode || elapsed >= blockThreshold || reblockKey == key {
            if !overlay.isPresenting { presentBlock(for: snapshot) }
            return
        }

        if elapsed >= notifyThreshold {
            if let last = lastNotifiedAt, now.timeIntervalSince(last) < notifyCooldown {
                return  // throttled
            }
            presenter.presentDistractionWarning(
                appName: snapshot.appName,
                currentURL: snapshot.url
            )
            lastNotifiedAt = now
        }
    }

    private func presentBlock(for snapshot: ActivitySnapshot) {
        blocked = snapshot
        reblockKey = nil
        overlay.present(BlockRequest(snapshot: snapshot, reason: .drift(policy)))
    }

    /// "Let me through": a pass for the site on the block screen, if the
    /// preset allows one. Its time still counts as drift.
    func takePass(now: Date = .now) {
        guard policy.allowsPass, let snapshot = blocked else { return }
        activePass = Pass(key: Self.allowKey(for: snapshot),
                          name: BlockRequest.displayHost(snapshot.url) ?? snapshot.appName,
                          expiresAt: now.addingTimeInterval(policy.passSeconds))
        blocked = nil
        currentStreakStartedAt = nil
        lastNotifiedAt = nil
    }

    /// "It's for work": stop escalating this site / app for the rest of the
    /// session, and lift the block if it's already up.
    func allowForSession(_ snapshot: ActivitySnapshot) {
        allowedThisSession.insert(Self.allowKey(for: snapshot))
        currentStreakStartedAt = nil
        lastNotifiedAt = nil
        reblockKey = nil
        dismissDriftBlock()
    }

    static func allowKey(for snapshot: ActivitySnapshot) -> String {
        snapshot.url.flatMap { URL(string: $0)?.host?.lowercased() } ?? snapshot.bundleIdentifier
    }

    func resetForSessionEnd() {
        currentStreakStartedAt = nil
        lastNotifiedAt = nil
        activePass = nil
        reblockKey = nil
        blocked = nil
        allowedThisSession = []
        dismissDriftBlock()
    }

    /// Takes the block screen down only if a drift put it up; a daily limit's
    /// block stays when the session ends.
    private func dismissDriftBlock() {
        if case .drift = overlay.current?.reason { overlay.dismiss() }
    }
}
