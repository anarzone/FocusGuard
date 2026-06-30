import Foundation

/// Calls Anthropic's Messages API (`POST /v1/messages`) with a console API key
/// (`x-api-key`). Subscription / OAuth tokens are intentionally not supported —
/// Anthropic gates and rate-limits those to its own clients (Claude Code), so
/// they're unreliable from a third-party app.
struct AnthropicProvider: LLMProvider {
    static let defaultModel = "claude-sonnet-4-6"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let version = "2023-06-01"

    let model: String
    let apiKey: String
    var session: URLSession = .shared

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingCredential }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await HTTPRunner.data(for: req, session: session)
        return try Self.extractText(from: data)
    }

    /// Concatenates every `text` block in the `content` array.
    static func extractText(from data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("not JSON")
        }
        guard let content = obj["content"] as? [[String: Any]] else {
            throw LLMError.decoding("missing content")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}
