import XCTest
@testable import DebriefEval
import CoachingEngine
import Store

private extension URLRequest {
    /// URLProtocol sees the body as a stream, not httpBody.
    func bodyData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        return data
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Oracle / null / plumbing checks for the harness — no network, in-memory DBs only.
final class DebriefEvalTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var tmp: URL!
    var prompts: PromptStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        prompts = PromptStore(directory: tmp.appendingPathComponent("prompts"))
        try prompts.ensureDefaults()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func fixture(_ id: String) throws -> Fixture {
        try XCTUnwrap(Fixture.load(from: [Self.root.appendingPathComponent("eval/fixtures/synthetic")]).first { $0.id == id })
    }

    func config(status: Int = 200, model: String = "claude-sonnet-5-5", text: String?) -> EvalConfig {
        MockURLProtocol.handler = { _ in
            guard status == 200 else { return (status, Data(#"{"type":"error","error":{"type":"invalid_request_error"}}"#.utf8)) }
            let obj: [String: Any] = ["model": model, "stop_reason": "end_turn",
                                      "content": text.map { [["type": "text", "text": $0]] } ?? [],
                                      "usage": ["input_tokens": 10, "output_tokens": 5]]
            return (200, try! JSONSerialization.data(withJSONObject: obj))
        }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return EvalConfig(models: ["claude-sonnet-5-5"], reps: 1, judgeModel: nil, timeoutS: 30,
                          promptsDir: prompts.directory, outDir: tmp.appendingPathComponent("out"),
                          fixtureDirs: [tmp.appendingPathComponent("fx")], apiKey: "k", session: URLSession(configuration: c))
    }

    /// A hand-built debrief that honours every rule: what a perfect model would return.
    func oracle(_ fx: Fixture) throws -> String {
        let dims = try prompts.dimensions(for: fx.round)
        let ts = fx.segments.prefix(3).map { formatTimestamp($0.tStart) }
        let result = CoachingResult(
            proseDebrief: "Strong yes.", scores: Dictionary(uniqueKeysWithValues: dims.map { ($0, 4) }),
            advancement: .strongYes, advancementRationale: "Quantified results throughout.",
            weaknessTags: [], highlights: ts.map { Highlight(t: $0, note: "good") },
            actionItems: ["Keep doing it"], processNotes: [Highlight(t: ts[0], note: "recruiter follows up")])
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    func testOracleGradesContractAndVerdict() async throws {
        let fx = try fixture("syn-behavioral-strong")
        let outcome = await Runner.runJob(fx, model: "claude-sonnet-5-5", rep: 0, cfg: config(text: try oracle(fx)), prompts: prompts)
        guard case .scored(let row, let trace, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(row.grade["contract"], 1)
        XCTAssertEqual(row.grade["verdict_match"], 1)
        XCTAssertEqual(row.grade["ts_grounded"], 1)
        XCTAssertEqual(row.usage.inputTokens, 10)
        XCTAssertEqual(row.meta.advancement, "strong_yes")
        XCTAssertEqual(trace.map(\.role), ["system", "user", "assistant"])
        XCTAssertTrue(row.prompt.contains("Larkspur Payments"), "the real CoachingService built the user message")
    }

    /// Empty, garbage, and missing-text outputs are graded failures, never crashes or errors.
    func testNullOutputsAreGradedFailures() async throws {
        let fx = try fixture("syn-behavioral-strong")
        for text in ["{}", "not json at all", nil] as [String?] {
            let outcome = await Runner.runJob(fx, model: "claude-sonnet-5-5", rep: 0, cfg: config(text: text), prompts: prompts)
            guard case .scored(let row, _, _, _) = outcome else { return XCTFail("\(String(describing: text)): \(outcome)") }
            XCTAssertEqual(row.grade["contract"], 0)
            XCTAssertEqual(row.grade["verdict_match"], 0, "no verdict is a miss")
        }
    }

    func testServedModelMismatchIsAnError() async throws {
        let fx = try fixture("syn-behavioral-strong")
        let outcome = await Runner.runJob(fx, model: "claude-sonnet-5-5", rep: 0,
                                          cfg: config(model: "claude-haiku-5-5", text: try oracle(fx)), prompts: prompts)
        guard case .failed(let e) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(e.failure_class, "model_mismatch")
        XCTAssertEqual(e.usage?.inputTokens, 10, "billed usage is kept on the error row")
    }

    func testHTTP400LandsInErrorsNotResults() async throws {
        let fxDir = tmp.appendingPathComponent("fx")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.root.appendingPathComponent("eval/fixtures/synthetic/syn-recruiter-weak.json"),
                                         to: fxDir.appendingPathComponent("syn-recruiter-weak.json"))
        let cfg = config(status: 400, text: nil)
        let failures = try await Runner.run(cfg).failed
        XCTAssertEqual(failures, 1)
        let vdir = cfg.outDir.appendingPathComponent("baseline")
        XCTAssertTrue(EvalFiles.rows(vdir).isEmpty)
        let errs = EvalFiles.errors(vdir)
        XCTAssertEqual(errs.map(\.failure_class), ["http_4xx"])
        XCTAssertEqual(errs.first?.retries, 0, "a 400 is not retried")
        // Resume re-runs it: the failed (case, rep) holds no slot in results.jsonl.
        let again = try await Runner.run(cfg).failed
        XCTAssertEqual(again, 1)
        XCTAssertEqual(EvalFiles.errors(vdir).count, 2)
    }

    func testRunWritesRowsTracesAndSummary() async throws {
        let fxDir = tmp.appendingPathComponent("fx")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.root.appendingPathComponent("eval/fixtures/synthetic/syn-behavioral-strong.json"),
                                         to: fxDir.appendingPathComponent("syn-behavioral-strong.json"))
        var cfg = config(text: try oracle(try fixture("syn-behavioral-strong")))
        cfg.reps = 2
        let failures = try await Runner.run(cfg).failed
        XCTAssertEqual(failures, 0)
        let vdir = cfg.outDir.appendingPathComponent("baseline")
        XCTAssertEqual(EvalFiles.rows(vdir).map(\.rep).sorted(), [0, 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: vdir.appendingPathComponent("traces/syn-behavioral-strong_rep1.json").path))
        let again = try await Runner.run(cfg).failed
        XCTAssertEqual(again, 0)
        XCTAssertEqual(EvalFiles.rows(vdir).count, 2, "resume skips (case, rep) already scored")
        let md = Summary.build(out: cfg.outDir, k: 2)
        XCTAssertTrue(md.contains("| contract | 1.00"), md)
        XCTAssertTrue(md.contains("contract pass@2 / pass^2 | 1.00 / 1.00"), md)
    }

    /// A judge failure keeps the billed, scored coach row and logs the judge error separately.
    func testJudgeFailureKeepsScoredRow() async throws {
        let fx = try fixture("syn-behavioral-strong")
        var cfg = config(text: try oracle(fx))
        cfg.judgeModel = "claude-opus-5-5"
        let coach = MockURLProtocol.handler!
        MockURLProtocol.handler = { req in
            let body = try! JSONSerialization.jsonObject(with: req.bodyData()) as! [String: Any]
            return body["model"] as? String == "claude-opus-5-5" ? (400, Data("bad".utf8)) : coach(req)
        }
        let outcome = await Runner.runJob(fx, model: "claude-sonnet-5-5", rep: 0, cfg: cfg, prompts: prompts)
        guard case .scored(let row, _, nil, let judgeError?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(row.grade["contract"], 1)
        XCTAssertNil(row.grade["grounded"])
        XCTAssertEqual(row.meta.judge_error, "http_4xx")
        XCTAssertEqual(judgeError.stage, "judge")
        XCTAssertNil(judgeError.usage, "coach usage stays on the row, not double-counted")
    }

    /// Resume after a judge failure re-runs only the judge — on the persisted debrief — and
    /// rewrites that row in place; the coach call is not billed again.
    func testResumeRejudgesOnlyTheJudge() async throws {
        let fxDir = tmp.appendingPathComponent("fx")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.root.appendingPathComponent("eval/fixtures/synthetic/syn-behavioral-strong.json"),
                                         to: fxDir.appendingPathComponent("syn-behavioral-strong.json"))
        var cfg = config(text: try oracle(try fixture("syn-behavioral-strong")))
        cfg.judgeModel = "claude-opus-5-5"
        let coach = MockURLProtocol.handler!
        nonisolated(unsafe) var coachCalls = 0, judgeOK = false, judgedDebrief = ""
        MockURLProtocol.handler = { req in
            let body = try! JSONSerialization.jsonObject(with: req.bodyData()) as! [String: Any]
            guard body["model"] as? String == "claude-opus-5-5" else { coachCalls += 1; return coach(req) }
            guard judgeOK else { return (400, Data("bad".utf8)) }
            judgedDebrief = ((body["messages"] as! [[String: Any]])[0]["content"] as! String)
            let verdict = Dictionary(uniqueKeysWithValues: JudgeRubric.criteria.map { ($0, ["reason": "r", "satisfied": true]) })
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: verdict), as: UTF8.self)
            return (200, try! JSONSerialization.data(withJSONObject: [
                "model": "claude-opus-5-5", "stop_reason": "end_turn", "content": [["type": "text", "text": text]],
                "usage": ["input_tokens": 7, "output_tokens": 3]] as [String: Any]))
        }
        let first = try await Runner.run(cfg)
        XCTAssertEqual([first.scored, first.judgeErrors, first.failed], [1, 1, 0])
        let vdir = cfg.outDir.appendingPathComponent("baseline")
        let debrief = try XCTUnwrap(EvalFiles.rows(vdir).first?.meta.debrief_json)
        XCTAssertNotNil(EvalFiles.rows(vdir).first?.meta.judge_error)

        judgeOK = true
        let second = try await Runner.run(cfg)
        XCTAssertEqual([second.scored, second.judgeErrors, second.failed], [1, 0, 0])
        XCTAssertEqual(coachCalls, 1, "resume must not re-bill the coach call")
        let rows = EvalFiles.rows(vdir)
        XCTAssertEqual(rows.count, 1, "re-judged row replaced in place, not appended")
        XCTAssertNil(rows[0].meta.judge_error)
        XCTAssertEqual(rows[0].grade["grounded"], 1)
        XCTAssertEqual(rows[0].grade["contract"], 1, "coach grades survive the rewrite")
        XCTAssertEqual(rows[0].judge_usage?.inputTokens, 7)
        XCTAssertTrue(judgedDebrief.contains(debrief), "the judge saw the persisted debrief")
        XCTAssertTrue(Summary.build(out: cfg.outDir, k: 1).contains("| 1 / 0 / 1 / 0 |"), "the judge error is now resolved")

        let third = try await Runner.run(cfg)
        XCTAssertEqual([third.scored, third.judgeErrors, third.failed], [0, 0, 0])
    }

    func testUnknownModelIsUnpricedNotFree() {
        XCTAssertEqual(EvalFiles.price("claude-haiku-4-5-20251001")?.in, 1)
        XCTAssertEqual(EvalFiles.price("claude-opus-5")?.out, 25)
        XCTAssertNil(EvalFiles.price("claude-opus-5-7"), "no neighbouring-family fallback")
        XCTAssertNil(EvalFiles.cost("claude-mystery-1", .init(inputTokens: 10, outputTokens: 5)))
        XCTAssertEqual(EvalFiles.cost("claude-mystery-1", nil), 0, "no usage, nothing billed")
    }

    func testTruncatedIsUngradedAndServedModelMatchIsStrict() async throws {
        let fx = try fixture("syn-behavioral-strong")
        let cfg = config(text: "{")
        let coach = MockURLProtocol.handler!
        MockURLProtocol.handler = { req in
            let (code, data) = coach(req)
            var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            obj["stop_reason"] = "max_tokens"
            return (code, try! JSONSerialization.data(withJSONObject: obj))
        }
        let outcome = await Runner.runJob(fx, model: "claude-sonnet-5-5", rep: 0, cfg: cfg, prompts: prompts)
        guard case .scored(let row, _, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(row.status, "truncated")
        XCTAssertTrue(row.grade.isEmpty)
        XCTAssertTrue(servedMatches("claude-sonnet-5-5-20261001", "claude-sonnet-5-5"))
        XCTAssertFalse(servedMatches("claude-sonnet-5-5", "claude-sonnet-5"))
    }

    func testTimestampGroundingTolerance() {
        XCTAssertTrue(Grader.isGrounded("00:00:25", in: [20]))
        XCTAssertTrue(Grader.isGrounded("[00:00:15]", in: [20]))
        XCTAssertFalse(Grader.isGrounded("00:00:26", in: [20]))
        XCTAssertTrue(Grader.isGrounded("14:22", in: [862]))
        XCTAssertFalse(Grader.isGrounded("around the middle", in: [20]))
        XCTAssertEqual(Grader.seconds("01:02:03"), 3723)
    }

    func testPassAtKAndPassHatK() {
        XCTAssertEqual(Stats.passAtK(n: 5, c: 0, k: 5), 0)
        XCTAssertEqual(Stats.passAtK(n: 5, c: 1, k: 5), 1)
        XCTAssertEqual(Stats.passHatK(n: 5, c: 5, k: 5), 1)
        XCTAssertEqual(Stats.passHatK(n: 5, c: 4, k: 5), 0, "pass^k: one failing rep fails the case")
        XCTAssertEqual(Stats.passAtK(n: 5, c: 2, k: 2), 0.7, accuracy: 1e-9)   // 1 - C(3,2)/C(5,2)
        XCTAssertEqual(Stats.passHatK(n: 5, c: 3, k: 2), 0.3, accuracy: 1e-9)  // C(3,2)/C(5,2)
        let ci = Stats.wilson(0, 10)
        XCTAssertEqual(ci.lo, 0)
        XCTAssertGreaterThan(ci.hi, 0.2)
        XCTAssertEqual(Stats.kappa([1, 0, 1, 0], [1, 0, 1, 0]), 1)
    }
}
