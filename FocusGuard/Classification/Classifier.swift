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
