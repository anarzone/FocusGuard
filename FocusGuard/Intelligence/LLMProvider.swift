import Foundation

/// A minimal text-completion interface the insights feature talks to. Concrete
/// implementations wrap a specific HTTP API (Anthropic, OpenAI, …) but the
/// caller only ever sees `complete(...)`. Kept deliberately tiny — the feature
/// needs one single-shot, non-streaming completion.
protocol LLMProvider: Sendable {
    /// Sends one system+user prompt and returns the model's text reply.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

enum LLMError: LocalizedError {
    case missingCredential
    case badURL
    case http(status: Int, body: String)
    case emptyResponse
    case decoding(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "No API key or token is set for the selected provider."
        case .badURL:
            return "The provider endpoint URL is invalid."
        case .http(let status, let body):
            // Rate limiting is common with subscription tokens (much stricter
            // limits than API keys) — give an actionable message rather than raw JSON.
            if status == 429 {
                return "Rate limited (HTTP 429). The provider is throttling requests — wait a minute and try again. Subscription tokens have much lower limits than API keys."
            }
            // Otherwise surface the provider's own error — usually actionable
            // (bad key, model not found). Trim so the UI stays sane.
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = detail.count > 300 ? String(detail.prefix(300)) + "…" : detail
            return "Request failed (HTTP \(status)).\(snippet.isEmpty ? "" : " \(snippet)")"
        case .emptyResponse:
            return "The model returned an empty response."
        case .decoding(let what):
            return "Couldn't read the response (\(what))."
        case .network(let err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

/// Shared helper: run a prepared request on the injected session and return the
/// raw `Data`, mapping non-2xx and transport failures into `LLMError`.
enum HTTPRunner {
    static func data(for request: URLRequest, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMError.decoding("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw LLMError.http(status: http.statusCode,
                                    body: String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.network(error)
        }
    }
}
