import Foundation
import UserNotifications

/// Watches the activity stream for a "drift loop" — repeated visits to the
/// same distraction host within a short window — and surfaces a "Start a
/// focus session?" notification when it sees one.
///
/// This is fired only OUTSIDE of an active session; the EscalationEngine
/// already handles in-session distraction. Cooldown per host so a single
/// rabbit hole doesn't spam the user.
@MainActor
final class PatternDetector {
    private let presenter: NotificationPresenter
    private let windowSeconds: TimeInterval = 600   // 10 min
    private let triggerCount = 3
    private let perHostCooldown: TimeInterval = 3600 // 1 hour

    private var visits: [String: [Date]] = [:]   // host → recent visit timestamps
    private var lastSuggestedAt: [String: Date] = [:]
    private var lastObservedHost: String?

    init(presenter: NotificationPresenter) {
        self.presenter = presenter
    }

    func observe(snapshot: ActivitySnapshot, isInSession: Bool) {
        // Only watch distractions, only when the user isn't already focused.
        guard !isInSession,
              snapshot.classification == .distraction,
              let host = snapshot.url.flatMap({ URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") })
        else {
            lastObservedHost = nil
            return
        }

        // De-dupe consecutive ticks on the same host — a 10-minute Twitter
        // session would otherwise count as 600 visits.
        if lastObservedHost == host { return }
        lastObservedHost = host

        let now = Date()

        // Trim visits outside the rolling window.
        var times = visits[host] ?? []
        times = times.filter { now.timeIntervalSince($0) <= windowSeconds }
        times.append(now)
        visits[host] = times

        guard times.count >= triggerCount else { return }
        if let last = lastSuggestedAt[host], now.timeIntervalSince(last) < perHostCooldown { return }
        lastSuggestedAt[host] = now
        visits[host] = []  // reset so we don't re-suggest mid-cooldown

        presenter.presentDriftPrompt(host: host)
    }
}
