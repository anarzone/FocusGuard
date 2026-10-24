import AppKit
import Foundation
import SwiftData

/// What Apps & Sites shows: Used, the rules, or the sorting flow.
enum AppsMode: Hashable {
    case used, rules, sort
}

/// How far back "Used" looks.
enum AppsRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "Last 7 days"
    case month = "Last 30 days"

    var id: String { rawValue }

    func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week:  return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        }
    }

    /// "in the last 7 days", "today".
    var phrase: String {
        switch self {
        case .today: return "today"
        case .week:  return "in the last 7 days"
        case .month: return "in the last 30 days"
        }
    }
}

/// Where an app's or site's category comes from.
enum RuleSource: Equatable {
    /// No rule: it counts as neutral.
    case none
    /// One of FocusGuard's own rules.
    case builtIn
    /// One the user made, here or by changing a category.
    case user

    init(_ rule: AppRule?) {
        guard let rule else { self = .none; return }
        self = rule.priority >= 200 ? .user : .builtIn
    }
}

/// One app or site in "Used".
struct AppsItem: Identifiable, Equatable {
    let row: UsageRow
    let source: RuleSource
    /// The rule that decides it, if any, by kind; for the why line.
    let ruleKind: RuleMatchKind?

    var id: String { row.id }
    var name: String { row.name }
    var isSite: Bool { row.isSite }
    /// What a daily limit or rule targets: the host, or the bundle id.
    var target: String { row.host ?? row.bundleId }

    /// "Site · built-in rule", "App · you sorted it".
    var why: String {
        let kind = isSite ? "Site" : "App"
        switch source {
        case .none:    return "\(kind) · no rule yet"
        case .builtIn: return "\(kind) · built-in rule"
        case .user:    return ruleKind == .titleRegex ? "\(kind) · your window-title rule" : "\(kind) · you sorted it"
        }
    }
}

@MainActor
enum AppsModelBuilder {
    /// Apps and sites used since `start`, most time first, with where each
    /// one's category comes from.
    static func items(context: ModelContext, classifier: Classifier, from start: Date, to end: Date) -> [AppsItem] {
        MenuInsightsBuilder.usageRows(context: context, from: start, to: end, limit: 300).map { row in
            let rule = classifier.matchingRule(bundleId: row.host == nil ? row.bundleId : "",
                                               windowTitle: nil,
                                               url: row.host.map { "https://\($0)" })
            return AppsItem(row: row, source: RuleSource(rule), ruleKind: rule?.matchKind)
        }
    }

    /// How many items each category has.
    static func counts(_ items: [AppsItem]) -> [Classification: Int] {
        Dictionary(grouping: items, by: \.row.classification).mapValues(\.count)
    }

    /// Items left to sort: the ones nobody has decided on yet, most used
    /// first, then the built-in guesses.
    static func toSort(_ items: [AppsItem]) -> [AppsItem] {
        items.filter { $0.source == .none } + items.filter { $0.source == .builtIn }
    }
}

// MARK: - Rules

/// A rule as the Rules list shows it.
struct RuleItem: Identifiable, Equatable {
    let id: UUID
    let kind: RuleMatchKind
    /// The app's name, the host, the address prefix, or what the title contains.
    let title: String
    let note: String
    let classification: Classification
    let source: RuleSource
    let limitMinutes: Int?

    /// "App", "Site", "Part of a site", "Window title".
    var matchLabel: String { kind == .titleRegex ? "Window title" : kind.label }
}

