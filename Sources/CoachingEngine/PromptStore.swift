import Foundation
import Store

public struct PromptStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Debrief/prompts")
    }

    private static let defaults: [(file: String, content: String)] = [
        ("base.md", DefaultPrompts.base),
        ("behavioral.md", DefaultPrompts.behavioral),
        ("technical.md", DefaultPrompts.technical),
        ("recruiter_screen.md", DefaultPrompts.recruiterScreen),
        ("system_design.md", DefaultPrompts.systemDesign),
        ("product_sense.md", DefaultPrompts.productSense),
        ("tech_deep_dive.md", DefaultPrompts.techDeepDive),
    ]

    public func ensureDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (file, content) in Self.defaults {
            let url = directory.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: url.path) {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Every overlay file in the prompts directory is a selectable round type.
    /// Builtins first (stable order), then custom files alphabetically.
    public func availableRoundTypes() -> [RoundType] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let types = files.filter { $0.pathExtension == "md" }
            .map { RoundType(rawValue: $0.deletingPathExtension().lastPathComponent) }
            .filter { $0.rawValue != "base" }
        let customs = types.filter { !RoundType.builtins.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return RoundType.builtins.filter(types.contains) + customs
    }

    /// Parses `- key: description` bullets out of a `## Scored dimensions` section.
    /// Returns [] when the section is absent, so a hand-written overlay with no such
    /// section still coaches — it just contributes no scored dimensions of its own.
    static func parseDimensions(_ markdown: String) -> [String] {
        var keys: [String] = []
        var inSection = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                // Any other heading closes the section — dimensions never span headings.
                inSection = trimmed.lowercased() == "## scored dimensions"
                continue
            }
            guard inSection, trimmed.hasPrefix("- ") else { continue }
            // Continuation lines of a wrapped bullet are indented, so only an
            // unindented "- " starts a new dimension.
            guard line.hasPrefix("- "), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon])
                .trimmingCharacters(in: .whitespaces)
            // snake_case only: guards against prose bullets ("- Note: ...") becoming keys.
            if !key.isEmpty, key.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }) {
                keys.append(key)
            }
        }
        return keys
    }

    /// The scored dimension keys for a round: base's shared delivery dimensions plus the
    /// overlay's round-specific ones. This is the JSON-schema contract the LLM must return,
    /// so it is derived from the same markdown the model reads — the two cannot drift.
    public func dimensions(for roundType: RoundType) throws -> [String] {
        let base = try String(contentsOf: directory.appendingPathComponent("base.md"), encoding: .utf8)
        let overlay = (try? String(contentsOf: directory.appendingPathComponent("\(roundType.rawValue).md"),
                                   encoding: .utf8)) ?? ""
        var seen = Set<String>()
        return (Self.parseDimensions(base) + Self.parseDimensions(overlay)).filter { seen.insert($0).inserted }
    }

    public func assembleSystemPrompt(roundType: RoundType,
                                     historyTags: [(tag: String, count: Int)],
                                     customInstructions: String = "") throws -> String {
        let base = try String(contentsOf: directory.appendingPathComponent("base.md"), encoding: .utf8)
        // Missing overlay (user deleted a custom type's file) must not fail the
        // debrief — coach from the base rubric alone.
        let overlay = (try? String(contentsOf: directory.appendingPathComponent("\(roundType.rawValue).md"),
                                   encoding: .utf8)) ?? ""
        let history: String
        if historyTags.isEmpty {
            history = "## Prior session history\n\nNo prior session history."
        } else {
            let lines = historyTags.map { "- \($0.tag) (x\($0.count))" }.joined(separator: "\n")
            history = "## Prior session history\n\nRecurring weakness tags from this candidate's recent interviews:\n\(lines)"
        }
        var sections = overlay.isEmpty ? [base, history] : [base, overlay, history]
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sections.append("""
            ## Criteria for THIS interview

            These instructions were provided specifically for this interview. Where they conflict \
            with the general rubric above, follow these. Otherwise the base dimensions, weakness-tag \
            vocabulary, and output format above still fully apply.

            \(trimmed)
            """)
        }
        return sections.joined(separator: "\n\n")
    }
}
