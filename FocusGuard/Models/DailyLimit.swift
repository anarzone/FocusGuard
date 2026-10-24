import Foundation
import SwiftData

/// A daily time limit on one site or app: minutes a day, counted all day (in
/// sessions and out) and reset at 00:00. `DailyLimitsEngine` counts and enforces it.
@Model
final class DailyLimit {
    @Attribute(.unique) var id: UUID
    /// A site's host ("youtube.com", subdomains included) or an app's bundle id.
    var target: String
    var isSite: Bool
    /// What the screens show: the host, or the app's name.
    var name: String
    /// Minutes a day.
    var minutes: Int
    /// A change that waits for tomorrow (Strict): the new minutes, or 0 to
    /// remove the limit.
    var pendingMinutes: Int?
    /// Start of the day `pendingMinutes` takes effect.
    var pendingFrom: Date?
    /// Extra-time grants taken on `extraDay`.
    var extraGrants: Int = 0
    /// Start of the day `extraGrants` belong to.
    var extraDay: Date?
    var createdAt: Date

    /// A change waiting for tomorrow, as the UI shows it.
    enum PendingChange: Equatable {
        case minutes(Int)
        case removal
    }

    var pendingChange: PendingChange? {
        guard let pending = pendingMinutes else { return nil }
        return pending == 0 ? .removal : .minutes(pending)
    }

    init(id: UUID = UUID(), target: String, isSite: Bool, name: String, minutes: Int, createdAt: Date = .now) {
        self.id = id
        self.target = target
        self.isSite = isSite
        self.name = name
        self.minutes = minutes
        self.createdAt = createdAt
    }
}
