import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    /// The user's own name for the session; nil means automatic.
    var label: String?
    /// The name it earned when it ended, e.g. "Steady Deep Dive"
    /// (see `SessionNamer`). Shown when `label` is nil.
    var autoName: String?
    var statusRaw: Int
    /// Planned length in minutes; nil means open-ended. SessionManager auto-stops
    /// the session when elapsed time reaches this value.
    var plannedDurationMinutes: Int?
    /// When the user paused; nil while running. Tracker stops associating events
    /// with this session while non-nil.
    var pausedAt: Date?
    /// Total accumulated paused time, in seconds. Updated on resume.
    var pausedSeconds: TimeInterval = 0
    /// What the session was for, typed before it started (Pro). Nil
    /// without one.
    var goal: String?
    /// Whether the goal was reached (`GoalVerdict`): the debrief's verdict,
    /// or the user's correction of it. Nil until there's a debrief.
    var goalVerdictRaw: String?
    /// The project the session counted toward in the work log, worked out
    /// from its goal and apps.
    var project: String?
    /// The written debrief (`StoredDebrief`, JSON), made on this Mac when
    /// the session ended. Nil without Apple Intelligence.
    var debriefData: Data?

    @Relationship(deleteRule: .cascade, inverse: \ActivityEvent.session)
    var events: [ActivityEvent] = []

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        label: String? = nil,
        status: SessionStatus = .active,
        plannedDurationMinutes: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.label = label
        self.statusRaw = status.rawValue
        self.plannedDurationMinutes = plannedDurationMinutes
    }
}
