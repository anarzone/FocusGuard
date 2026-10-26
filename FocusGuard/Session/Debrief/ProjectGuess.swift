import Foundation

/// Which project a session counted toward, for the work log. Renaming and
/// merging projects comes later; for now the name is worked out once, when
/// the session ends, in this order:
/// 1. a project from earlier sessions that the goal names,
/// 2. the project the model named,
/// 3. a repository open on github.com or gitlab.com,
/// 4. the name the focus windows share ("FocusGuard — Session.swift").
enum ProjectGuess {
    static func guess(goal: String?, modelProject: String? = nil, titles: [DebriefFacts.Title],
                      apps: [DebriefFacts.App], known: [String]) -> String? {
        if let goal, let named = known.first(where: { mentions(goal, $0) }) { return named }
        if let modelProject = clean(modelProject) { return canonical(modelProject, known: known) }
        if let repo = repository(in: titles) { return canonical(repo, known: known) }
        if let shared = sharedName(titles: titles, apps: apps) { return canonical(shared, known: known) }
        return nil
    }

    /// The known spelling of `name`, if an earlier session used one.
    static func canonical(_ name: String, known: [String]) -> String {
        known.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    /// Whether `goal` names `project` as a whole word: "Fix FocusGuard's
    /// menu" names FocusGuard, "refocus" doesn't name Focus.
    static func mentions(_ goal: String, _ project: String) -> Bool {
        guard project.count >= 2 else { return false }
        let pattern = "(^|[^\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: project) + "($|[^\\p{L}\\p{N}])"
        return goal.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "FocusGuard" from a tab titled "… · Pull Request #49 · anarzone/FocusGuard".
    static func repository(in titles: [DebriefFacts.Title]) -> String? {
        var totals: [String: TimeInterval] = [:]
        for title in titles where title.app == "github.com" || title.app == "gitlab.com" {
            for part in title.title.components(separatedBy: " · ") {
                let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "/")
                guard pieces.count == 2, let repo = pieces.last,
                      pieces.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
                else { continue }
                totals[String(repo), default: 0] += title.seconds
            }
        }
        return totals.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// The part focus-app titles share: "FocusGuard" from "FocusGuard —
    /// Session.swift" and "FocusGuard — AppState.swift". It has to be in at
    /// least two titles and a third of the titled focus time.
    static func sharedName(titles: [DebriefFacts.Title], apps: [DebriefFacts.App]) -> String? {
        let focusApps = Set(apps.filter { $0.classification == .focus && !$0.isSite }.map(\.name))
        let appNames = Set(apps.map { $0.name.lowercased() })
        var seconds: [String: TimeInterval] = [:]
        var count: [String: Int] = [:]
        var total: TimeInterval = 0
        for title in titles where focusApps.contains(title.app) {
            total += title.seconds
            for part in Set(parts(of: title.title)) where !appNames.contains(part.lowercased()) {
                seconds[part, default: 0] += title.seconds
                count[part, default: 0] += 1
            }
        }
        guard total > 0 else { return nil }
        return seconds
            .filter { count[$0.key, default: 0] >= 2 && $0.value >= total / 3 }
            .max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// A title's pieces that could be a name: not a file, not too long.
    private static func parts(of title: String) -> [String] {
        title.components(separatedBy: CharacterSet(charactersIn: "—–|·"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { part in
                guard part.count >= 2, part.count <= 40, part.split(separator: " ").count <= 4 else { return false }
                guard part.range(of: "^[^ ]+\\.[A-Za-z0-9]{1,5}$", options: .regularExpression) == nil else { return false }
                guard part.rangeOfCharacter(from: .letters) != nil else { return false }
                return !["edited", "untitled"].contains(part.lowercased())
            }
    }

    private static func clean(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.count <= 40 else { return nil }
        return trimmed
    }
}
