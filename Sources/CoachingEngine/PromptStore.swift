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
