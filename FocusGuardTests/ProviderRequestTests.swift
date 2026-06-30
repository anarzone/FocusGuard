import XCTest
@testable import FocusGuard

/// Captures the outgoing request and returns a canned response, so provider
/// tests assert header/URL/body construction and response parsing without
/// touching the network.
final class StubURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var responseBody = Data()
    static var statusCode = 200

    static func reset() {
        lastRequest = nil
        responseBody = Data()
        statusCode = 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lastRequest = request
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
}
