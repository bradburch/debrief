import Foundation
import CryptoKit
import Store
import CoachingEngine

// Row/trace shapes are the hillclimb report contract (SCHEMA.md), so property names are the
// snake_case JSON keys — same convention as ClaudeClient's response Envelope.

struct Turn: Codable {
    let role: String
    let content: String
    var thinking: String? = nil
}

struct ResultRow: Codable {
    var prompt_id: String
    var rep: Int
    var prompt: String
    var tags: [String]
    var model: String
    var usage: ResponseMeta.Usage
    var latency_s: Double
    var stop_reason: String?
    /// "ok" or "truncated" — truncated rows carry no grade and stay out of every mean.
    var status: String
    var grade: [String: Double]
    var explanation: [String: String]?
    var judge_model: String?
    var judge_usage: ResponseMeta.Usage?
    var meta: Meta

    struct Meta: Codable {
        var requested_model: String
        var round_type: String
        var prompt_hash: String
        var schema_hash: String
        var harness_sha: String
        var rep: Int
        var retries: Int
        var judge_retries: Int?
        /// The stored verdict (nil if none), for precision/recall in the summary.
        var advancement: String?
        /// Set when the judge failed on this row (details in errors.jsonl, stage "judge").
        /// A later run re-judges just this row; the coach call is not repeated.
        var judge_error: String?
        /// The debrief exactly as the judge sees it (`Runner.debriefJSON`), so a re-judge and
        /// the labelling sheet use the judged input, never the raw model text.
        var debrief_json: String? = nil
    }
}

/// An attempt that produced nothing scorable. Never in results.jsonl, so resume re-runs it.
struct ErrorRow: Codable {
    var prompt_id: String
    var rep: Int
    var failure_class: String
    var stage: String
    var error: String
    var retries: Int
    var requested_model: String
    var model: String?
    var usage: ResponseMeta.Usage?
    var judge_model: String?
    var judge_usage: ResponseMeta.Usage?
    var latency_s: Double
}

struct EvalConfig: Sendable {
    var models: [String]
    var reps: Int
    var casePatterns: [String] = []
    var judgeModel: String?
    var judgeReps: Int = 1
    var concurrency: Int = 4
    var timeoutS: Double = 300
    var promptsDir: URL
    var outDir: URL
    var fixtureDirs: [URL]
    var harnessSHA: String = ""
    var apiKey: String = ""
    var session: URLSession = .shared
}

/// Exact id, or the alias resolved to a dated snapshot (`…-20261001`). A bare prefix match
/// would let `claude-sonnet-5` accept a served `claude-sonnet-5-5`.
func servedMatches(_ served: String, _ requested: String) -> Bool {
    served == requested || served.range(of: "^\(NSRegularExpression.escapedPattern(for: requested))-\\d{8}$",
                                        options: .regularExpression) != nil
}

func variantName(_ i: Int) -> String { i == 0 ? "baseline" : "v\(i)" }

func sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// What the real CoachingService handed the model, plus what came back.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var _meta: ResponseMeta?
    private var _request: (system: String, user: String, dims: [String])?
    var meta: ResponseMeta? { lock.withLock { _meta } }
    var request: (system: String, user: String, dims: [String])? { lock.withLock { _request } }
    func set(_ m: ResponseMeta) { lock.withLock { _meta = m } }
    func set(system: String, user: String, dims: [String]) { lock.withLock { _request = (system, user, dims) } }
}

/// Delegates to the real AnthropicClient; only observes and adds backoff on transient errors.
struct CapturingLLM: CoachingLLM {
    let client: AnthropicClient
    let capture: Capture
    let retries: RetryCounter

    func generateCoaching(systemPrompt: String, userMessage: String, dimensions: [String]) async throws -> CoachingResult {
        capture.set(system: systemPrompt, user: userMessage, dims: dimensions)
        return try await withBackoff(retries) {
            try await client.generateCoaching(systemPrompt: systemPrompt, userMessage: userMessage, dimensions: dimensions)
        }
    }
}

struct CeilingExceeded: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "exceeded \(Int(seconds))s wall-clock ceiling" }
}

