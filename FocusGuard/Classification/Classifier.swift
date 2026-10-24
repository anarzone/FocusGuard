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
    /// Title patterns compiled once per refresh; invalid ones map to nil.
    private var compiledTitlePatterns: [String: Regex<AnyRegexOutput>?] = [:]
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 30

    /// True while Strict locks the blocked list (until the session ends):
    /// nothing blocked can be unblocked then. Set by AppState.
    @ObservationIgnored var isBlockListLocked: () -> Bool = { false }

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    func invalidate() {
        lastFetch = nil
        // Rules changed (and setOverride back-fills past events): totals the
        // stats store kept for past days are out of date.
        NotificationCenter.default.post(name: .activityTotalsChanged, object: nil)
    }

    /// Persist a user override for a given bundle ID or host. Replaces any
    /// existing rule with the same pattern + match-kind so toggling between
    /// classifications doesn't accumulate dead rows. Higher priority (300)
    /// than the default 200 to ensure user overrides win cleanly. Returns
    /// false when Strict's lock refuses to unblock it.
    @discardableResult
    func setOverride(bundleId: String? = nil, host: String? = nil, classification: Classification) -> Bool {
        let pattern: String
        let kind: RuleMatchKind
        if let bundleId, !bundleId.isEmpty {
            pattern = bundleId
            kind = .bundleId
        } else if let host, !host.isEmpty {
            pattern = host
            kind = .host
        } else {
            return false
        }
        if classification != .distraction, isBlockListLocked(), isBlocked(pattern, kind) { return false }

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
            for e in events {
                if let host = e.url.flatMap({ URL(string: $0)?.host?.lowercased() }),
                   Self.host(host, matches: pattern) {
                    e.classificationRaw = raw
                }
            }
        case .titleRegex:
            break
        }

        try? context.save()
        invalidate()
        return true
    }

    /// Whether this app or site is classified as a distraction right now.
    func isBlocked(_ pattern: String, _ kind: RuleMatchKind) -> Bool {
        switch kind {
        case .bundleId:   return classify(bundleId: pattern, windowTitle: nil, url: nil) == .distraction
        case .host:       return classify(bundleId: "", windowTitle: nil, url: "https://\(pattern)") == .distraction
        case .titleRegex: return false
        }
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
                if let host, Self.host(host, matches: pattern) {
                    return rule.classification
                }

            case .titleRegex:
                if let title = windowTitle,
                   let regex = compiledTitlePatterns[pattern] ?? nil,
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
        // Highest priority first; on a tie the newer rule wins, so the
        // order is the same on every launch.
        descriptor.sortBy = [SortDescriptor(\.priority, order: .reverse),
                             SortDescriptor(\.createdAt, order: .reverse)]
        rules = (try? context.fetch(descriptor)) ?? []
        compiledTitlePatterns = [:]
        for rule in rules where rule.matchKind == .titleRegex && compiledTitlePatterns[rule.pattern] == nil {
            let regex = Self.compileTitlePattern(rule.pattern)
            if regex == nil {
                Persistence.logger.error("ignoring invalid title rule: \(rule.pattern, privacy: .public)")
            }
            compiledTitlePatterns[rule.pattern] = .some(regex)
        }
        lastFetch = .now
    }

    // MARK: - Matching

    /// A site rule matches the host itself and its subdomains — `youtube.com`
    /// matches `m.youtube.com`, but not `notyoutube.com` or
    /// `youtube.com.example.net` (it used to be a plain substring check).
    static func host(_ host: String, matches pattern: String) -> Bool {
        var p = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        if let schemeEnd = p.range(of: "://") { p = String(p[schemeEnd.upperBound...]) }
        if let slash = p.firstIndex(of: "/") { p = String(p[..<slash]) }
        if p.hasPrefix("www.") { p = String(p.dropFirst(4)) }
        guard !p.isEmpty else { return false }
        let h = host.lowercased()
        return h == p || h.hasSuffix("." + p)
    }

    /// Case-insensitive title pattern, or nil when it isn't valid.
    static func compileTitlePattern(_ pattern: String) -> Regex<AnyRegexOutput>? {
        (try? Regex(pattern))?.ignoresCase()
    }
}
