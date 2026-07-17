import XCTest
@testable import CoachingEngine

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClaudeClientTests: XCTestCase {
    func makeClient() -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return AnthropicClient(apiKey: "test-key", session: URLSession(configuration: config))
    }

    static let dims = ["answer_relevance", "structure", "conciseness", "questions_asked"]

    static let goodPayload = """
    {"prose_debrief":"Good interview.","scores":{"answer_relevance":4,"structure":2,"conciseness":3,"questions_asked":4},
     "advancement":"lean_yes","advancement_rationale":"Recovered well after the hint.",
     "weakness_tags":["rambling_intro"],"highlights":[{"t":"00:14:22","note":"Strong recovery"}],
     "action_items":["Prep a 90 second intro"]}
    """

    func envelope(text: String, stopReason: String = "end_turn") -> Data {
        let obj: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testParsesStructuredResponse() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            // Verify the request body carries model + structured output config.
            let body = try! JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "claude-opus-4-8")
            XCTAssertNotNil((body["output_config"] as? [String: Any])?["format"])
            return (200, self.envelope(text: Self.goodPayload))
        }
        let result = try await makeClient().generateCoaching(systemPrompt: "coach", userMessage: "transcript", dimensions: Self.dims)
        XCTAssertEqual(result.proseDebrief, "Good interview.")
        XCTAssertEqual(result.scores["structure"], 2)
        XCTAssertEqual(result.weaknessTags, ["rambling_intro"])
        XCTAssertEqual(result.highlights.first?.t, "00:14:22")
        XCTAssertEqual(result.overallScore, 3.25, accuracy: 0.001)
    }

    func testRefusalThrows() async {
        MockURLProtocol.handler = { _ in (200, self.envelope(text: "", stopReason: "refusal")) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .refusal) } catch { XCTFail("\(error)") }
    }

    func testHTTPErrorThrows() async {
        MockURLProtocol.handler = { _ in (429, Data("rate limited".utf8)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
            XCTFail("expected throw")
        } catch let e as ClaudeError {
            XCTAssertEqual(e, .httpStatus(429, body: "rate limited"))
        } catch { XCTFail("\(error)") }
    }

    func testMaxTokensThrowsTruncated() async {
        MockURLProtocol.handler = { _ in (200, self.envelope(text: "{", stopReason: "max_tokens")) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .truncated) } catch { XCTFail("\(error)") }
    }

    func testRequestBodyUsesConfiguredModel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = AnthropicClient(apiKey: "test-key", model: "claude-sonnet-5",
                                     session: URLSession(configuration: config))
        MockURLProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
            return (200, self.envelope(text: Self.goodPayload))
        }
        _ = try await client.generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
    }

    func testThinkingConfigMatchesModelCapability() async throws {
        func thinking(forModel model: String) async throws -> [String: Any] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = AnthropicClient(apiKey: "k", model: model,
                                         session: URLSession(configuration: config))
            var captured: [String: Any] = [:]
            MockURLProtocol.handler = { request in
                let body = try! JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
                captured = body["thinking"] as! [String: Any]
                return (200, self.envelope(text: Self.goodPayload))
            }
            _ = try await client.generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
            return captured
        }
        // Adaptive-capable 4.6+ models send adaptive thinking.
        let opus = try await thinking(forModel: "claude-opus-4-8")
        let sonnet = try await thinking(forModel: "claude-sonnet-5")
        XCTAssertEqual(opus["type"] as? String, "adaptive")
        XCTAssertEqual(sonnet["type"] as? String, "adaptive")
        // Haiku 4.5 rejects adaptive (400); it must get enabled + a budget under max_tokens.
        let haiku = try await thinking(forModel: "claude-haiku-4-5-20251001")
        XCTAssertEqual(haiku["type"] as? String, "enabled")
        XCTAssertEqual(haiku["budget_tokens"] as? Int, 8000)
    }
}

extension URLRequest {
    /// URLProtocol exposes the body only as a stream in some paths; normalize.
    func bodyData() -> Data {
        if let b = httpBody { return b }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 16_384
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
