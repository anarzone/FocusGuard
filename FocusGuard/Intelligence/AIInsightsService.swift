import Foundation

/// Composes the coaching prompt, calls the configured provider, and parses the
/// reply into a short list of tips. Provider-agnostic: it only talks to the
/// `LLMProvider` protocol, so the same flow works for Anthropic, OpenAI, or any
/// OpenAI-compatible endpoint.
enum AIInsightsService {
    static let maxTokens = 500

    private static let systemPrompt = """
    You are a concise, supportive focus coach inside a Mac productivity app. \
    You are given an aggregated summary of the user's focus session data \
    (no raw content, just numbers and app/site names). Reply with 2-3 short, \
    specific, actionable tips to help them focus better tomorrow. One tip per \
    line. No preamble, no numbering, no markdown, no closing remarks — just the \
    tip lines. Keep each tip under 25 words and ground it in the data provided.
    """

    /// Generates tips for the given pre-built summary using the supplied provider.
    static func tips(summary: String, provider: LLMProvider) async throws -> [String] {
        let reply = try await provider.complete(
            system: systemPrompt,
            user: summary,
            maxTokens: maxTokens
        )
        return parseTips(reply)
    }

    /// Splits a reply into clean tip lines: drops empties, strips leading
    /// bullets/numbers, and caps the count so the UI stays tidy.
    static func parseTips(_ reply: String) -> [String] {
        let cleaned = reply
            .components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespaces)
                // Strip common list markers: "- ", "* ", "• ", "1. ", "1) ".
                while let first = s.first, "-*•".contains(first) {
                    s.removeFirst()
                    s = s.trimmingCharacters(in: .whitespaces)
                }
                if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }),
                   s.distance(from: s.startIndex, to: dot) <= 2,
                   s[s.startIndex..<dot].allSatisfy(\.isNumber) {
                    s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .filter { !$0.isEmpty }
        return Array(cleaned.prefix(4))
    }
}
