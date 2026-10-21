import Foundation
import Store

/// One eval case. The on-disk shape is a contract shared with `scripts/export-eval-fixtures`,
/// so field names here are the JSON keys — change both ends together.
struct Fixture: Codable, Sendable {
    struct Segment: Codable, Sendable {
        let speaker: Speaker
        let tStart: Double
        let text: String
    }
    struct Expected: Codable, Sendable {
        /// nil = outcome unknown; `verdict_match` is omitted for the case.
        let advances: Bool?
        let outcomeSource: String
    }
    /// Synthetic-only assertions, each graded as its own `chk_*` metric.
    struct Checks: Codable, Sendable {
        var advancesFalse: Bool?
        var correctnessBelowConciseness: Bool?
        /// Every inner list must have at least one alternative in the process notes.
        var processNotesMention: [[String]]?
        var injectionResisted: Bool?
        var maxMeanScore: Double?
    }

    let id: String
    let source: String
    let roundType: String
    let company: String
    let durationSeconds: Int
    let contextNotes: String
    let segments: [Segment]
    let expected: Expected
    var checks: Checks?

    var round: RoundType { RoundType(rawValue: roundType) }

    var outcomeLabel: String {
        switch expected.advances {
        case true?: return "advanced"
        case false?: return "rejected"
        case nil: return "unknown"
        }
    }

    /// `eval/fixtures/synthetic` (committed) + `eval/fixtures/local` (gitignored, may be
    /// absent). Files starting with `_` are exporter sidecars, not cases.
    static func load(from dirs: [URL]) throws -> [Fixture] {
        var all: [Fixture] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix("_") {
                do { all.append(try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))) }
                catch { throw EvalError.refuse("bad fixture \(file.lastPathComponent): \(error)") }
            }
        }
        var seen = Set<String>()
        for f in all {
            // Ids become file names and the resume key — refuse anything that isn't path-safe.
            guard f.id.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
                throw EvalError.refuse("fixture id '\(f.id)' is not path-safe")
            }
            guard seen.insert(f.id.lowercased()).inserted else { throw EvalError.refuse("duplicate fixture id '\(f.id)'") }
        }
        return all
    }

    /// `--cases` takes comma-separated ids or fnmatch globs (`behavioral-*`).
    static func matches(_ id: String, patterns: [String]) -> Bool {
        patterns.isEmpty || patterns.contains { fnmatch($0, id, 0) == 0 }
    }
}

enum EvalError: Error, CustomStringConvertible {
    /// Exit 2: refused to run (config, harness gate, bad input). Nothing was spent.
    case refuse(String)
    var description: String { if case .refuse(let m) = self { return m }; return "" }
}
