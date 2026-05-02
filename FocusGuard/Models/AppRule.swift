import Foundation
import SwiftData

@Model
final class AppRule {
    @Attribute(.unique) var id: UUID
    var pattern: String
    var matchKindRaw: Int
    var classificationRaw: Int
    /// Higher priority wins on conflict. Built-in rules use 100, user rules
    /// default to 200 so they override defaults.
    var priority: Int
    var createdAt: Date

    var matchKind: RuleMatchKind {
        get { RuleMatchKind(rawValue: matchKindRaw) ?? .bundleId }
        set { matchKindRaw = newValue.rawValue }
    }

    var classification: Classification {
        get { Classification(rawValue: classificationRaw) ?? .neutral }
        set { classificationRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        pattern: String,
        matchKind: RuleMatchKind,
        classification: Classification,
        priority: Int = 200,
        createdAt: Date = .now
    ) {
        self.id = id
        self.pattern = pattern
        self.matchKindRaw = matchKind.rawValue
        self.classificationRaw = classification.rawValue
        self.priority = priority
        self.createdAt = createdAt
    }
}