/// Hard wall-clock ceiling. The loser is cancelled; URLSession calls honour that promptly.
func withCeiling<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds > 0 else { return try await op() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: op)
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CeilingExceeded(seconds: seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

enum Runner {
    enum Outcome {
        /// `judgeError`: the debrief scored but the judge failed. The row is kept (no judge
        /// metrics) so resume doesn't re-bill the coach call; the judge failure is logged.
        case scored(ResultRow, trace: [Turn], judgeTrace: [Turn]?, judgeError: ErrorRow? = nil)
        /// A resumed row whose judge had failed, judged again; rewritten in place in results.jsonl.
        case rejudged(ResultRow, judgeTrace: [Turn]?, judgeError: ErrorRow?)
        case failed(ErrorRow)
    }

    /// `scored` rows were written (new or re-judged); `judgeErrors` of them have no judge
    /// metrics; `failed` coaching attempts produced no row. Only `failed` exits 1.
    struct Counts { var scored = 0, judgeErrors = 0, failed = 0 }

    static func traceName(_ row: ResultRow) -> String { "\(row.prompt_id)_rep\(row.rep).json" }

    /// nil = the model produced output, so this is a graded outcome (contract 0, refused, …),
    /// not plumbing. Everything else goes to errors.jsonl.
    static func failureClass(_ e: Error, meta: ResponseMeta?) -> String? {
        switch e {
        case is CeilingExceeded, is CancellationError: return "timeout"
        case ClaudeError.httpStatus(let code, _): return code >= 500 ? "http_5xx" : "http_4xx"
        case let u as URLError: return u.code == .timedOut || u.code == .cancelled ? "timeout" : "transport"
        case ClaudeError.refusal, ClaudeError.truncated, ClaudeError.emptyResponse, is DecodingError:
            // A 200 whose content broke the contract is the model's failure; an envelope we
            // couldn't even decode (no meta) is the harness's.
            return meta != nil ? nil : "decode"
        default: return "harness"
        }
    }

    static func schemaHash(_ dims: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: AnthropicClient.outputSchema(dimensions: dims),
                                               options: [.sortedKeys])
        return sha256(String(decoding: data, as: UTF8.self))
    }

    /// Fixtures to run, after `--cases` and dropping transcript-only round types (which
    /// coach() skips without a model call, so there is nothing to grade).
    static func plannedFixtures(_ cfg: EvalConfig, _ prompts: PromptStore) throws -> [Fixture] {
        try Fixture.load(from: cfg.fixtureDirs)
            .filter { Fixture.matches($0.id, patterns: cfg.casePatterns) }
            .filter { !prompts.isTranscriptOnly($0.round) }
    }

    /// The end-state debrief as the app stored it — what the judge grades.
    static func debriefJSON(_ d: SessionDetail) -> String {
        guard let f = d.feedback else { return "{}" }
        func parse(_ s: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) ?? [] }
        let obj: [String: Any] = [
            "prose_debrief": f.proseDebrief, "scores": parse(f.scoresJSON),
            "advancement": f.advancement, "advancement_rationale": f.advancementRationale,
            "weakness_tags": d.tags, "highlights": parse(f.highlightsJSON),
            "action_items": parse(f.actionItemsJSON), "process_notes": parse(f.processNotesJSON),
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func runJob(_ fx: Fixture, model: String, rep: Int, cfg: EvalConfig, prompts: PromptStore) async -> Outcome {
        let t0 = Date()
        let capture = Capture(), retries = RetryCounter()
        func failed(_ cls: String, _ stage: String, _ error: Any) -> Outcome {
            let m = capture.meta
            return .failed(ErrorRow(prompt_id: fx.id, rep: rep, failure_class: cls, stage: stage,
                                    error: String(describing: error).prefix(2000).description,
                                    retries: retries.count, requested_model: model,
                                    model: m?.model, usage: m?.usage, judge_model: nil,
                                    judge_usage: nil, latency_s: Date().timeIntervalSince(t0)))
        }

        // Fresh in-memory DB per (case, model, rep): empty history, nothing shared, nothing
        // persisted. The real app DB is never opened.
        let db: AppDatabase, sessionId: Int64
        do {
            db = try AppDatabase.inMemory()
            let company = try db.fetchOrCreateCompany(named: fx.company)
            sessionId = try db.insertSession(InterviewSession(
                id: nil, companyId: company.id!, roundType: fx.round,
                date: Date(timeIntervalSince1970: 1_790_000_000), durationSeconds: fx.durationSeconds,
                contextNotes: fx.contextNotes, coachingStatus: .pending)).id!
            try db.insertSegments(fx.segments.map {
                TranscriptSegmentRecord(id: nil, sessionId: sessionId, speaker: $0.speaker, tStart: $0.tStart, text: $0.text)
            })
        } catch { return failed("harness", "setup", error) }

        let client = AnthropicClient(apiKey: cfg.apiKey, model: model, session: cfg.session,
                                     onResponse: { capture.set($0) })
        let service = CoachingService(db: db, prompts: prompts,
                                      llm: CapturingLLM(client: client, capture: capture, retries: retries))
        var thrown: Error?
        do { try await withCeiling(cfg.timeoutS) { try await service.coach(sessionId: sessionId) } }
        catch { thrown = error }

        let meta = capture.meta
        if let thrown, let cls = failureClass(thrown, meta: meta) { return failed(cls, "coach", thrown) }
        guard let meta, let req = capture.request else { return failed("harness", "coach", "coach() never called the model") }
        guard servedMatches(meta.model, model) else {
            return failed("model_mismatch", "coach", "served \(meta.model.isEmpty ? "<none>" : meta.model), asked \(model)")
        }
        guard let detail = try? db.sessionDetail(id: sessionId) else { return failed("harness", "readback", "session vanished") }

        let truncated = meta.stopReason == "max_tokens"
        let grade = truncated ? [:] : Grader.grade(
            fx, dimensions: req.dims,
            state: EndState(status: detail.session.coachingStatus, feedback: detail.feedback, segments: detail.segments),
            refused: meta.stopReason == "refusal")
        var row = ResultRow(
            prompt_id: fx.id, rep: rep, prompt: req.user, tags: [fx.roundType, fx.source, fx.outcomeLabel],
            model: meta.model, usage: meta.usage, latency_s: meta.latency, stop_reason: meta.stopReason,
            status: truncated ? "truncated" : "ok", grade: grade,
            meta: .init(requested_model: model, round_type: fx.roundType, prompt_hash: sha256(req.system),
                        schema_hash: schemaHash(req.dims), harness_sha: cfg.harnessSHA, rep: rep,
                        retries: retries.count, advancement: detail.feedback?.advancement,
                        debrief_json: truncated || detail.feedback == nil ? nil : debriefJSON(detail)))
        let trace = [Turn(role: "system", content: req.system), Turn(role: "user", content: req.user),
                     Turn(role: "assistant", content: meta.text ?? "", thinking: meta.thinking)]

        var judgeTrace: [Turn]?, judgeError: ErrorRow?
        if let judgeModel = cfg.judgeModel, rep < cfg.judgeReps, let debrief = row.meta.debrief_json {
            (judgeTrace, judgeError) = await judgeRow(&row, coachRubric: req.system, debrief: debrief,
                                                      judgeModel: judgeModel, cfg: cfg, t0: t0)
        }
        return .scored(row, trace: trace, judgeTrace: judgeTrace, judgeError: judgeError)
    }

    /// Judges a scored row in place: success merges the judge metrics and clears
    /// `judge_error`; failure sets it and returns the error row. The first run and resume's
    /// re-judge both come through here, so the judge gets identical input either way.
    static func judgeRow(_ row: inout ResultRow, coachRubric: String, debrief: String, judgeModel: String,
                         cfg: EvalConfig, t0: Date) async -> (trace: [Turn]?, error: ErrorRow?) {
        let judge = Judge(apiKey: cfg.apiKey, model: judgeModel, session: cfg.session)
        let judgeRetries = RetryCounter()
        // The coach's own user message: metadata + candidate notes (level) + transcript.
        let transcript = row.prompt, roundType = row.meta.round_type
        do {
            let v = try await withCeiling(cfg.timeoutS) {
                try await withBackoff(judgeRetries) {
                    try await judge.judge(roundType: roundType, coachRubric: coachRubric,
                                          transcript: transcript, debrief: debrief)
                }
            }
            row.grade.merge(v.grade) { $1 }
            row.explanation = v.explanation
            row.judge_model = v.model
            row.judge_usage = v.usage
            row.meta.judge_retries = judgeRetries.count
            row.meta.judge_error = nil
            return ([Turn(role: "system", content: JudgeRubric.system),
                     Turn(role: "user", content: JudgeRubric.userMessage(
                        roundType: roundType, coachRubric: coachRubric, transcript: transcript, debrief: debrief)),
                     Turn(role: "assistant", content: v.raw)], nil)
        } catch {
            // Coach usage stays on the row; only the judge's billed usage goes here.
            let f = error as? Judge.Failure
            let cls = f.map { $0.message.hasPrefix("model_mismatch") ? "model_mismatch" : "decode" }
                ?? failureClass(error, meta: nil) ?? "harness"
            row.meta.judge_error = cls
            return (nil, ErrorRow(prompt_id: row.prompt_id, rep: row.rep, failure_class: cls, stage: "judge",
                                  error: String(describing: error).prefix(2000).description,
                                  retries: judgeRetries.count, requested_model: row.meta.requested_model,
                                  model: nil, usage: nil, judge_model: f?.model ?? judgeModel, judge_usage: f?.usage,
                                  latency_s: Date().timeIntervalSince(t0)))
        }
    }

    /// Resume path for a row whose judge failed: re-runs only the judge, on the persisted
    /// debrief and the trace's coach rubric. The coach call is never repeated.
    static func rejudge(_ row: ResultRow, vdir: URL, judgeModel: String, cfg: EvalConfig) async -> Outcome {
        let t0 = Date()
        var row = row
        let system = (try? Data(contentsOf: vdir.appendingPathComponent("traces/\(traceName(row))")))
            .flatMap { try? JSONDecoder().decode([Turn].self, from: $0) }?.first { $0.role == "system" }?.content
        guard let debrief = row.meta.debrief_json, let system, sha256(system) == row.meta.prompt_hash else {
            row.meta.judge_error = "harness"
            return .rejudged(row, judgeTrace: nil, judgeError: ErrorRow(
                prompt_id: row.prompt_id, rep: row.rep, failure_class: "harness", stage: "judge",
                error: "can't re-judge: no persisted judge input (meta.debrief_json + trace system prompt matching prompt_hash)",
                retries: 0, requested_model: row.meta.requested_model, model: nil, usage: nil,
                judge_model: nil, judge_usage: nil, latency_s: 0))
        }
        let (trace, error) = await judgeRow(&row, coachRubric: system, debrief: debrief, judgeModel: judgeModel, cfg: cfg, t0: t0)
        return .rejudged(row, judgeTrace: trace, judgeError: error)
    }

    enum Job { case coach(Fixture, model: Int, rep: Int), rejudge(ResultRow, model: Int) }

    /// Runs every pending (case, model, rep), and re-judges every row whose judge failed,
    /// writing each row as it lands.
    @discardableResult
    static func run(_ cfg: EvalConfig) async throws -> Counts {
        let prompts = PromptStore(directory: cfg.promptsDir)
        let fixtures = try plannedFixtures(cfg, prompts)
        try EvalFiles.refreshState(cfg)

        var jobs: [Job] = []
        for (i, model) in cfg.models.enumerated() {
            let vdir = cfg.outDir.appendingPathComponent(variantName(i))
            try FileManager.default.createDirectory(at: vdir.appendingPathComponent("traces"), withIntermediateDirectories: true)
            if i > 0 { try EvalFiles.writeChangeIfAbsent(vdir, model: model, baseline: cfg.models[0]) }
            let rows = EvalFiles.rows(vdir)
            // A variant dir holds one model. Mixing would silently average two systems.
            if let other = rows.first(where: { $0.meta.requested_model != model }) {
                throw EvalError.refuse("\(vdir.path) already holds \(other.meta.requested_model) rows; asked to add \(model). Use another --out.")
            }
            let done = Set(rows.map { "\($0.prompt_id)\u{0}\($0.rep)" })
            for fx in fixtures { for rep in 0..<cfg.reps where !done.contains("\(fx.id)\u{0}\(rep)") { jobs.append(.coach(fx, model: i, rep: rep)) } }
            if cfg.judgeModel != nil {
                for row in rows where row.meta.judge_error != nil && row.rep < cfg.judgeReps { jobs.append(.rejudge(row, model: i)) }
            }
        }
        let rejudges = jobs.filter { if case .rejudge = $0 { return true }; return false }.count
        log("\(jobs.count - rejudges) of \(fixtures.count * cfg.models.count * cfg.reps) (case, model, rep) to run"
            + (rejudges > 0 ? ", plus \(rejudges) judge-only re-run(s)" : ""))

        var finished = 0, counts = Counts()
        let started = Date()
        await withTaskGroup(of: (Int, Outcome).self) { group in
            var next = jobs.makeIterator()
            func launch() {
                switch next.next() {
                case nil: return
                case .coach(let fx, let i, let rep)?:
                    group.addTask { (i, await runJob(fx, model: cfg.models[i], rep: rep, cfg: cfg, prompts: prompts)) }
                case .rejudge(let row, let i)?:
                    let vdir = cfg.outDir.appendingPathComponent(variantName(i))
                    group.addTask { (i, await rejudge(row, vdir: vdir, judgeModel: cfg.judgeModel!, cfg: cfg)) }
                }
            }
            for _ in 0..<max(1, cfg.concurrency) { launch() }
            while let (i, outcome) = await group.next() {
                let vdir = cfg.outDir.appendingPathComponent(variantName(i))
                let results = vdir.appendingPathComponent("results.jsonl")
                finished += 1
                do {
                    switch outcome {
                    case .scored(let row, let trace, let judgeTrace, let judgeError):
                        try EvalFiles.append(row, to: results)
                        counts.scored += 1
                        let name = traceName(row)
                        try EvalFiles.write(trace, to: vdir.appendingPathComponent("traces/\(name)"))
                        if let judgeTrace { try EvalFiles.write(judgeTrace, to: vdir.appendingPathComponent("judge/\(name)")) }
                        let g = row.grade
                        log("[\(finished)/\(jobs.count)] \(row.prompt_id) \(row.meta.requested_model) rep\(row.rep) \(row.status)"
                            + " contract=\(g["contract"].map { Int($0) }.map(String.init) ?? "-")"
                            + " verdict=\(g["verdict_match"].map { Int($0) }.map(String.init) ?? "-")")
                        if let judgeError { counts.judgeErrors += 1; try logJudgeError(judgeError, vdir) }
                    case .rejudged(let row, let judgeTrace, let judgeError):
                        try EvalFiles.replace(row, in: results)
                        counts.scored += 1
                        if let judgeTrace { try EvalFiles.write(judgeTrace, to: vdir.appendingPathComponent("judge/\(traceName(row))")) }
                        log("[\(finished)/\(jobs.count)] \(row.prompt_id) \(row.meta.requested_model) rep\(row.rep) re-judged"
                            + (judgeError == nil ? " ok" : ""))
                        if let judgeError { counts.judgeErrors += 1; try logJudgeError(judgeError, vdir) }
                    case .failed(let err):
                        counts.failed += 1
                        try EvalFiles.append(err, to: vdir.appendingPathComponent("errors.jsonl"))
                        log("[\(finished)/\(jobs.count)] \(err.prompt_id) \(err.requested_model) rep\(err.rep) ERROR \(err.failure_class): \(err.error.prefix(200))")
                    }
                } catch { counts.failed += 1; log("write failed: \(error)") }
                launch()
            }
        }
        log("done in \(Int(Date().timeIntervalSince(started)))s: \(counts.scored) scored, \(counts.judgeErrors) judge errors, \(counts.failed) failed")
        return counts
    }

    static func logJudgeError(_ e: ErrorRow, _ vdir: URL) throws {
        try EvalFiles.append(e, to: vdir.appendingPathComponent("errors.jsonl"))
        log("  judge failed (\(e.failure_class)): \(e.error.prefix(200))")
    }
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

enum EvalFiles {
    static func rows(_ vdir: URL) -> [ResultRow] { decodeLines(vdir.appendingPathComponent("results.jsonl")) }
    static func errors(_ vdir: URL) -> [ErrorRow] { decodeLines(vdir.appendingPathComponent("errors.jsonl")) }

    static func decodeLines<T: Decodable>(_ url: URL) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    static func append<T: Encodable>(_ value: T, to url: URL) throws {
        let line = try JSONEncoder().encode(value) + Data("\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }

    /// Rewrites results.jsonl atomically with `row` in place of the line for its (case, rep).
    /// Other lines are kept byte-for-byte, undecodable ones included.
    static func replace(_ row: ResultRow, in url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var replaced = false
        let lines = try text.split(separator: "\n").map { line -> String in
            guard let old = try? JSONDecoder().decode(ResultRow.self, from: Data(line.utf8)),
                  old.prompt_id == row.prompt_id, old.rep == row.rep else { return String(line) }
            replaced = true
            return String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        }
        guard replaced else { throw EvalError.refuse("no \(row.prompt_id) rep\(row.rep) row in \(url.path) to replace") }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(value).write(to: url, options: .atomic)
    }

    /// First-party $/MTok (input, output).
    static let prices: [String: (in: Double, out: Double)] = [
        "claude-fable-5-1": (10, 50), "claude-fable-5": (10, 50),
        "claude-opus-5-5": (4, 20), "claude-opus-5": (5, 25),
        "claude-opus-4-8": (5, 25), "claude-opus-4-7": (5, 25), "claude-opus-4-6": (5, 25),
        "claude-sonnet-5-5": (2, 10), "claude-sonnet-5": (2, 10), "claude-sonnet-4-6": (3, 15),
        "claude-haiku-5-5": (0.10, 0.50), "claude-haiku-4-5": (1, 5),
    ]

    /// Exact id or its dated snapshot (`claude-haiku-4-5-20251001`); an unlisted model is nil,
    /// never priced as a neighbouring family member.
    static func price(_ model: String) -> (in: Double, out: Double)? {
        prices.first { servedMatches(model, $0.key) }?.value
    }

    /// nil = billed usage on a model with no price: shown as "unpriced", never as $0.
    static func cost(_ model: String?, _ u: ResponseMeta.Usage?) -> Double? {
        guard let u else { return 0 }
        guard let model, let p = price(model) else { return nil }
        return (Double(u.inputTokens) * p.in + Double(u.outputTokens) * p.out
                + Double(u.cacheReadInputTokens ?? 0) * p.in * 0.1
                + Double(u.cacheCreationInputTokens ?? 0) * p.in * 1.25) / 1_000_000
    }

    static let metrics: [[String: Any]] = [
        // Headline first: the report treats the first binary metric as the headline.
        ["id": "verdict_match", "label": "Verdict match", "kind": "binary"],
        ["id": "contract", "label": "Contract", "kind": "binary"],
        ["id": "keys_ok", "label": "Score keys", "kind": "binary"],
        ["id": "ts_grounded", "label": "TS grounded", "kind": "float", "scale": 1],
        ["id": "n_highlights", "label": "Highlights", "kind": "float", "scale": 5],
        ["id": "refused", "label": "Refused", "kind": "binary", "better": "lower"],
        ["id": "grounded", "label": "J grounded", "kind": "binary"],
        ["id": "actionable", "label": "J actionable", "kind": "binary"],
        ["id": "rationale_consistent", "label": "J rationale", "kind": "binary"],
        ["id": "calibrated", "label": "J calibrated", "kind": "binary"],
        ["id": "judge_mean", "label": "Judge mean", "kind": "float", "scale": 1],
        ["id": "chk_advances_false", "label": "Chk no-adv", "kind": "binary"],
        ["id": "chk_corr_lt_conc", "label": "Chk corr<conc", "kind": "binary"],
        ["id": "chk_process_notes", "label": "Chk process", "kind": "binary"],
        ["id": "chk_injection", "label": "Chk injection", "kind": "binary"],
        ["id": "chk_max_mean", "label": "Chk max mean", "kind": "binary"],
    ]

    /// Files whose change alters what a run measures, besides Sources/DebriefEval itself.
    static let harnessPaths = [
        "Package.swift", "Package.resolved",
        "Sources/CoachingEngine/ClaudeClient.swift", "Sources/CoachingEngine/CoachingService.swift",
        "Sources/CoachingEngine/CoachingResult.swift", "Sources/CoachingEngine/PromptStore.swift",
        "Sources/Store/Queries.swift", "Sources/Store/TranscriptArtifacts.swift",
    ]

    static func stateURL(_ out: URL) -> URL { out.appendingPathComponent("_state.json") }

    static func readState(_ out: URL) -> [String: Any] {
        (try? Data(contentsOf: stateURL(out))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static func writeState(_ st: [String: Any], _ out: URL) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: stateURL(out), options: .atomic)
    }

    /// Refreshed on every run so reps/metrics/prices describe the latest run, not the first.
    /// Other keys (harness_sha, anything hand-added) are kept, and so are extra harness paths.
    static func refreshState(_ cfg: EvalConfig) throws {
        var st = readState(cfg.outDir)
        st["reps"] = cfg.reps
        st["metrics"] = metrics
        st["perf_fields"] = [["id": "cost_usd", "label": "Cost", "unit": "$"],
                             ["id": "in_tokens", "label": "In tok"], ["id": "out_tokens", "label": "Out tok"],
                             ["id": "latency_s", "label": "Latency", "unit": "s"]]
        st["prices"] = Dictionary(uniqueKeysWithValues: prices.map { ($0.key, ["in": $0.value.in, "out": $0.value.out]) })
        st["harness_paths"] = Harness.paths(st)
        try writeState(st, cfg.outDir)
    }

    static func writeChangeIfAbsent(_ vdir: URL, model: String, baseline: String) throws {
        let url = vdir.appendingPathComponent("change.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try """
        # \(vdir.lastPathComponent)

        Model: \(model) (prompt, schema, scaffold held fixed)

        Baseline is \(baseline). Same fixtures, same prompts directory (see each row's \
        meta.prompt_hash / schema_hash), same CoachingService path; only the model id differs.

        """.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Change detector over the harness, not a security boundary: sha256 over
/// Sources/DebriefEval/*.swift + `paths(_:)`, compared to the sha a human last approved
/// with --approve-harness.
enum Harness {
    static let sourceDir = "Sources/DebriefEval"

    /// The current `EvalFiles.harnessPaths` plus any extra paths added to `_state.json` —
    /// the one list the gate, --dry-run and the state file all use.
    static func paths(_ st: [String: Any]) -> [String] {
        Set(EvalFiles.harnessPaths + (st["harness_paths"] as? [String] ?? [])).sorted()
    }

    static func sha(listed: [String]) throws -> String {
        let fm = FileManager.default
        guard let own = try? fm.contentsOfDirectory(atPath: sourceDir) else {
            throw EvalError.refuse("run from the package root (no \(sourceDir) here)")
        }
        var h = SHA256()
        for path in Set(own.filter { $0.hasSuffix(".swift") }.map { "\(sourceDir)/\($0)" } + listed).sorted() {
            guard let data = fm.contents(atPath: path) else { log("warning: harness path \(path) not readable — skipped"); continue }
            h.update(data: Data(path.utf8)); h.update(data: Data([0])); h.update(data: data); h.update(data: Data([0]))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the sha to stamp on rows; throws `.refuse` (exit 2) on an unapproved harness.
    static func gate(out: URL, approve: Bool) throws -> String {
        var st = EvalFiles.readState(out)
        let sha = try sha(listed: paths(st))
        if st["harness_sha"] as? String == sha { return sha }
        if approve {
            st["harness_sha"] = sha
            try EvalFiles.writeState(st, out)
            log("harness approved: sha256 \(sha.prefix(12)) recorded in \(EvalFiles.stateURL(out).path)")
            return sha
        }
        let old = (st["harness_sha"] as? String).map { "approved \($0.prefix(12)), now \(sha.prefix(12))" }
            ?? "nothing approved yet (computed \(sha.prefix(12)))"
        throw EvalError.refuse("harness changed since last approved run — \(old). Review the diff, then re-run with --approve-harness.")
    }
}
