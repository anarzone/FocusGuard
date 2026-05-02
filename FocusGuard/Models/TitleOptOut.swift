import Foundation
import SwiftData

/// An app whose window titles should not be persisted alongside activity events.
@Model
final class TitleOptOut {
    @Attribute(.unique) var bundleIdentifier: String
    var reason: String?
    var createdAt: Date

    init(bundleIdentifier: String, reason: String? = nil, createdAt: Date = .now) {
        self.bundleIdentifier = bundleIdentifier
        self.reason = reason
        self.createdAt = createdAt
    }
}
