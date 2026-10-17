import AppKit
import Foundation

/// What the user drifted to, while it's happening.
struct DriftInfo: Equatable {
    let since: Date
    let snapshot: ActivitySnapshot
    /// When the block overlay takes over; nil in strict mode (it already has).
    let blocksAt: Date?

    var displayName: String {
        let host = snapshot.url.flatMap { URL(string: $0)?.host }
        return host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? snapshot.appName
    }
}

/// The finished session, frozen at the moment it ended.
struct SessionRecap {
    let label: String
    let startedAt: Date
    let endedAt: Date
    let plannedMinutes: Int?
    let grid: SessionGrid
    let topDrift: (name: String, seconds: TimeInterval)?

    /// How long the menu keeps showing the recap before going back to Ready.
    static let shelfLife: TimeInterval = 15 * 60

    @MainActor
    init(session: Session) {
        let endedAt = session.endedAt ?? .now
        let running = max(0, endedAt.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        label = session.label ?? "Focus session"
        startedAt = session.startedAt
        self.endedAt = endedAt
        plannedMinutes = session.plannedDurationMinutes
        grid = SessionGrid.build(
            segments: SessionGrid.segments(from: session.events),
            elapsed: running,
            planned: session.plannedDurationMinutes.map { TimeInterval($0 * 60) },
            current: nil
        )
        topDrift = SessionGrid.topDrift(in: session.events)
    }

    var nextSessionMinutes: Int { plannedMinutes ?? 25 }
    var suggestedBreakMinutes: Int { AppState.suggestedBreakMinutes(forSessionMinutes: nextSessionMinutes) }
}

/// The one thing the menu is about right now. Break wins over session wins
/// over recap wins over ready.
enum MenuPhase {
    case ready
    case session(Session, drift: DriftInfo?)
    case recap(SessionRecap)
    case onBreak(BreakState)
}

extension AppState {
    func menuPhase(now: Date = .now) -> MenuPhase {
        if let state = breakManager.current { return .onBreak(state) }
        if let session = sessionManager.currentSession {
            return .session(session, drift: session.pausedAt == nil ? currentDrift(now: now) : nil)
        }
        if let recap, now.timeIntervalSince(recap.endedAt) < SessionRecap.shelfLife {
            return .recap(recap)
        }
        return .ready
    }

    var statusGlyphState: StatusGlyphState {
        switch menuPhase() {
        case .ready:
            return .ready
        case .onBreak:
            return .onBreak
        case .recap:
            return .complete
        case .session(let session, let drift):
            if session.pausedAt != nil { return .paused }
            if drift != nil { return .drifted }
            return .focusing(
                elapsed: sessionManager.runningSeconds(for: session),
                planned: session.plannedDurationMinutes.map { TimeInterval($0 * 60) }
            )
        }
    }

    /// A drift counts once it outlasts the engine's silence window, so a
    /// two-second glance at a distracting tab doesn't flip the menu.
    func currentDrift(now: Date = .now) -> DriftInfo? {
        guard let since = escalationEngine.currentStreakStartedAt,
              let snapshot = tracker.currentSnapshot,
              snapshot.classification == .distraction,
              now.timeIntervalSince(since) >= escalationEngine.silenceThreshold else { return nil }
        let blocksAt = escalationEngine.strictMode
            ? nil
            : since.addingTimeInterval(escalationEngine.blockThreshold)
        return DriftInfo(since: since, snapshot: snapshot, blocksAt: blocksAt)
    }

    func liveGrid(for session: Session, now: Date = .now) -> SessionGrid {
        SessionGrid.build(
            segments: SessionGrid.segments(from: session.events),
            elapsed: sessionManager.runningSeconds(for: session, now: now),
            planned: session.plannedDurationMinutes.map { TimeInterval($0 * 60) },
            current: session.pausedAt == nil ? (tracker.currentSnapshot?.classification ?? .neutral) : nil,
            live: true
        )
    }

    /// Bring back the last app the user was focused in; failing that, just
    /// hide the distraction.
    func backToWork() {
        if let id = tracker.lastFocusBundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        } else {
            NSWorkspace.shared.frontmostApplication?.hide()
        }
    }

    /// "It's for work" — stop nudging about this site / app until the session ends.
    func allowCurrentDriftForSession() {
        guard let snapshot = tracker.currentSnapshot else { return }
        escalationEngine.allowForSession(snapshot)
    }
}
