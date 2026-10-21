import Foundation
import Store
import CoachingEngine

/// `swift run DebriefEval --help`. See eval/README.md.
@main
struct EvalCLI {
    static let usage = """
    usage: swift run DebriefEval [--models a,b] [--reps N] [--cases ids/globs] [--judge-model ID|none]
             [--judge-reps N] [--concurrency N] [--timeout-s N] [--prompts-dir DIR] [--out DIR]
             [--report-builder PATH] [--approve-harness] [--dry-run]
           swift run DebriefEval --summary | --judge-selftest | --export-labels N | --agreement
    """

    static func main() async {
        do { exit(try await run(Array(CommandLine.arguments.dropFirst()))) }
        catch EvalError.refuse(let m) { log("refusing to run: \(m)"); exit(2) }
        catch { log("error: \(error)"); exit(1) }
    }

    static func run(_ argv: [String]) async throws -> Int32 {
        var a: [String: String] = [:], flags = Set<String>()
        var i = 0
        while i < argv.count {
            let k = argv[i]
            if ["--approve-harness", "--dry-run", "--summary", "--judge-selftest", "--agreement", "-h", "--help"].contains(k) {
                flags.insert(k)
            } else if k.hasPrefix("--"), i + 1 < argv.count {
                a[k] = argv[i + 1]; i += 1
            } else { throw EvalError.refuse("unknown or incomplete argument \(k)\n\(usage)") }
            i += 1
        }
        if flags.contains("-h") || flags.contains("--help") { print(usage); return 0 }
        func int(_ k: String, _ d: Int) throws -> Int {
            guard let s = a[k] else { return d }
            guard let v = Int(s), v >= 0 else { throw EvalError.refuse("\(k) needs a non-negative integer") }
            return v
        }

        let out = URL(fileURLWithPath: a["--out"] ?? ".claude/hillclimb/coaching")
        let judgeModel = a["--judge-model"] ?? "claude-opus-5-5"
        var cfg = EvalConfig(
            models: (a["--models"] ?? "claude-sonnet-5-5,claude-haiku-5-5").split(separator: ",").map(String.init),
            reps: max(1, try int("--reps", 5)),
            casePatterns: a["--cases"]?.split(separator: ",").map(String.init) ?? [],
            judgeModel: judgeModel == "none" ? nil : judgeModel,
            judgeReps: try int("--judge-reps", 1),
            concurrency: max(1, try int("--concurrency", 4)),
            timeoutS: Double(try int("--timeout-s", 300)),
            promptsDir: a["--prompts-dir"].map { URL(fileURLWithPath: $0) } ?? PromptStore.defaultDirectory(),
            outDir: out,
            fixtureDirs: [URL(fileURLWithPath: "eval/fixtures/synthetic"), URL(fileURLWithPath: "eval/fixtures/local")])
        let labelsDir = URL(fileURLWithPath: "eval/labels")
        let builder = a["--report-builder"] ?? ProcessInfo.processInfo.environment["DEBRIEF_REPORT_BUILDER"]

        if flags.contains("--summary") { Summary.write(out: out, k: cfg.reps, reportBuilder: builder); return 0 }
        if flags.contains("--agreement") { print(try Labels.agreement(out: out, dir: labelsDir)); return 0 }
        if a["--export-labels"] != nil {
            try Labels.exportLabels(out: out, limit: try int("--export-labels", 30), dir: labelsDir)
            return 0
        }
        guard FileManager.default.fileExists(atPath: cfg.promptsDir.appendingPathComponent("base.md").path) else {
            throw EvalError.refuse("no base.md in \(cfg.promptsDir.path) — pass --prompts-dir")
        }
        if flags.contains("--dry-run") { try dryRun(cfg, out: out); return 0 }

        cfg.apiKey = try apiKey()
        if flags.contains("--judge-selftest") { return try await selfTest(cfg) }
        cfg.harnessSHA = try Harness.gate(out: out, approve: flags.contains("--approve-harness"))
        let counts = try await Runner.run(cfg)
        Summary.write(out: out, k: cfg.reps, reportBuilder: builder)
        // Judge-only errors keep their scored rows and re-judge on the next run, so they warn
        // rather than fail; only a coaching attempt with no row exits 1.
        if counts.judgeErrors > 0 && counts.failed == 0 {
            log("warning: \(counts.judgeErrors) judge error(s); re-run to re-judge just those rows (coaching is not re-billed)")
        }
        return counts.failed > 0 ? 1 : 0
    }

