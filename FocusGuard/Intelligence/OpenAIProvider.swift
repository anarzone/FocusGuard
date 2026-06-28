import Foundation

/// Calls any OpenAI-style Chat Completions API (`POST {baseURL}/v1/chat/completions`
/// with a `Authorization: Bearer` key). The same shape serves OpenAI itself and
/// the many OpenAI-compatible gateways (OpenRouter, Groq, Together, Ollama,
/// LM Studio, …) — only the base URL and model id differ.
struct OpenAIProvider: LLMProvider {
    static let defaultBaseURL = "https://api.openai.com"
    static let defaultModel = "gpt-5"

    let model: String
    let apiKey: String
    /// Origin only, e.g. "https://api.openai.com" or "http://localhost:11434".
    let baseURL: String
    var session: URLSession = .shared

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingCredential }
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/v1/chat/completions") else {
            throw LLMError.badURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            // `max_tokens` is the most broadly accepted field across OpenAI and
            // OpenAI-compatible servers (Ollama, Groq, OpenRouter, LM Studio).
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await HTTPRunner.data(for: req, session: session)
        return try Self.extractText(from: data)
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
