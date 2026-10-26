import Foundation

/// Asks the on-device model what new apps and sites are, a few at a time,
/// and decides which answers are sure enough to apply on their own.
enum SmartCategorizer {
    /// Items per question: the on-device model's context is small.
    static let batchSize = 6

    /// The model's answer about one item.
    struct Verdict: Equatable {
        let key: String
        let classification: Classification
        let sure: Int
        let reason: String
    }

    /// Applied on its own, or left for the person.
    enum Decision: Equatable {
        case apply
        case askUser
    }

    /// Sure enough to apply Focus or Neutral without asking.
    static let applyAt = 75
    /// Distracting blocks pages in sessions, so it takes more.
    static let applyDistractingAt = 85

    static func decide(_ verdict: Verdict, evidence: SmartEvidence) -> Decision {
        switch verdict.classification {
        case .focus, .neutral:
            return verdict.sure >= applyAt ? .apply : .askUser
        case .distraction:
            // Mostly used inside sessions: calling it a distraction would
            // block something they work with. Let them say.
            if evidence.sessionShare >= 0.5 && evidence.seconds >= 10 * 60 { return .askUser }
            return verdict.sure >= applyDistractingAt ? .apply : .askUser
        }
    }

    /// Asks about `items` in batches. Items the model leaves out, or a batch
    /// that fails, get no verdict; they're asked again on the next run.
    static func verdicts(for items: [SmartEvidence], model: any OnDeviceModel) async -> [Verdict] {
        var out: [Verdict] = []
        var start = 0
        while start < items.count {
            let batch = Array(items[start..<min(start + batchSize, items.count)])
            start += batchSize
            do {
                out += try await ask(batch, model: model)
            } catch {
                Persistence.logger.error("smart categories: batch failed: \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }

    // MARK: - The question

    static let instructions = """
        You sort the apps and websites someone uses on their Mac for a focus timer.
        focus: tools for their work or study, like code editors, design tools, terminals, \
        docs, issue trackers and reference sites.
        neutral: neither helps nor hurts, like system utilities, settings, file managers, \
        calls, and music playing in the background.
        distracting: pulls attention away from work, like social media, video, news feeds, \
        games and shopping.
        Judge from the evidence: when and how long it's used, what it's used next to, \
        and its window titles.
        For each one, write a reason of at most ten plain words that points to the evidence, \
        like "Open next to Xcode while you code". Don't repeat the category in the reason.
        Say how sure you are from 0 to 100. Below 70 means a person should decide.
        """

    private struct Answer: Decodable {
        struct Item: Decodable {
            let id: String
            let reason: String
            let category: String
            let sure: Int
        }
        let items: [Item]
    }

    static func shape(ids: [String]) -> AnswerShape {
        .object([
            .init("items", "One entry for each app or site, in the order given", .list(of: .object([
                .init("id", "The id given for it", .choice(ids)),
                .init("reason", "Why, in at most ten words, from the evidence", .text),
                .init("category", "Which it is", .choice(["focus", "neutral", "distracting"])),
                .init("sure", "How sure you are, 0 to 100", .number(0...100)),
            ]), count: ids.count...ids.count)),
        ])
    }

    private static func ask(_ batch: [SmartEvidence], model: any OnDeviceModel) async throws -> [Verdict] {
        let ids = batch.indices.map { "a\($0 + 1)" }
        let answer = try await model.respond(Answer.self, instructions: instructions,
                                             prompt: prompt(for: batch, ids: ids), shape: shape(ids: ids))
        var seen = Set<String>()
        return answer.items.compactMap { item in
            guard let index = ids.firstIndex(of: item.id), seen.insert(item.id).inserted,
                  let classification = category(item.category) else { return nil }
            let evidence = batch[index]
            return Verdict(key: evidence.key, classification: classification,
                           sure: min(100, max(0, item.sure)), reason: tidyReason(item.reason, evidence: evidence))
        }
    }

    static func prompt(for batch: [SmartEvidence], ids: [String]) -> String {
        var lines = ["Sort these:"]
        for (id, item) in zip(ids, batch) {
            var parts = ["\(id). \(item.isSite ? "Website" : "App"): \(item.name)"]
            if !item.isSite { parts.append("id \(item.bundleId)") }
            let share = Int((item.sessionShare * 100).rounded())
            parts.append("\(spoken(item.seconds)) in the last week, \(share)% of it in focus sessions")
            if let hours = item.hours { parts.append(hours) }
            if !item.alongside.isEmpty {
                parts.append("used next to " + item.alongside
                    .map { "\($0.name) (\(word($0.classification)))" }.joined(separator: ", "))
            }
            if !item.titles.isEmpty {
                parts.append("titles: " + item.titles.map { "“\($0)”" }.joined(separator: ", "))
            }
            lines.append(parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    static func category(_ word: String) -> Classification? {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "focus":       return .focus
        case "neutral":     return .neutral
        case "distracting": return .distraction
        default:            return nil
        }
    }

    static func word(_ classification: Classification) -> String {
        switch classification {
        case .focus:       return "focus"
        case .neutral:     return "neutral"
        case .distraction: return "distracting"
        }
    }

    /// One short line, starting with a capital, no full stop; the evidence
    /// stands in when the model gave nothing usable.
    static func tidyReason(_ reason: String, evidence: SmartEvidence) -> String {
        var text = reason.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'."))
        if text.count > 80 { text = String(text.prefix(79)) + "…" }
        guard text.count >= 3 else { return fallbackReason(evidence) }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func fallbackReason(_ evidence: SmartEvidence) -> String {
        let time = spoken(evidence.seconds)
        if evidence.sessionShare >= 0.6 { return "\(time) this week, mostly in sessions" }
        if evidence.sessionShare <= 0.2 { return "\(time) this week, mostly outside sessions" }
        return "\(time) this week"
    }

    /// "1h 10m", "42 min".
    static func spoken(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