    /// ANTHROPIC_API_KEY, else the app's secrets.json (same file SecretStore writes). Never printed.
    static func apiKey() throws -> String {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Debrief/secrets.json")
        if let data = try? Data(contentsOf: url),
           let k = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["anthropic-api-key"], !k.isEmpty {
            return k
        }
        throw EvalError.refuse("no API key: set ANTHROPIC_API_KEY or save one in Debrief Settings")
    }

    static func dryRun(_ cfg: EvalConfig, out: URL) throws {
        let prompts = PromptStore(directory: cfg.promptsDir)
        let all = try Fixture.load(from: cfg.fixtureDirs).filter { Fixture.matches($0.id, patterns: cfg.casePatterns) }
        let cases = all.filter { !prompts.isTranscriptOnly($0.round) }
        print("DRY RUN — no API calls, nothing written.")
        print("prompts: \(cfg.promptsDir.path)")
        for skipped in all where prompts.isTranscriptOnly(skipped.round) { print("  skip \(skipped.id) (transcript-only round type)") }
        for round in Set(cases.map(\.roundType)).sorted() {
            let rt = RoundType(rawValue: round)
            let sys = try prompts.assembleSystemPrompt(roundType: rt, historyTags: [])
            let dims = try prompts.dimensions(for: rt)
            print("  \(round): prompt_hash \(sha256(sys).prefix(12)) schema_hash \(Runner.schemaHash(dims).prefix(12)) dims \(dims.joined(separator: ","))")
        }
        print("cases (\(cases.count)):")
        for c in cases { print("  \(c.id)  [\(c.roundType), \(c.source), \(c.outcomeLabel)] \(c.segments.count) segments") }
        let judgeCalls = cfg.judgeModel == nil ? 0 : cases.count * min(cfg.reps, cfg.judgeReps)
        var total = 0.0
        print("plan:")
        for (i, m) in cfg.models.enumerated() {
            let p = EvalFiles.price(m) ?? (0, 0)
            let coach = Double(cases.count * cfg.reps) * (10_000 * p.in + 5_000 * p.out) / 1e6
            let jp = cfg.judgeModel.flatMap(EvalFiles.price) ?? (0, 0)
            let judge = Double(judgeCalls) * (12_000 * jp.in + 1_500 * jp.out) / 1e6
            total += coach + judge
            print("  \(variantName(i))/ \(m): \(cases.count) cases × \(cfg.reps) reps = \(cases.count * cfg.reps) coaching calls (~$\(Summary.f(coach))) + \(judgeCalls) judge calls on \(cfg.judgeModel ?? "-") (~$\(Summary.f(judge)))"
                  + (EvalFiles.price(m) == nil ? "  [no price for \(m)]" : ""))
        }
        print("estimate: ~$\(Summary.f(total)) (assumes 10k in / 5k out per coaching call, 12k in / 1.5k out per judge call; resume skips rows already in \(out.path))")
        let st = EvalFiles.readState(out)
        let sha = try Harness.sha(listed: Harness.paths(st))
        print("harness sha \(sha.prefix(12)): " + (st["harness_sha"] as? String == sha ? "approved" : "NOT approved — the real run exits 2 until run once with --approve-harness"))
    }

