import Foundation

/// Checks what the model wrote against what the session actually holds, and
/// drops whatever isn't backed by it: apps, files, pull requests and counts it
/// made up, and any claim that the goal got done. Whether it did is the
/// person's call. Run when a debrief is written, and again when one is shown,
/// so debriefs written before this check are held to it too.
struct DebriefCheck {
    /// The session as the model was told it, without the goal.
    private let activity: String
    private let activityWords: Set<String>
    private let activityNumbers: Set<String>
    private let goalWords: Set<String>
    /// Words of the titles that share a word with the goal.
    private let goalTitleWords: Set<String>
    /// Each app's or site's title words, by its lower-cased name.
    private let titleWords: [String: Set<String>]
    /// Whether capital letters mark names. In German every noun has one.
    private let capitalsMarkNames: Bool

    init(facts: DebriefFacts, language: String = OnDeviceAI.appLanguage) {
        let lines = DebriefPrompt(facts: facts).text.split(separator: "\n").dropFirst()
        activity = Self.fold(lines.joined(separator: "\n"))
        activityWords = Self.words(activity)
        activityNumbers = Set(Self.numbers(in: activity))
        var goal = Self.words(Self.fold(facts.goal ?? "")).subtracting(Self.stopWords)
        // A goal's "PR" is a title's "Pull Request".
        if !goal.isDisjoint(with: ["pr", "prs"]) { goal.formUnion(["pull", "request"]) }
        goalWords = Self.words(Self.fold(facts.goal ?? ""))
        var byApp: [String: Set<String>] = [:]
        var related = Set<String>()
        for title in facts.titles {
            let words = Self.words(Self.fold(title.title)).subtracting(Self.stopWords)
            byApp[Self.fold(title.app), default: []].formUnion(words)
            if !words.isDisjoint(with: goal) { related.formUnion(words) }
        }
        titleWords = byApp
        goalTitleWords = related
        capitalsMarkNames = language == "en"
    }

    func clean(_ draft: StoredDebrief) -> StoredDebrief {
        var out = draft
        // What the titles show about the goal, so it needs a title about the goal.
        out.evidence = draft.evidence.flatMap { text in
            supported(text) && !Self.words(Self.fold(text)).isDisjoint(with: goalTitleWords) ? text : nil
        }
        out.evidenceShort = out.evidence == nil ? nil : draft.evidenceShort.flatMap { supported($0) ? $0 : nil }
        out.workedOn = draft.workedOn.map { StoredDebrief.Line(app: $0.app, what: what($0)) }
        out.driftDetail = draft.driftDetail.flatMap { supported($0) ? $0 : nil }
        out.tip = draft.tip.flatMap { supported($0) ? $0 : nil }
        out.tipDetail = out.tip == nil ? nil : draft.tipDetail.flatMap { text in
            let words = Self.words(Self.fold(text)).subtracting(Self.stopWords)
            return supported(text) && !words.isDisjoint(with: activityWords.subtracting(Self.stopWords)) ? text : nil
        }
        out.project = draft.project.flatMap { project($0) }
        return out
    }

    /// Only words from that app's own titles: with none, there's nothing to say.
    private func what(_ line: StoredDebrief.Line) -> String {
        guard let titles = titleWords[Self.fold(line.app)], supported(line.what),
              !Self.words(Self.fold(line.what)).subtracting(Self.stopWords).isDisjoint(with: titles) else { return "" }
        return line.what
    }

