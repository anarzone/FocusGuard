import XCTest
@testable import FocusGuard

/// Captures the outgoing request and returns a canned response, so provider
/// tests assert header/URL/body construction and response parsing without
/// touching the network.
final class StubURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    /// The request body as JSON. URLSession hands it over as a stream.
    static var lastBodyJSON: [String: Any]?
    static var responseBody = Data()
    static var statusCode = 200

    static func reset() {
        lastRequest = nil
        lastBodyJSON = nil
        responseBody = Data()
        statusCode = 200
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lastRequest = request
        StubURLProtocol.lastBodyJSON = Self.bodyData(of: request)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: StubURLProtocol.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StubURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ProviderRequestTests: XCTestCase {
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func test_anthropic_apiKey_setsXApiKeyHeader() async throws {
        StubURLProtocol.responseBody = #"{"content":[{"type":"text","text":"hello tips"}]}"#.data(using: .utf8)!
        let provider = AnthropicProvider(model: "claude-sonnet-4-6",
                                         apiKey: "sk-test-123",
                                         session: stubbedSession())
        let text = try await provider.complete(system: "s", user: "u", maxTokens: 10)

        XCTAssertEqual(text, "hello tips")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-test-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func test_openAI_hitsChatCompletionsWithBearer() async throws {
        StubURLProtocol.responseBody = #"{"choices":[{"message":{"role":"assistant","content":"tip a\ntip b"}}]}"#.data(using: .utf8)!
        let provider = OpenAIProvider(model: "gpt-test", apiKey: "key-9",
                                      baseURL: "https://api.openai.com",
                                      session: stubbedSession())
        let text = try await provider.complete(system: "s", user: "u", maxTokens: 10)

        XCTAssertEqual(text, "tip a\ntip b")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer key-9")
    }

    func test_openAICompatible_usesCustomBaseURL() async throws {
        StubURLProtocol.responseBody = #"{"choices":[{"message":{"content":"x"}}]}"#.data(using: .utf8)!
        let provider = OpenAIProvider(model: "llama3", apiKey: "local",
                                      baseURL: "http://localhost:11434/",   // trailing slash trimmed
                                      session: stubbedSession())
        _ = try await provider.complete(system: "s", user: "u", maxTokens: 10)

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func test_httpError_surfacesProviderMessage() async {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseBody = #"{"error":{"message":"invalid x-api-key"}}"#.data(using: .utf8)!
        let provider = AnthropicProvider(model: "m", apiKey: "bad",
                                         session: stubbedSession())
        do {
            _ = try await provider.complete(system: "s", user: "u", maxTokens: 10)
            XCTFail("expected an error")
        } catch let error as LLMError {
            guard case .http(let status, let body) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("invalid x-api-key"))
        } catch {
            XCTFail("expected LLMError, got \(error)")
        }
    }

    func test_emptyCredential_throwsMissingCredential() async {
        let provider = AnthropicProvider(model: "m", apiKey: "", session: stubbedSession())
        do {
            _ = try await provider.complete(system: "s", user: "u", maxTokens: 10)
            XCTFail("expected an error")
        } catch let error as LLMError {
            guard case .missingCredential = error else {
                return XCTFail("expected .missingCredential, got \(error)")
            }
        } catch {
            XCTFail("expected LLMError, got \(error)")
        }
    }

    func test_openAI_sendsMaxCompletionTokensWithRoomToReason() async throws {
        StubURLProtocol.responseBody = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
        let provider = OpenAIProvider(model: "gpt-5", apiKey: "key-9",
                                      baseURL: OpenAIProvider.defaultBaseURL,
                                      session: stubbedSession())
        _ = try await provider.complete(system: "s", user: "u", maxTokens: 5)

        let body = try XCTUnwrap(StubURLProtocol.lastBodyJSON)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, OpenAIProvider.reasoningTokenFloor)
        XCTAssertNil(body["max_tokens"])
    }

    func test_openAICompatible_sendsMaxTokens() async throws {
        StubURLProtocol.responseBody = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
        let provider = OpenAIProvider(model: "llama3", apiKey: "k",
                                      baseURL: "https://openrouter.ai/api",
                                      session: stubbedSession())
        _ = try await provider.complete(system: "s", user: "u", maxTokens: 500)

        let body = try XCTUnwrap(StubURLProtocol.lastBodyJSON)
        XCTAssertEqual(body["max_tokens"] as? Int, 500)
        XCTAssertNil(body["max_completion_tokens"])
    }

    func test_localServer_worksWithoutAKey() async throws {
        StubURLProtocol.responseBody = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
        let provider = OpenAIProvider(model: "llama3", apiKey: "",
                                      baseURL: "http://localhost:11434",
                                      session: stubbedSession())
        let text = try await provider.complete(system: "s", user: "u", maxTokens: 10)

        XCTAssertEqual(text, "ok")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func test_remoteServer_withoutAKey_throwsMissingCredential() async {
        let provider = OpenAIProvider(model: "m", apiKey: "",
                                      baseURL: "https://openrouter.ai/api",
                                      session: stubbedSession())
        do {
            _ = try await provider.complete(system: "s", user: "u", maxTokens: 10)
            XCTFail("expected an error")
        } catch let error as LLMError {
            guard case .missingCredential = error else {
                return XCTFail("expected .missingCredential, got \(error)")
            }
        } catch {
            XCTFail("expected LLMError, got \(error)")
        }
    }

    func test_isLocalEndpoint() {
        func settings(_ provider: ProviderKind, _ baseURL: String) -> AISettings {
            AISettings(enabled: true, provider: provider, model: "m", baseURL: baseURL)
        }
        XCTAssertTrue(settings(.openAICompatible, "http://localhost:11434").isLocalEndpoint)
        XCTAssertTrue(settings(.openAICompatible, "http://127.0.0.1:1234/").isLocalEndpoint)
        XCTAssertTrue(settings(.openAICompatible, "http://[::1]:11434").isLocalEndpoint)
        XCTAssertFalse(settings(.openAICompatible, "https://openrouter.ai/api").isLocalEndpoint)
        XCTAssertFalse(settings(.openAI, "http://localhost:11434").isLocalEndpoint)
    }
}