@MainActor
enum RuleItemBuilder {
    static func items(rules: [AppRule], limits: [LimitStatus]) -> [RuleItem] {
        let hosts = Set(rules.filter { $0.matchKind == .host }.map { $0.pattern.lowercased() })
        return rules
            .sorted { ($0.priority, $0.createdAt) > ($1.priority, $1.createdAt) }
            .map { rule in
                let limit = limits.first { status in
                    switch rule.matchKind {
                    case .host:     return status.isSite && status.target == rule.pattern.lowercased()
                    case .bundleId: return !status.isSite && status.target == rule.pattern
                    default:        return false
                    }
                }
                return RuleItem(id: rule.id, kind: rule.matchKind, title: title(rule), note: note(rule, hosts: hosts),
                                classification: rule.classification, source: RuleSource(rule),
                                limitMinutes: limit?.minutes)
            }
    }

    static func title(_ rule: AppRule) -> String {
        switch rule.matchKind {
        case .bundleId:   return appName(rule.pattern) ?? fallbackName(rule.pattern)
        case .host:       return rule.pattern
        case .urlPrefix:  return rule.pattern
        case .titleRegex: return "contains “\(TitleRule.readable(rule.pattern))”"
        }
    }

    static func note(_ rule: AppRule, hosts: Set<String>) -> String {
        switch rule.matchKind {
        case .bundleId:   return rule.pattern
        case .host:       return "and its subdomains"
        case .urlPrefix:
            let host = rule.pattern.split(separator: "/").first.map(String.init) ?? ""
            return hosts.contains(host) ? "Wins over \(host)" : "Only this part of the site"
        case .titleRegex: return "Window titles, in any app"
        }
    }

    /// "Discord" from "com.hnc.Discord", for apps that aren't installed.
    static func fallbackName(_ bundleId: String) -> String {
        let parts = bundleId.split(separator: ".").map(String.init)
        guard var name = parts.last else { return bundleId }
        // "com.example.Thing.desktop" says less than the part before it.
        if ["desktop", "app", "mac", "macos", "client", "electron"].contains(name.lowercased()), parts.count > 1 {
            name = parts[parts.count - 2]
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static var names: [String: String?] = [:]

    /// The app's name for a bundle id, if it's installed.
    static func appName(_ bundleId: String) -> String? {
        if let cached = names[bundleId] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        names[bundleId] = name
        return name
    }
}

/// Window-title rules are stored as a case-insensitive regex. The window
/// only makes "contains" rules, escaped, and reads them back as plain text.
enum TitleRule {
    static func pattern(containing text: String) -> String {
        NSRegularExpression.escapedPattern(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The text a "contains" rule looks for, or the raw pattern for others.
    static func readable(_ pattern: String) -> String {
        var out = ""
        var escaped = false
        for ch in pattern {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            out.append(ch)
        }
        return out
    }
}

// MARK: - Matching preview

/// "Matched 46 visits in the last 7 days, 1h 05m in total."
@MainActor
enum RuleMatchPreview {
    struct Result: Equatable {
        let visits: Int
        let seconds: TimeInterval
    }

    static func preview(kind: RuleMatchKind, pattern: String, context: ModelContext, now: Date = .now) -> Result? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let start = AppsRange.week.start(now: now)
        let descriptor = FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.endedAt >= start })
        let events = Persistence.fetch(context, descriptor)
        var visits = 0
        var seconds: TimeInterval = 0
        var lastMatched = false
        for event in events.sorted(by: { $0.startedAt < $1.startedAt }) {
            let matched: Bool
            switch kind {
            case .bundleId:
                matched = event.bundleIdentifier == pattern
            case .host:
                matched = event.url.flatMap { URL(string: $0)?.host?.lowercased() }
                    .map { Classifier.host($0, matches: trimmed) } ?? false
            case .urlPrefix:
                matched = event.url.map { Classifier.url($0, matchesPrefix: trimmed) } ?? false
            case .titleRegex:
                matched = event.windowTitle?.localizedCaseInsensitiveContains(pattern.trimmingCharacters(in: .whitespaces)) ?? false
            }
            if matched {
                seconds += max(0, event.duration) + 1
                if !lastMatched { visits += 1 }
            }
            lastMatched = matched
        }
        return Result(visits: visits, seconds: seconds)
    }
}
