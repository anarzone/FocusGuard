import Foundation
import Observation

/// Lightweight in-memory state for an active break. Breaks are not persisted
/// to SwiftData yet — they exist only between session-end and break-end. If
/// we want "N breaks today" in Reports later, promote this to a @Model.
struct BreakState: Equatable {
    let startedAt: Date
    /// Mutable so the user can extend mid-break.
    var plannedDuration: TimeInterval

    /// Seconds remaining (clamped to 0). Computed on read.
    func remaining(now: Date = .now) -> TimeInterval {
        let elapsed = now.timeIntervalSince(startedAt)
        return max(0, plannedDuration - elapsed)
    }

    var isComplete: Bool { remaining() <= 0 }
}

/// Owns the active break. Starts/extends/skips. Mirrors `SessionManager`'s
/// shape so the rest of the app talks to it the same way.
@Observable
@MainActor
final class BreakManager {
    private(set) var current: BreakState?

    /// Fired once when a break ends naturally (timer hits 0). NOT fired when
    /// the user skips — skipping cancels the break, the prompt to start a new
    /// session is the user's already-active intent.
    var onBreakCompleted: (() -> Void)?
    /// Fired when a break ends by any means (completed or skipped). Hooked to
    /// the overlay controller so it can dismiss.
    var onBreakEnded: (() -> Void)?

    var isOnBreak: Bool { current != nil }

    func startBreak(durationMinutes: Int) {
        guard current == nil else { return }
        current = BreakState(
            startedAt: .now,
            plannedDuration: TimeInterval(durationMinutes * 60)
        )
    }

    /// Add minutes to the current break without restarting the clock. Used
    /// by the "+5 min" button on the overlay.
    func extend(byMinutes minutes: Int) {
        guard var state = current else { return }
        state.plannedDuration += TimeInterval(minutes * 60)
        current = state
    }

    /// User pressed "Skip break". Cancels the break.
    func skip() {
        guard current != nil else { return }
        current = nil
        onBreakEnded?()
    }

    /// Called from the tracker tick. If the break has run out, fire callbacks
    /// and clear state. Returns true on the tick when the break completes.
    @discardableResult
    func checkExpiration(now: Date = .now) -> Bool {
        guard let state = current, state.remaining(now: now) <= 0 else { return false }
        current = nil
        onBreakCompleted?()
        onBreakEnded?()
        return true
    }
}
