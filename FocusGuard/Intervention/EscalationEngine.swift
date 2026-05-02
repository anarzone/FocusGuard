import Foundation

/// State machine that tracks consecutive distraction time during an active
/// session and fires escalating responses:
/// - 0..silenceThreshold: log only (no action)
/// - silenceThreshold..notifyThreshold: still silent
/// - >= notifyThreshold: send a motivational notification (throttled)
/// - >= blockThreshold: (Phase 5 full) trigger block overlay — not yet wired
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
    /// At this many seconds we'd show the block overlay (not implemented yet).
    var blockThreshold: TimeInterval = 90
    /// Minimum seconds between notifications for the same streak.
    var notifyCooldown: TimeInterval = 60

    /// How many seconds of override the block overlay's "let me through" button
    /// grants. Resets the streak so we don't immediately re-block.
    var overrideGraceSeconds: TimeInterval = 120

    /// Strict mode: any distraction during a session triggers the block overlay
    /// IMMEDIATELY, bypassing silence and notify thresholds. Lenient (default):
    /// silence → notify → block as configured.
    var strictMode: Bool = false

    private(set) var currentStreakStartedAt: Date?
    private var lastNotifiedAt: Date?
    private var overrideExpiresAt: Date?

    private let presenter: DistractionNotifier
    private let overlay: BlockOverlayPresenting

    init(presenter: DistractionNotifier, overlay: BlockOverlayPresenting? = nil) {
        self.presenter = presenter
        self.overlay = overlay ?? BlockOverlayController()
        self.overlay.onOverride = { [weak self] in
            guard let self else { return }
            self.overrideExpiresAt = Date().addingTimeInterval(self.overrideGraceSeconds)
            self.currentStreakStartedAt = nil
            self.lastNotifiedAt = nil
        }
    }

    /// Called every tracker tick. `isInSession` should be true only when the
    /// user has explicitly started a focus session — escalation is a no-op
    /// outside sessions.
    func observe(snapshot: ActivitySnapshot, isInSession: Bool) {
        // Honor an in-flight "let me through" override.
        if let expiry = overrideExpiresAt {
            if Date() < expiry {
                currentStreakStartedAt = nil
                return
            } else {
                overrideExpiresAt = nil
            }
        }

        guard isInSession, snapshot.classification == .distraction else {
            // Reset the streak on focus / neutral / no session.
            currentStreakStartedAt = nil
            lastNotifiedAt = nil
            return
        }

        let now = snapshot.observedAt
        if currentStreakStartedAt == nil {
            currentStreakStartedAt = now
        }

        guard let start = currentStreakStartedAt else { return }
        let elapsed = now.timeIntervalSince(start)

        // Strict mode: skip the silence/notify ladder, block immediately.
        if strictMode, !overlay.isPresenting {
            overlay.present(
                distractionAppName: snapshot.appName,
                urlHost: snapshot.url.flatMap { URL(string: $0)?.host },
                overrideSeconds: Constants.Escalation.blockOverrideCountdown
            )
            return
        }

        // Block stage takes precedence — once the overlay is up, no more notifications.
        if elapsed >= blockThreshold, !overlay.isPresenting {
            overlay.present(
                distractionAppName: snapshot.appName,
                urlHost: snapshot.url.flatMap { URL(string: $0)?.host },
                overrideSeconds: Constants.Escalation.blockOverrideCountdown
            )
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

    func resetForSessionEnd() {
        currentStreakStartedAt = nil
        lastNotifiedAt = nil
        overrideExpiresAt = nil
        if overlay.isPresenting { overlay.dismiss() }
    }
}
