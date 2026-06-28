import Foundation

/// Calls Anthropic's Messages API (`POST /v1/messages`). Supports two auth modes:
///
/// - `.apiKey`: a console API key sent via the `x-api-key` header.
/// - `.subscription`: an OAuth token from Claude's `claude setup-token`, sent as
///   `Authorization: Bearer …` plus the `anthropic-beta: oauth-2025-04-20`
///   header — the same mechanism Claude Code uses for Pro/Max subscriptions.
struct AnthropicProvider: LLMProvider {
    enum Auth: Sendable {
        case apiKey(String)
        case subscription(token: String)
    }

    static let defaultModel = "claude-sonnet-4-6"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let version = "2023-06-01"

    let model: String
    let auth: Auth
    var session: URLSession = .shared

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.version, forHTTPHeaderField: "anthropic-version")

        switch auth {
        case .apiKey(let key):
            guard !key.isEmpty else { throw LLMError.missingCredential }
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case .subscription(let token):
            guard !token.isEmpty else { throw LLMError.missingCredential }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }

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
