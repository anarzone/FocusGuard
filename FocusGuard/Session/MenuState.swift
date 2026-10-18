import AppKit
import Foundation
import SwiftData

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

/// The minutes beside the menu-bar icon.
struct StatusLabel: Equatable {
    enum Kind: Equatable { case sessionLeft, sessionElapsed, breakLeft }

    let minutes: Int
    /// Paused sessions show their time dimmed.
    let dimmed: Bool
    let kind: Kind

    var text: String {
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    var accessibilityText: String {
        let unit = minutes == 1 ? "minute" : "minutes"
        switch kind {
        case .sessionLeft:    return "\(minutes) \(unit) left\(dimmed ? ", paused" : "")"
        case .sessionElapsed: return "\(minutes) \(unit) so far\(dimmed ? ", paused" : "")"
        case .breakLeft:      return "\(minutes) \(unit) of break left"
        }
    }
}

/// The finished session, frozen at the moment it ended.
struct SessionRecap {
    let label: String
    let startedAt: Date
    let endedAt: Date
    let plannedMinutes: Int?
    let timeline: SessionTimeline
    let topDrift: (name: String, seconds: TimeInterval)?
    /// Longest unbroken focus run in this session.
    let longestZone: TimeInterval
    /// True when that run is also the longest of the day so far.
    let isBestToday: Bool

    /// How long the menu keeps showing the recap before going back to Ready.
    static let shelfLife: TimeInterval = 15 * 60

    @MainActor
    init(session: Session, bestZoneToday: TimeInterval) {
        let endedAt = session.endedAt ?? .now
        let running = max(0, endedAt.timeIntervalSince(session.startedAt) - session.pausedSeconds)
        label = session.label ?? "Focus session"
        startedAt = session.startedAt
        self.endedAt = endedAt
        plannedMinutes = session.plannedDurationMinutes
        timeline = SessionTimeline.build(
            segments: SessionTimeline.segments(from: session.events),
            elapsed: running,
            planned: session.plannedDurationMinutes.map { TimeInterval($0 * 60) },
            current: nil
        )
        topDrift = SessionTimeline.topDrift(in: session.events)
        longestZone = FocusRuns.compute(FocusRuns.spans(from: session.events), now: endedAt).longest
        isBestToday = longestZone >= 60 && longestZone + 1 >= bestZoneToday
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

    /// Minutes shown beside the menu-bar icon: left in a timed session or a
    /// break, elapsed in an open-ended one, dimmed while paused. Nil when
    /// nothing is running or the user turned it off.
    func statusLabel(now: Date = .now) -> StatusLabel? {
        guard UserDefaults.standard.object(forKey: SettingsKeys.menuBarShowTime) as? Bool ?? true else { return nil }
        if let state = breakManager.current {
            return StatusLabel(minutes: Self.minutesRoundedUp(state.remaining(now: now)), dimmed: false, kind: .breakLeft)
        }
        guard let session = sessionManager.currentSession else { return nil }
        let elapsed = sessionManager.runningSeconds(for: session, now: now)
        let paused = session.pausedAt != nil
        if let planned = session.plannedDurationMinutes {
            let left = max(0, Double(planned * 60) - elapsed)
            return StatusLabel(minutes: Self.minutesRoundedUp(left), dimmed: paused, kind: .sessionLeft)
        }
        return StatusLabel(minutes: Int(elapsed / 60), dimmed: paused, kind: .sessionElapsed)
    }

    /// "1m" until the last second, so the label never reads "0m" while time remains.
    nonisolated static func minutesRoundedUp(_ seconds: TimeInterval) -> Int {
        seconds <= 0 ? 0 : Int((seconds / 60).rounded(.up))
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

    func liveTimeline(for session: Session, now: Date = .now) -> SessionTimeline {
        SessionTimeline.build(
            segments: SessionTimeline.segments(from: session.events),
            elapsed: sessionManager.runningSeconds(for: session, now: now),
            planned: session.plannedDurationMinutes.map { TimeInterval($0 * 60) },
            current: session.pausedAt == nil ? (tracker.currentSnapshot?.classification ?? .neutral) : nil,
            live: true
        )
    }

    /// "In the zone" for the running session.
    func focusRuns(for session: Session, now: Date = .now) -> FocusRuns {
        FocusRuns.compute(FocusRuns.spans(from: session.events), now: now)
    }

    /// Longest focus run across today's sessions. Cached for 30 s — it scans
    /// the whole day's events; callers fold in the live session's run.
    func bestZoneToday(now: Date = .now, fresh: Bool = false) -> TimeInterval {
        if !fresh, let cache = bestZoneCache, now.timeIntervalSince(cache.at) < 30 {
            return cache.value
        }
        let startOfDay = Calendar.current.startOfDay(for: now)
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= startOfDay }
        )
        let events = Persistence.fetch(container.mainContext, descriptor).filter { $0.session != nil }
        let value = FocusRuns.compute(FocusRuns.spans(from: events), now: now).longest
        bestZoneCache = (now, value)
        return value
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
