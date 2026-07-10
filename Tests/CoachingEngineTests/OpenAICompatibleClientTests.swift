import XCTest
@testable import CoachingEngine

final class OpenAICompatibleClientTests: XCTestCase {
    func makeClient(apiKey: String = "") -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return OpenAICompatibleClient(baseURL: URL(string: "http://localhost:11434/v1")!,
                                      model: "deepseek-r1:14b", apiKey: apiKey,
                                      session: URLSession(configuration: config))
    }

    static let goodJSON = """
    {"prose_debrief":"Solid.","scores":{"answer_relevance":4,"structure":3,"conciseness":3,"questions_asked":2},
     "weakness_tags":[],"highlights":[{"t":"00:05:10","note":"good {question}"}],"action_items":["Prep"]}
    """

    // The format appendix's illustrative example object, verbatim — a weak
    // local model may echo this instead of following it.
    static let exampleObjectJSON = """
    {
      "prose_debrief": "The 300-600 word markdown debrief.",
      "scores": {"answer_relevance": 4, "structure": 3, "conciseness": 3, "questions_asked": 2},
      "weakness_tags": ["rambling_intro"],
      "highlights": [{"t": "00:14:32", "note": "Strong recovery after the hint"}],
      "action_items": ["Prep a 90-second intro"]
    }
    """

    func envelope(content: String) -> Data {
        try! JSONSerialization.data(withJSONObject:
            ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    func testRequestShapeAndPlainJSONResponse() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))  // no key → no header
            let body = try! JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "deepseek-r1:14b")
            let messages = body["messages"] as! [[String: String]]
            XCTAssertEqual(messages[0]["role"], "system")
            XCTAssertTrue(messages[0]["content"]!.contains("ONLY a single JSON object"))  // format appendix
            XCTAssertTrue(messages[0]["content"]!.hasPrefix("coach"))  // original prompt first
            XCTAssertEqual(messages[1], ["role": "user", "content": "transcript"])
            return (200, self.envelope(content: Self.goodJSON))
        }
        let result = try await makeClient().generateCoaching(systemPrompt: "coach", userMessage: "transcript")
        XCTAssertEqual(result.proseDebrief, "Solid.")
        XCTAssertEqual(result.scores["answer_relevance"], 4)
    }

    func testBearerHeaderWhenKeyProvided() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-local")
            return (200, self.envelope(content: Self.goodJSON))
        }
        _ = try await makeClient(apiKey: "sk-local").generateCoaching(systemPrompt: "s", userMessage: "u")
    }

    func testParsesThinkBlocksAndFences() async throws {
        let wrapped = "<think>hmm {not: json}</think>\nHere you go:\n```json\n\(Self.goodJSON)\n```"
        MockURLProtocol.handler = { _ in (200, self.envelope(content: wrapped)) }
        let result = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
        XCTAssertEqual(result.highlights.first?.note, "good {question}")  // braces inside strings survive
    }

    func testGarbageContentThrowsEmptyResponse() async {
        MockURLProtocol.handler = { _ in (200, self.envelope(content: "I cannot produce JSON, sorry.")) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testHTTPErrorThrows() async {
        MockURLProtocol.handler = { _ in (500, Data("model not found".utf8)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .httpStatus(500, body: "model not found")) }
        catch { XCTFail("\(error)") }
    }

    func testEchoedExampleBeforeRealAnswerReturnsRealResult() async throws {
        // A weak local model echoes the appendix's example object before its
        // actual answer ("Here is the shape: {example} ... now my analysis:
        // {real}"). The example must decode, but its prose is the sentinel,
        // so generateCoaching should keep scanning and return the real result.
        let content = """
        Here is the shape: \(Self.exampleObjectJSON)
        Now my analysis:
        \(Self.goodJSON)
        """
        MockURLProtocol.handler = { _ in (200, self.envelope(content: content)) }
        let result = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
        XCTAssertEqual(result.proseDebrief, "Solid.")
    }

    func testEchoedExampleAloneThrowsEmptyResponse() async {
        // If the model only ever echoes the example (no real answer follows),
        // there is no non-sentinel candidate to return, so the session must
        // fail loudly rather than silently persist the fabricated example.
        MockURLProtocol.handler = { _ in (200, self.envelope(content: Self.exampleObjectJSON)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testCandidateObjectsEdgeCases() {
        // Unclosed think tag: the tag isn't stripped, so a brace fragment inside
        // the un-terminated reasoning can still be extracted here (accepted
        // residual gap — it fails to decode downstream and the session is
        // marked failed and retryable).
        XCTAssertNil(OpenAICompatibleClient.candidateObjects(in: "no braces here").first)
        XCTAssertNil(OpenAICompatibleClient.candidateObjects(in: "{\"unterminated\": ").first)
        let s = String(data: OpenAICompatibleClient.candidateObjects(in: "prefix {\"a\": \"b}\"} suffix").first!,
                       encoding: .utf8)
        XCTAssertEqual(s, "{\"a\": \"b}\"}")
        let esc = String(data: OpenAICompatibleClient.candidateObjects(in: #"{"a": "quote \" brace }"}"#).first!,
                         encoding: .utf8)
        XCTAssertEqual(esc, #"{"a": "quote \" brace }"}"#)
    }

    func testCandidateObjectsWithMalformedThinkMarkers() {
        // Stray/nested think markers make span-stripping return leftover
        // reasoning fragments; extracting from after the LAST </think> instead
        // finds the real payload.
        let nested = "<think>outer {a:1} <think>inner</think> still thinking {b:2}</think>\n{\"real\":\"json\"}"
        let nestedResult = String(data: OpenAICompatibleClient.candidateObjects(in: nested).first!, encoding: .utf8)
        XCTAssertEqual(nestedResult, #"{"real":"json"}"#)

        // Well-formed sequential think blocks with the JSON payload after both.
        let sequential = "<think>a</think> x <think>b</think> {\"real\":\"json\"}"
        let sequentialResult = String(data: OpenAICompatibleClient.candidateObjects(in: sequential).first!, encoding: .utf8)
        XCTAssertEqual(sequentialResult, #"{"real":"json"}"#)
    }
}
