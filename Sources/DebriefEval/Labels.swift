import Foundation

/// Human labels for judge calibration. Blind: label.md and labels.json show only `item-NN`,
/// in hashed (not variant) order; which case/model each item is lives in `_key.json`.
enum Labels {
    struct Item: Codable {
        var item: String
        /// 0/1 per JudgeRubric criterion; nil until the human fills it in.
        var labels: [String: Int?]
        var notes: String
    }
    struct Key: Codable {
        var item: String
        var prompt_id: String
        var variant: String
        var rep: Int
    }

    static func exportLabels(out: URL, limit: Int, dir: URL) throws {
        let json = dir.appendingPathComponent("labels.json")
        // Never clobber a half-finished labelling session.
        guard !FileManager.default.fileExists(atPath: json.path) else {
            throw EvalError.refuse("\(json.path) exists — move it aside to export a fresh set")
        }
        var picked: [(row: ResultRow, variant: String, debrief: String)] = []
        for v in Summary.variants(out) {
            // The debrief exactly as the judge graded it, so human and judge label the same text.
            for row in EvalFiles.rows(out.appendingPathComponent(v)).sorted(by: { $0.prompt_id < $1.prompt_id })
            where row.grade["grounded"] != nil {
                guard let debrief = row.meta.debrief_json else { continue }
                picked.append((row, v, debrief))
            }
        }
        // Deterministic shuffle so variants interleave and the limit doesn't favour baseline.
        picked = Array(picked.sorted { sha256($0.row.prompt_id + $0.variant) < sha256($1.row.prompt_id + $1.variant) }.prefix(limit))
        var items: [Item] = [], keys: [Key] = []
        var md = "# Debrief labelling sheet\n\n"
        md += "For each item, read the transcript and debrief, then set each criterion in labels.json to 1 (pass) or 0 (fail). "
        md += "Judge only what is asked; do not reward length or polish.\n\n"
        for c in JudgeRubric.criteria { md += "- **\(c)** — \(JudgeRubric.questions[c]!)\n" }
        for (n, p) in picked.enumerated() {
            let id = String(format: "item-%02d", n + 1)
            items.append(Item(item: id, labels: Dictionary(uniqueKeysWithValues: JudgeRubric.criteria.map { ($0, nil) }), notes: ""))
            keys.append(Key(item: id, prompt_id: p.row.prompt_id, variant: p.variant, rep: p.row.rep))
            md += "\n---\n\n## \(id)\n\n### Interview\n\n```\n\(p.row.prompt)\n```\n\n### Debrief\n\n```json\n\(p.debrief)\n```\n"
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try md.write(to: dir.appendingPathComponent("label.md"), atomically: true, encoding: .utf8)
        try EvalFiles.write(items, to: json)
        try EvalFiles.write(keys, to: dir.appendingPathComponent("_key.json"))
        log("wrote \(items.count) items to \(dir.path)/label.md + labels.json")
    }

    /// Per-criterion agreement % and Cohen's kappa, human vs judge. < 90% is flagged: the
    /// judge prompt needs another pass before its scores can steer a decision.
    static func agreement(out: URL, dir: URL) throws -> String {
        let url = dir.appendingPathComponent("labels.json")
        guard let data = try? Data(contentsOf: url) else { throw EvalError.refuse("no \(url.path) — run --export-labels first") }
        let items = try JSONDecoder().decode([Item].self, from: data)
        let keys = Dictionary(uniqueKeysWithValues: try JSONDecoder().decode(
            [Key].self, from: Data(contentsOf: dir.appendingPathComponent("_key.json"))).map { ($0.item, $0) })
        var rowsByVariant: [String: [ResultRow]] = [:]
        var md = "| criterion | n | agreement | kappa | |\n|---|---|---|---|---|\n"
        for c in JudgeRubric.criteria {
            var human: [Int] = [], judge: [Int] = []
            for it in items {
                guard let h = it.labels[c] ?? nil, let it = keys[it.item] else { continue }
                let rows = rowsByVariant[it.variant] ?? EvalFiles.rows(out.appendingPathComponent(it.variant))
                rowsByVariant[it.variant] = rows
                guard let j = rows.first(where: { $0.prompt_id == it.prompt_id && $0.rep == it.rep })?.grade[c] else { continue }
                human.append(h); judge.append(Int(j))
            }
            let agree = human.isEmpty ? 0 : Double(zip(human, judge).filter { $0 == $1 }.count) / Double(human.count)
            md += "| \(c) | \(human.count) | \(Summary.f(agree * 100, 0))% | \(Summary.f(Stats.kappa(human, judge))) | "
                + (agree < 0.9 ? "**below 90%**" : "") + " |\n"
        }
        return md
    }
}
