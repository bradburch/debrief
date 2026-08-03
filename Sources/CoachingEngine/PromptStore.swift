import Foundation
import Store

public enum PromptError: Error, Equatable {
    /// base.md declares no `## Scored dimensions`, so there is nothing to score. Reachable if
    /// the user edits the section out of base.md; `ensureDefaults` repairs the upgrade case.
    case noScoredDimensions(round: String)
    /// base.md is the shared prompt every overlay builds on, not a selectable round type.
    case cannotDeleteBase
}

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
        ("mock_interview.md", DefaultPrompts.mockInterview),
    ]

    /// Marker that makes a round type transcript-only: recorded and transcribed, never
    /// sent to an LLM. Read from the overlay's leading metadata block so a round type is
    /// still purely data — adding one never needs a Swift change.
    static let transcriptOnlyKey = "transcript-only:"

    /// Heading that marks a prompt as speaking the current contract. Its absence in a builtin
    /// we ship is the upgrade signal — see `ensureDefaults`.
    static let dimensionsHeading = "## Scored dimensions"

    /// Seeds missing prompts, and upgrades builtin prompts left over from before scored
    /// dimensions were parsed out of the markdown.
    ///
    /// The upgrade is not optional politeness. `ensureDefaults` deliberately never clobbers a
    /// file, so every install that had already launched Debrief kept a `base.md` with no
    /// `## Scored dimensions` heading — making `dimensions(for:)` return `[]`, which builds an
    /// empty `scores` schema, stores every debrief with a 0.0 average, and fails every local-LLM
    /// debrief outright. A stale prompt is not merely out of date here; it is incompatible with
    /// the response contract the clients enforce.
    ///
    /// Any user edits are preserved next to the file as `<name>.md.pre-dimensions.bak` rather
    /// than silently discarded — we can't merge them, but we must not lose them.
    public func ensureDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (file, content) in Self.defaults {
            let url = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try content.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            // Only upgrade a builtin we ship, only when OUR default declares dimensions and
            // the file on disk doesn't. A custom round type the user wrote has no dimensions
            // section and is none of our business.
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard content.contains(Self.dimensionsHeading),
                  !existing.contains(Self.dimensionsHeading) else { continue }
            let backup = url.appendingPathExtension("pre-dimensions.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            try content.write(to: url, atomically: true, encoding: .utf8)
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

    // MARK: - Transcript-only round types

    public func isTranscriptOnly(_ type: RoundType) -> Bool {
        let url = directory.appendingPathComponent("\(type.rawValue).md")
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return Self.parseTranscriptOnly(markdown)
    }

    /// True when the overlay's leading metadata block declares `transcript-only: true`.
    ///
    /// Only the lines before the first Markdown heading are considered, so prose that
    /// merely discusses being transcript-only can never accidentally disable scoring for
    /// a round type — the marker has to be metadata, not a sentence.
    static func parseTranscriptOnly(_ markdown: String) -> Bool {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return false }  // metadata block is over
            guard trimmed.lowercased().hasPrefix(transcriptOnlyKey) else { continue }
            let value = trimmed.dropFirst(transcriptOnlyKey.count).trimmingCharacters(in: .whitespaces)
            return value.lowercased() == "true"
        }
        return false
    }

    /// Returns `markdown` with the transcript-only marker set to `on`.
    ///
    /// The editor shows the marker both as a checkbox and as raw text in the prompt body,
    /// so one of them has to win on save or they drift apart. The checkbox does: any
    /// existing marker in the leading metadata block is dropped first, then re-added when
    /// `on`. Idempotent, so saving repeatedly never stacks up duplicate lines.
    public static func settingTranscriptOnly(_ on: Bool, in markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { break }  // past the metadata block
            if trimmed.lowercased().hasPrefix(transcriptOnlyKey) {
                lines.remove(at: index)
                continue
            }
            index += 1
        }
        // Drop blank lines the removal may have left at the top.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n")
        return on ? "transcript-only: true\n\n" + body : body
    }

    // MARK: - Editing round types

    /// Raw markdown for a round type, or "" when it has no overlay file yet.
    public func markdown(for type: RoundType) -> String {
        let url = directory.appendingPathComponent("\(type.rawValue).md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func write(_ markdown: String, for type: RoundType) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try markdown.write(to: directory.appendingPathComponent("\(type.rawValue).md"),
                           atomically: true, encoding: .utf8)
    }

    /// Deletes a round type's overlay, which is what removes it from the picker.
    /// Refuses `base`, which is the shared prompt every round type builds on rather than
    /// a selectable type — deleting it would break every debrief.
    public func delete(_ type: RoundType) throws {
        guard type.rawValue != "base" else {
            throw PromptError.cannotDeleteBase
        }
        let url = directory.appendingPathComponent("\(type.rawValue).md")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Normalizes a user-typed name ("Take Home Review") into a round-type raw value
    /// ("take_home_review"), which is both the filename stem and the stored value.
    /// Returns nil when nothing usable is left, so the UI can reject the input.
    public static func normalizedRawValue(from name: String) -> String? {
        let allowed = name.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : " "
        }
        let slug = String(allowed).split(separator: " ").joined(separator: "_")
        return slug.isEmpty ? nil : slug
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
    ///
    /// Throws rather than returning [] when base.md declares nothing. An empty set is not a
    /// benign edge case: it builds a `scores` schema with no properties, which the Anthropic
    /// path happily stores as a 0.0-average debrief and the local path fails on every session.
    /// Failing here leaves the session retryable and says why.
    public func dimensions(for roundType: RoundType) throws -> [String] {
        let base = try String(contentsOf: directory.appendingPathComponent("base.md"), encoding: .utf8)
        let overlay = (try? String(contentsOf: directory.appendingPathComponent("\(roundType.rawValue).md"),
                                   encoding: .utf8)) ?? ""
        var seen = Set<String>()
        let dims = (Self.parseDimensions(base) + Self.parseDimensions(overlay))
            .filter { seen.insert($0).inserted }
        guard !dims.isEmpty else { throw PromptError.noScoredDimensions(round: roundType.rawValue) }
        return dims
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
