import Foundation

/// Calls any OpenAI-style Chat Completions API (`POST {baseURL}/v1/chat/completions`
/// with a `Authorization: Bearer` key). The same shape serves OpenAI itself and
/// the many OpenAI-compatible gateways (OpenRouter, Groq, Together, Ollama,
/// LM Studio, …) — only the base URL and model id differ. A server on this
/// Mac may go without a key.
struct OpenAIProvider: LLMProvider {
    static let defaultBaseURL = "https://api.openai.com"
    static let defaultModel = "gpt-5"
    /// OpenAI's reasoning models (gpt-5, o-series) count their thinking
    /// against the token cap, so a small cap leaves nothing for the reply.
    static let reasoningTokenFloor = 2048

    let model: String
    let apiKey: String
    /// Origin only, e.g. "https://api.openai.com" or "http://localhost:11434".
    let baseURL: String
    var session: URLSession = .shared

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty || Self.isLocal(baseURL) else { throw LLMError.missingCredential }
        guard let url = URL(string: "\(Self.origin(baseURL))/v1/chat/completions") else {
            throw LLMError.badURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if url.host()?.lowercased() == "api.openai.com" {
            // OpenAI's own API takes `max_completion_tokens`; its reasoning
            // models reject `max_tokens` outright.
            body["max_completion_tokens"] = max(maxTokens, Self.reasoningTokenFloor)
        } else {
            // `max_tokens` is what OpenAI-compatible servers accept (Ollama,
            // Groq, OpenRouter, LM Studio).
            body["max_tokens"] = maxTokens
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await HTTPRunner.data(for: req, session: session)
        return try Self.extractText(from: data)
    }

    private static func origin(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Whether `baseURL` points at this Mac (Ollama, LM Studio, …).
    static func isLocal(_ baseURL: String) -> Bool {
        guard let host = URL(string: origin(baseURL))?.host()?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "::1" || host.hasPrefix("127.")
    }

    static func extractText(from data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("not JSON")
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.decoding("missing choices[0].message.content")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}
