import XCTest
@testable import CoachingEngine
import Store

final class PromptStoreTests: XCTestCase {
    var dir: URL!
    var store: PromptStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = PromptStore(directory: dir)
    }

    func testEnsureDefaultsWritesAllFilesButNeverOverwrites() throws {
        try store.ensureDefaults()
        for name in ["base.md", "behavioral.md", "technical.md", "recruiter_screen.md", "system_design.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
        // User edits base.md; ensureDefaults must not clobber it.
        try "MY CUSTOM PROMPT".write(to: dir.appendingPathComponent("base.md"), atomically: true, encoding: .utf8)
        try store.ensureDefaults()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("base.md"), encoding: .utf8), "MY CUSTOM PROMPT")
    }

    func testParseDimensionsReadsOnlyItsOwnSection() {
        let md = """
        # Overlay

        Additional focus:
        - Think-aloud quality: prose bullet, NOT a dimension — wrong section.

        ## Scored dimensions

        - correctness: did it work?
          - nested: an indented continuation line, not a new dimension.
        - problem_solving: how they got there.
        - Note: a capitalized prose bullet is not a snake_case key.

        ## Additional weakness tags

        - not_a_dimension: this section is over.
        """
        XCTAssertEqual(PromptStore.parseDimensions(md), ["correctness", "problem_solving"])
    }

    func testParseDimensionsAbsentSectionYieldsNone() {
        // A hand-written overlay with no dimensions section must still coach.
        XCTAssertEqual(PromptStore.parseDimensions("# Overlay\n\nJust focus prose.\n"), [])
    }

    func testDimensionsMergeBaseAndOverlayWithoutDuplicates() throws {
        try store.ensureDefaults()
        let dims = try store.dimensions(for: .technical)
        // Base's delivery dimensions come first, then the round's own.
        XCTAssertEqual(Array(dims.prefix(4)),
                       ["answer_relevance", "structure", "conciseness", "questions_asked"])
        XCTAssertTrue(dims.contains("correctness"), "the technical round must score correctness")
        XCTAssertEqual(dims.count, Set(dims).count, "duplicate keys would break the JSON schema")
    }

    func testEveryBuiltinRoundDeclaresRoundSpecificDimensions() throws {
        try store.ensureDefaults()
        let base = try store.dimensions(for: RoundType(rawValue: "base_only_nonexistent_overlay"))
        for round in RoundType.builtins {
            let dims = try store.dimensions(for: round)
            XCTAssertFalse(Set(dims).subtracting(base).isEmpty,
                           "\(round.rawValue) scores only delivery dimensions — its overlay declares none")
        }
    }

    func testMissingOverlayFallsBackToBaseDimensions() throws {
        try store.ensureDefaults()
        // A custom round type whose .md the user deleted must not fail the debrief.
        XCTAssertEqual(try store.dimensions(for: RoundType(rawValue: "gone")),
                       ["answer_relevance", "structure", "conciseness", "questions_asked"])
    }

    func testAssembleLayersBaseOverlayAndHistory() throws {
        try store.ensureDefaults()
        let prompt = try store.assembleSystemPrompt(
            roundType: .behavioral,
            historyTags: [("rambling_intro", 3), ("no_quantified_impact", 1)])
        XCTAssertTrue(prompt.contains("STAR"))                      // overlay present
        XCTAssertTrue(prompt.contains("weakness_tags"))             // base rubric present
        XCTAssertTrue(prompt.contains("- rambling_intro (x3)"))     // history present
        let starIndex = prompt.range(of: "STAR")!.lowerBound
        let historyIndex = prompt.range(of: "rambling_intro (x3)")!.lowerBound
        XCTAssertLessThan(starIndex, historyIndex, "history section comes last")
    }

    func testAssembleWithEmptyHistory() throws {
        try store.ensureDefaults()
        let prompt = try store.assembleSystemPrompt(roundType: .technical, historyTags: [])
        XCTAssertTrue(prompt.contains("No prior session history"))
    }

    func testAssembleAppendsCustomInstructionsWithPrecedence() throws {
        try store.ensureDefaults()
        let prompt = try store.assembleSystemPrompt(
            roundType: .behavioral, historyTags: [],
            customInstructions: "Focus on staff-level scope.")
        XCTAssertTrue(prompt.contains("Focus on staff-level scope."))
        XCTAssertTrue(prompt.contains("Criteria for THIS interview"))
        XCTAssertTrue(prompt.contains("Where they conflict"))
        XCTAssertLessThan(prompt.range(of: "weakness_tags")!.lowerBound,
                          prompt.range(of: "Criteria for THIS interview")!.lowerBound,
                          "criteria section comes after the base rubric")
    }

    func testAssembleOmitsCriteriaSectionWhenEmptyOrWhitespace() throws {
        try store.ensureDefaults()
        let prompt = try store.assembleSystemPrompt(
            roundType: .behavioral, historyTags: [], customInstructions: "   \n  ")
        XCTAssertFalse(prompt.contains("Criteria for THIS interview"))
    }

    func testAvailableRoundTypesDiscoversFilesBuiltinsFirst() throws {
        try store.ensureDefaults()
        try "custom".write(to: dir.appendingPathComponent("take_home_review.md"), atomically: true, encoding: .utf8)
        try "custom".write(to: dir.appendingPathComponent("bar_raiser.md"), atomically: true, encoding: .utf8)
        try "not a prompt".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.availableRoundTypes(), [
            .recruiterScreen, .behavioral, .technical, .systemDesign, .productSense, .techDeepDive,  // builtins, fixed order
            RoundType(rawValue: "bar_raiser"), RoundType(rawValue: "take_home_review"),  // customs, alphabetical
        ])  // base.md excluded, non-.md files excluded
    }

    func testAvailableRoundTypesEmptyDirectory() {
        XCTAssertEqual(store.availableRoundTypes(), [])
    }

    func testAssembleFallsBackToBaseWhenOverlayMissing() throws {
        try store.ensureDefaults()
        let prompt = try store.assembleSystemPrompt(
            roundType: RoundType(rawValue: "deleted_custom_type"), historyTags: [])
        XCTAssertTrue(prompt.contains("weakness_tags"))          // base rubric present
        XCTAssertTrue(prompt.contains("No prior session history"))
    }
}
