import Foundation
import SwiftData

@Model
final class ActivityEvent {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date

    var bundleIdentifier: String
    var appName: String
    var windowTitle: String?
    var url: String?

    /// Optional — set by Phase 4's classifier once rules exist.
    var classificationRaw: Int?

    var session: Session?

    var classification: Classification? {
        get { classificationRaw.flatMap(Classification.init(rawValue:)) }
        set { classificationRaw = newValue?.rawValue }
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        bundleIdentifier: String,
        appName: String,
        windowTitle: String? = nil,
        url: String? = nil,
        session: Session? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.session = session
    }
}
