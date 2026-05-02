import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var label: String?
    var statusRaw: Int
    /// Planned length in minutes; nil means open-ended. SessionManager auto-stops
    /// the session when elapsed time reaches this value.
    var plannedDurationMinutes: Int?
    /// When the user paused; nil while running. Tracker stops associating events
    /// with this session while non-nil.
    var pausedAt: Date?
    /// Total accumulated paused time, in seconds. Updated on resume.
    var pausedSeconds: TimeInterval = 0

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
