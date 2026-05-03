import Foundation
import SwiftData

/// Resolves an `(bundleId, windowTitle, url)` tuple into a `Classification`
/// using the user-editable rule store.
///
/// Caching: rule fetches are cheap (single-table, low cardinality) but doing
/// them on every 1 Hz tick is wasteful. We snapshot rules into memory and
/// refresh after `cacheTTL` seconds, or eagerly when the rules editor calls
/// `invalidate()`.
@MainActor
@Observable
final class Classifier {
    private let context: ModelContext
    private var rules: [AppRule] = []
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 30

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    func invalidate() {
        lastFetch = nil
    }

    /// Persist a user override for a given bundle ID or host. Replaces any
    /// existing rule with the same pattern + match-kind so toggling between
    /// classifications doesn't accumulate dead rows. Higher priority (300)
    /// than the default 200 to ensure user overrides win cleanly.
    func setOverride(bundleId: String? = nil, host: String? = nil, classification: Classification) {
        let pattern: String
        let kind: RuleMatchKind
        if let bundleId, !bundleId.isEmpty {
            pattern = bundleId
            kind = .bundleId
        } else if let host, !host.isEmpty {
            pattern = host
            kind = .host
        } else {
            return
        }

        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<AppRule>(
            predicate: #Predicate { $0.pattern == pattern && $0.matchKindRaw == kindRaw }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        for rule in existing {
            rule.classification = classification
            rule.priority = 300
        }
        if existing.isEmpty {
            context.insert(AppRule(
                pattern: pattern,
                matchKind: kind,
                classification: classification,
                priority: 300
            ))
        }

        // Back-fill: reclassify past ActivityEvent rows so the change is
        // visible in current reports immediately, not just for future events.
        let raw = classification.rawValue
        switch kind {
        case .bundleId:
            let bundleDescriptor = FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { $0.bundleIdentifier == pattern }
            )
            let events = (try? context.fetch(bundleDescriptor)) ?? []
            for e in events { e.classificationRaw = raw }
        case .host:
            // Host match is "url contains host" — predicate runs over all
            // events with a non-nil URL and we filter in Swift. Cheap enough
            // since reclassification is a rare action.
            let urlDescriptor = FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { $0.url != nil }
            )
            let events = (try? context.fetch(urlDescriptor)) ?? []
            let needle = pattern.lowercased()
            for e in events {
                if let host = e.url.flatMap({ URL(string: $0)?.host?.lowercased() }),
                   host.contains(needle) {
                    e.classificationRaw = raw
                }
            }
        case .titleRegex:
            break
        }

        try? context.save()
        invalidate()
    }

    func classify(bundleId: String, windowTitle: String?, url: String?) -> Classification {
        if shouldRefresh { refresh() }

        let host = url.flatMap { URL(string: $0)?.host?.lowercased() }

        for rule in rules {
            let pattern = rule.pattern
            switch rule.matchKind {
            case .bundleId:
                if bundleId == pattern { return rule.classification }

            case .host:
                if let host, host.contains(pattern.lowercased()) {
                    return rule.classification
                }

            case .titleRegex:
                if let title = windowTitle,
                   let regex = try? Regex(pattern).ignoresCase(),
                   (try? regex.firstMatch(in: title)) != nil {
                    return rule.classification
                }
            }
        }
        return .neutral
    }

    // MARK: - Private

    private var shouldRefresh: Bool {
        guard let last = lastFetch else { return true }
        return Date().timeIntervalSince(last) > cacheTTL
    }

    private func refresh() {
        var descriptor = FetchDescriptor<AppRule>()
        descriptor.sortBy = [SortDescriptor(\.priority, order: .reverse)]
        rules = (try? context.fetch(descriptor)) ?? []
        lastFetch = .now
    }
}