    /// Paid (4 judge calls): three known-bad debriefs a working judge must fail on every
    /// criterion, plus one known-good debrief it must pass on every criterion — without the
    /// positive control, a judge that fails everything would "pass" this test.
    static func selfTest(_ cfg: EvalConfig) async throws -> Int32 {
        guard let judgeModel = cfg.judgeModel else { throw EvalError.refuse("--judge-model none") }
        guard let fx = try Fixture.load(from: [cfg.fixtureDirs[0]]).first(where: { $0.id == "syn-behavioral-strong" }) else {
            throw EvalError.refuse("syn-behavioral-strong fixture missing")
        }
        let prompts = PromptStore(directory: cfg.promptsDir)
        let rubric = try prompts.assembleSystemPrompt(roundType: fx.round, historyTags: [])
        let transcript = fx.segments.map { "[\(formatTimestamp($0.tStart))] \($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        let negatives: [(String, String)] = [
            ("empty", #"{"prose_debrief":"","scores":{},"advancement":"","advancement_rationale":"","weakness_tags":[],"highlights":[],"action_items":[],"process_notes":[]}"#),
            ("i-dont-know", #"{"prose_debrief":"I don't know.","scores":{},"advancement":"","advancement_rationale":"I don't know.","weakness_tags":[],"highlights":[],"action_items":["I don't know."],"process_notes":[]}"#),
            ("wrong-interview", #"""
            {"prose_debrief":"Lean no. You reached a correct brute-force two-sum quickly and traced it cleanly, but needed three escalating hints to reach the hash map and never stated its O(n) complexity.","scores":{"answer_relevance":4,"structure":4,"conciseness":4,"questions_asked":3,"star_completeness":2,"story_strength":2,"ownership":3,"quantified_impact":1},"advancement":"lean_no","advancement_rationale":"At 00:04:10 the hash map only arrived after the interviewer's third nudge, and at 00:04:35 you could not give the big-O.","weakness_tags":["needed_hints","no_complexity_analysis"],"highlights":[{"t":"00:01:40","note":"Traced the nested loop on [2,7,11,15] correctly."},{"t":"00:03:48","note":"Asked for a nudge on the one-pass approach."},{"t":"00:04:35","note":"Could not state the complexity of the hash-map solution."}],"action_items":["Drill stating time and space complexity out loud for every solution before the interviewer asks.","Practice the hash-map complement pattern until it comes without hints."],"process_notes":[]}
            """#),
        ]
        // Scores keyed by this round's live dimensions; 4 by default, 5 where the transcript
        // shows a quantified, owned, complete STAR story.
        let fives: Set = ["star_completeness", "quantified_impact", "ownership", "answer_relevance"]
        let goodScores = Dictionary(uniqueKeysWithValues: try prompts.dimensions(for: fx.round).map { ($0, fives.contains($0) ? 5 : 4) })
        let good: [String: Any] = [
            "prose_debrief": "Strong yes. Every story carried a measured result and a clear personal role: the ledger migration landed with zero reconciliation differences and CPU down from 85% to 31%, and you owned the risk doc, the dual-write shadow mode and the cutover yourself.",
            "scores": goodScores, "advancement": "strong_yes",
            "advancement_rationale": "At 00:02:30 you gave a baselined result (CPU 85→31%, p99 180→45 ms, zero reconciliation differences), at 00:03:45 you resolved a disagreement with the principal engineer with a failure-mode table in three days, and at 00:06:24 a mentee became primary on-call — senior-level evidence with no gaps.",
            "weakness_tags": [],
            "highlights": [["t": "00:00:20", "note": "Opened with a quantified situation: 85% CPU, eleven weeks to Black Friday."],
                           ["t": "00:02:30", "note": "Result with baselines: CPU 85→31%, p99 180→45 ms, zero reconciliation differences."],
                           ["t": "00:03:02", "note": "Named a real mistake — runbook written alone — and the game-day fix since."]],
            "action_items": ["At 00:00:58 you said you weren't the manager; lead with your tech-lead scope in the first sentence so ownership lands before the details.",
                             "The 00:06:24 mentoring story had no number for the team; prepare one metric (e.g. alert volume or on-call load) to close it the way the migration story closed."],
            "process_notes": [["t": "00:33:50", "note": "The recruiter will be in touch this week."]],
        ]
        let goodJSON = String(decoding: try JSONSerialization.data(withJSONObject: good, options: [.sortedKeys]), as: UTF8.self)

        let judge = Judge(apiKey: cfg.apiKey, model: judgeModel, session: cfg.session)
        var ok = true
        let v = try await withBackoff(RetryCounter()) {
            try await judge.judge(roundType: fx.roundType, coachRubric: rubric, transcript: transcript, debrief: goodJSON)
        }
        let missed = JudgeRubric.criteria.filter { v.grade[$0] != 1 }
        ok = missed.isEmpty
        print("known-good: \(missed.isEmpty ? "OK (passed every criterion)" : "JUDGE TOO STRICT — failed \(missed.joined(separator: ","))")")
        for c in JudgeRubric.criteria { print("    \(c)=\(Int(v.grade[c] ?? -1)) \(v.explanation[c] ?? "")") }
        for (name, debrief) in negatives {
            let v = try await withBackoff(RetryCounter()) {
                try await judge.judge(roundType: fx.roundType, coachRubric: rubric, transcript: transcript, debrief: debrief)
            }
            let passed = JudgeRubric.criteria.filter { v.grade[$0] == 1 }
            ok = ok && passed.isEmpty
            print("\(name): \(passed.isEmpty ? "OK (failed every criterion)" : "JUDGE TOO LENIENT — passed \(passed.joined(separator: ","))")"
                  + "  [\(EvalFiles.cost(v.model, v.usage).map { "$" + Summary.f($0, 3) } ?? "unpriced")]")
            for c in JudgeRubric.criteria { print("    \(c)=\(Int(v.grade[c] ?? -1)) \(v.explanation[c] ?? "")") }
        }
        return ok ? 0 : 1
    }
}