    private func project(_ name: String) -> String? {
        let folded = Self.fold(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty, !Self.placeholders.contains(folded) else { return nil }
        // A name the goal or the titles use, not one it came up with.
        return Self.words(folded).isSubset(of: activityWords.union(goalWords)) ? name : nil
    }

    /// Nothing in `text` that the session doesn't have, and no claim it got done.
    func supported(_ text: String) -> Bool {
        let folded = Self.fold(text)
        let words = Self.words(folded)
        if folded.range(of: Self.goalClaim, options: .regularExpression) != nil { return false }
        // "Merged" is fine when a title says so.
        if !words.subtracting(activityWords).isDisjoint(with: Self.doneWords) { return false }
        if !Set(Self.spelledNumbers(in: words)).isSubset(of: activityNumbers) { return false }

        let known = activityWords.union(goalWords)
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = raw.trimmingCharacters(in: .punctuationCharacters)
            let foldedToken = Self.fold(token)
            guard !token.isEmpty else { continue }
            let hasLetters = token.rangeOfCharacter(from: .letters) != nil
            if token.rangeOfCharacter(from: .decimalDigits) != nil {
                // Numbers have to come from the activity: "Review 3 PRs" as a
                // goal doesn't make "Reviewed 3 PRs" true. An id it names as a
                // whole, like PROJ-123, is fine.
                let whole = hasLetters && foldedToken.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .allSatisfy { known.contains(String($0)) }
                if !whole, !Self.numbers(in: foldedToken).allSatisfy(activityNumbers.contains) { return false }
                continue
            }
            // A file or a site.
            if foldedToken.contains("."), hasLetters, !activity.contains(foldedToken), !goalWords.isSuperset(of: Self.words(foldedToken)) {
                return false
            }
            // SessionNamer, PR.
            if Self.looksLikeAName(token), !Self.words(foldedToken).isSubset(of: known) {
                if foldedToken == "pr" || foldedToken == "prs", activity.contains("pull request") { continue }
                return false
            }
        }
        return !capitalsMarkNames || !hasUnknownCapital(text, known: known)
    }

    /// A capitalised word in the middle of a sentence that the session doesn't have.
    private func hasUnknownCapital(_ text: String, known: Set<String>) -> Bool {
        var startOfSentence = true
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = raw.trimmingCharacters(in: .punctuationCharacters)
            defer { startOfSentence = raw.last.map { ".:!?".contains($0) } ?? false }
            guard !startOfSentence, let first = token.first, first.isUppercase else { continue }
            if !Self.words(Self.fold(token)).isSubset(of: known) { return true }
        }
        return false
    }

    /// Capitals inside the word.
    private static func looksLikeAName(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    // MARK: - Words

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Digits without leading zeros, so 09:00 and 9 are the same 9.
    private static func numbers(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isNumber }).map { part in
            let trimmed = part.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }
    }

    private static func spelledNumbers(in words: Set<String>) -> [String] {
        words.compactMap { spelled[$0] }
    }

    private static let spelled = [
        "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "twenty": "20", "thirty": "30",
        "zwei": "2", "drei": "3", "vier": "4", "funf": "5", "sechs": "6", "sieben": "7", "acht": "8", "neun": "9",
        "zehn": "10", "elf": "11", "zwolf": "12", "zwanzig": "20", "dreissig": "30",
    ]

    /// Saying the goal got done, whatever a title claims.
    private static let goalClaim = #"\b(goal|ziel)\b.{0,30}\b(reached|met|achieved|done|complete|completed|finished|erreicht|erledigt|geschafft|fertig)\b"#

    private static let doneWords: Set<String> = [
        "done", "complete", "completed", "finished", "shipped", "resolved", "fixed", "achieved", "accomplished",
        "succeeded", "merged", "reached", "solved", "wrapped",
        "erledigt", "abgeschlossen", "fertig", "geschafft", "erreicht", "behoben", "gelost", "beendet",
    ]

    private static let placeholders: Set<String> = [
        "unknown", "unclear", "none", "n/a", "na", "no project", "project", "not clear", "untitled", "tbd", "other",
        "unbekannt", "keines", "kein projekt", "projekt",
    ]

    /// Words too common to tie a sentence to a title.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "was", "were", "you", "your", "are", "has", "had", "its", "not", "but",
        "all", "any", "out", "off", "into", "over", "after", "before", "during", "while", "then", "than", "when", "next", "more",
        "session", "sessions", "time", "focus", "focused", "drift", "drifted", "drifting", "min", "minutes", "app", "apps", "site",
        "der", "die", "das", "und", "mit", "von", "fur", "auf", "ist", "war", "nach", "vor", "bei", "ein", "eine", "dem", "den", "des",
        "at", "on", "in", "of", "to", "a", "an", "is", "it", "by", "as", "or",
    ]
}
