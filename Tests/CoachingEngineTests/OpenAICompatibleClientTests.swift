import XCTest
@testable import CoachingEngine
import Store

final class OpenAICompatibleClientTests: XCTestCase {
    func makeClient(apiKey: String = "") -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return OpenAICompatibleClient(baseURL: URL(string: "http://localhost:11434/v1")!,
                                      model: "deepseek-r1:14b", apiKey: apiKey,
                                      session: URLSession(configuration: config))
    }

    /// The round's scored dimensions. Arbitrary here — the client's contract is "require
    /// exactly the keys you were handed", not any particular set.
    static let dims = ["answer_relevance", "structure", "conciseness", "questions_asked"]

    static let goodJSON = """
    {"prose_debrief":"Solid.","scores":{"answer_relevance":4,"structure":3,"conciseness":3,"questions_asked":2},
     "advancement":"lean_no","advancement_rationale":"Never landed a result.",
     "weakness_tags":[],"highlights":[{"t":"00:05:10","note":"good {question}"}],"action_items":["Prep"]}
    """

    // The format appendix's illustrative example object — a weak local model may echo this
    // instead of following it. Built from the real appendix so it stays in sync: if the
    // example's shape drifts, this fixture drifts with it.
    static let exampleObjectJSON: String = {
        let appendix = OpenAICompatibleClient.formatAppendix(dimensions: dims)
        return OpenAICompatibleClient.candidateObjects(in: appendix)
            .compactMap { String(data: $0, encoding: .utf8) }
            .first { $0.contains(OpenAICompatibleClient.exampleProse) }!
    }()

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
        let result = try await makeClient().generateCoaching(systemPrompt: "coach", userMessage: "transcript", dimensions: Self.dims)
        XCTAssertEqual(result.proseDebrief, "Solid.")
        XCTAssertEqual(result.scores["answer_relevance"], 4)
    }

    func testBearerHeaderWhenKeyProvided() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-local")
            return (200, self.envelope(content: Self.goodJSON))
        }
        _ = try await makeClient(apiKey: "sk-local").generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
    }

    func testParsesThinkBlocksAndFences() async throws {
        let wrapped = "<think>hmm {not: json}</think>\nHere you go:\n```json\n\(Self.goodJSON)\n```"
        MockURLProtocol.handler = { _ in (200, self.envelope(content: wrapped)) }
        let result = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
        XCTAssertEqual(result.highlights.first?.note, "good {question}")  // braces inside strings survive
    }

    func testGarbageContentThrowsEmptyResponse() async {
        MockURLProtocol.handler = { _ in (200, self.envelope(content: "I cannot produce JSON, sorry.")) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testHTTPErrorThrows() async {
        MockURLProtocol.handler = { _ in (500, Data("model not found".utf8)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
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
        let result = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
        XCTAssertEqual(result.proseDebrief, "Solid.")
    }

    func testEchoedExampleAloneThrowsEmptyResponse() async {
        // If the model only ever echoes the example (no real answer follows),
        // there is no non-sentinel candidate to return, so the session must
        // fail loudly rather than silently persist the fabricated example.
        MockURLProtocol.handler = { _ in (200, self.envelope(content: Self.exampleObjectJSON)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testWrongScoreKeysRejected() async {
        // scores is [String: Int], so a model returning its own dimensions still DECODES.
        // Nothing but this guard catches it, and accepting it would average dimensions the
        // round never asked for into overallScore.
        MockURLProtocol.handler = { _ in (200, self.envelope(content: Self.goodJSON)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u",
                                                        dimensions: ["correctness", "problem_solving"])
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testOutOfBandScoresRejected() async {
        // A real debrief in the production DB was saved as all-zeros → a 0.0 mean shown as a
        // legitimate result. Neither client's transport enforces the 1-5 band (the API refuses
        // range keywords; local servers get no schema), so the decoder is the only guard.
        let zeros = """
        {"prose_debrief":"Zeroed.","scores":{"answer_relevance":0,"structure":0,"conciseness":0,"questions_asked":0},
         "advancement":"strong_no","advancement_rationale":"r","weakness_tags":[],
         "highlights":[{"t":"00:00:01","note":"n"}],"action_items":["a"]}
        """
        MockURLProtocol.handler = { _ in (200, self.envelope(content: zeros)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u", dimensions: Self.dims)
            XCTFail("expected throw — a 0 score must not persist")
        } catch let e as ClaudeError { XCTAssertEqual(e, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testFormatAppendixListsTheRoundsDimensions() {
        let appendix = OpenAICompatibleClient.formatAppendix(dimensions: ["correctness", "qa_honesty"])
        XCTAssertTrue(appendix.contains("\"correctness\""))
        XCTAssertTrue(appendix.contains("\"qa_honesty\""))
        XCTAssertFalse(appendix.contains("answer_relevance"), "must not leak a hardcoded dimension set")
        // The verdict's legal values have to reach a server that gets no JSON schema.
        for a in Advancement.allCases { XCTAssertTrue(appendix.contains(a.rawValue), a.rawValue) }
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
