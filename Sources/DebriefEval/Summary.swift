import Foundation
import Store

enum Summary {
    struct CaseK { let id: String; let n: Int; let c: Int }

    /// Per-case (n reps scored, c passed) for a metric, status-ok rows only.
    static func perCase(_ rows: [ResultRow], _ metric: String) -> [CaseK] {
        Dictionary(grouping: rows.filter { $0.grade[metric] != nil }, by: \.prompt_id)
            .map { CaseK(id: $0.key, n: $0.value.count, c: $0.value.filter { $0.grade[metric] == 1 }.count) }
            .sorted { $0.id < $1.id }
    }

    static func variants(_ out: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        let vs = names.compactMap { $0.hasPrefix("v") ? Int($0.dropFirst()) : nil }.sorted().map { "v\($0)" }
        return (names.contains("baseline") ? ["baseline"] : []) + vs
    }

    static func f(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }

    static func build(out: URL, k: Int) -> String {
        let vs = variants(out)
        let data = vs.map { v -> (rows: [ResultRow], all: [ResultRow], errs: [ErrorRow]) in
            let all = EvalFiles.rows(out.appendingPathComponent(v))
            return (all.filter { $0.status == "ok" }, all, EvalFiles.errors(out.appendingPathComponent(v)))
        }
        let label = zip(vs, data).map { v, d in "\(v) (\(Set(d.all.map(\.meta.requested_model)).sorted().joined(separator: ",")))" }
        var md = "# Coaching eval summary\n\n"
        md += "Means over status-ok reps; 95% CI (Wilson for binary). Truncated rows and errors are counted, never averaged.\n\n"

        md += "| metric | " + label.joined(separator: " | ") + " |\n|---|" + String(repeating: "---|", count: vs.count) + "\n"
        for m in EvalFiles.metrics {
            let id = m["id"] as! String, binary = m["kind"] as? String == "binary"
            let cells = data.map { d -> String in
                let xs = d.rows.compactMap { $0.grade[id] }
                guard !xs.isEmpty else { return "—" }
                if binary {
                    let ci = Stats.wilson(xs.reduce(0, +), Double(xs.count))
                    return "\(f(xs.reduce(0, +) / Double(xs.count))) [\(f(ci.lo))–\(f(ci.hi))] n=\(xs.count)"
                }
                let ci = Stats.meanCI(xs)
                return "\(f(ci.mean)) [\(f(ci.lo))–\(f(ci.hi))] n=\(xs.count)"
            }
            if cells.contains(where: { $0 != "—" }) { md += "| \(id) | " + cells.joined(separator: " | ") + " |\n" }
        }

        // Verdict as a classifier of "advances".
        md += "| advances P / R / spec | " + data.map { d -> String in
            var tp = 0, fp = 0, tn = 0, fn = 0
            for r in d.rows {
                guard let v = r.meta.advancement.flatMap(Advancement.init(rawValue:)), r.tags.count > 2,
                      r.tags[2] != "unknown" else { continue }
                switch (v.advances, r.tags[2] == "advanced") {
                case (true, true): tp += 1
                case (true, false): fp += 1
                case (false, false): tn += 1
                case (false, true): fn += 1
                }
            }
            func ratio(_ a: Int, _ b: Int) -> String { b == 0 ? "—" : f(Double(a) / Double(b)) }
            return "\(ratio(tp, tp + fp)) / \(ratio(tp, tp + fn)) / \(ratio(tn, tn + fp))"
        }.joined(separator: " | ") + " |\n"

        for metric in ["contract", "verdict_match"] {
            md += "| \(metric) pass@\(k) / pass^\(k) | " + data.map { d in
                let cs = perCase(d.rows, metric)
                guard !cs.isEmpty else { return "—" }
                let at = cs.map { Stats.passAtK(n: $0.n, c: $0.c, k: min(k, $0.n)) }.reduce(0, +) / Double(cs.count)
                let hat = cs.map { Stats.passHatK(n: $0.n, c: $0.c, k: min(k, $0.n)) }.reduce(0, +) / Double(cs.count)
                // A case with fewer scored reps than k is reported at k=n — say how many.
                let short = cs.filter { $0.n < k }.count
                return "\(f(at)) / \(f(hat)) (\(cs.count) cases" + (short > 0 ? ", \(short) with <\(k) reps)" : ")")
            }.joined(separator: " | ") + " |\n"
        }

        // Perf + spend. Error rows' billed usage counts: failed spend is still spend.
        func row(_ name: String, _ cell: (([ResultRow], [ResultRow], [ErrorRow])) -> String) {
            md += "| \(name) | " + data.map { cell(($0.rows, $0.all, $0.errs)) }.joined(separator: " | ") + " |\n"
        }
        // Error attempts accumulate across resumes; "unresolved" is (case, rep, stage) with no
        // later success — the number that says whether the comparison is complete.
        row("rows ok / truncated / failed attempts / unresolved") { d in
            let scored = Set(d.1.map { "\($0.prompt_id)\u{0}\($0.rep)" })
            let open = Set(d.2.filter { $0.stage == "judge" || !scored.contains("\($0.prompt_id)\u{0}\($0.rep)") }
                .map { "\($0.prompt_id)\u{0}\($0.rep)\u{0}\($0.stage)" })
            return "\(d.0.count) / \(d.1.count - d.0.count) / \(d.2.count) / \(open.count)"
        }
        row("tokens in / out (coach)") { d in
            "\(d.1.map(\.usage.inputTokens).reduce(0, +)) / \(d.1.map(\.usage.outputTokens).reduce(0, +))"
        }
        row("tokens in / out (judge)") { d in
            "\(d.1.compactMap { $0.judge_usage?.inputTokens }.reduce(0, +)) / \(d.1.compactMap { $0.judge_usage?.outputTokens }.reduce(0, +))"
        }
        row("cost $ (coach + judge + failed)") { d in
            let coach = d.1.map { EvalFiles.cost($0.model, $0.usage) }.reduce(0, +)
            let judge = d.1.map { EvalFiles.cost($0.judge_model, $0.judge_usage) }.reduce(0, +)
            let failed = d.2.map { EvalFiles.cost($0.model, $0.usage) + EvalFiles.cost($0.judge_model, $0.judge_usage) }.reduce(0, +)
            return "\(f(coach + judge + failed, 3)) (\(f(coach, 3)) + \(f(judge, 3)) + \(f(failed, 3)))"
        }
        row("latency p50 / p95 s") { d in
            let l = d.0.map(\.latency_s)
            return l.isEmpty ? "—" : "\(f(Stats.percentile(l, 50), 1)) / \(f(Stats.percentile(l, 95), 1))"
        }
        row("failed attempts by class") { d in
            let by = Dictionary(grouping: d.2, by: \.failure_class).map { "\($0.key)=\($0.value.count)" }.sorted()
            return by.isEmpty ? "none" : by.joined(separator: ", ")
        }
        row("served models") { Set($0.1.map(\.model)).sorted().joined(separator: ", ") }
        row("schema_hash") { Set($0.1.map { String($0.meta.schema_hash.prefix(10)) }).sorted().joined(separator: ", ") }
        row("harness_sha") { Set($0.1.map { String($0.meta.harness_sha.prefix(10)) }).sorted().joined(separator: ", ") }
        row("prompt_hash by round") { d in
            Set(d.1.map { "\($0.meta.round_type):\($0.meta.prompt_hash.prefix(8))" }).sorted().joined(separator: "<br>")
        }

        md += "\n## Per case (passes / reps)\n\n| case | " + vs.flatMap { ["\($0) contract", "\($0) verdict"] }.joined(separator: " | ")
            + " |\n|---|" + String(repeating: "---|", count: vs.count * 2) + "\n"
        let ids = Set(data.flatMap { $0.all.map(\.prompt_id) }).sorted()
        var flagged: [String] = []
        for id in ids {
            let cells = zip(vs, data).flatMap { v, d -> [String] in
                ["contract", "verdict_match"].map { m in
                    guard let c = perCase(d.rows.filter { $0.prompt_id == id }, m).first else { return "—" }
                    if m == "contract", c.c < c.n { flagged.append("\(id) (\(v))") }
                    return "\(c.c)/\(c.n)"
                }
            }
            md += "| \(id) | " + cells.joined(separator: " | ") + " |\n"
        }
        md += "\n**Contract pass^k false** (some rep broke the contract): "
            + (flagged.isEmpty ? "none" : flagged.joined(separator: ", ")) + "\n"
        return md
    }

    /// Writes summary.md, prints it, then runs the lite report builder if node and the
    /// builder are both present — skipped (not an error) otherwise.
    static func write(out: URL, k: Int, reportBuilder: String) {
        let md = build(out: out, k: k)
        try? md.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(md)
        let node = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node, FileManager.default.fileExists(atPath: reportBuilder) else {
            log("report builder skipped (node or \(reportBuilder) not found)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [reportBuilder, out.path + "/"]
        do { try p.run(); p.waitUntilExit() } catch { log("report builder failed: \(error)") }
    }
}
