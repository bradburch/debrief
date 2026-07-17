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

    func testEnsureDefaultsWritesAllFilesAndKeepsUserEdits() throws {
        try store.ensureDefaults()
        for name in ["base.md", "behavioral.md", "technical.md", "recruiter_screen.md", "system_design.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
        // A user edit to a prompt that still declares its dimensions is untouchable.
        let edited = DefaultPrompts.base.replacingOccurrences(of: "elite interview coach",
                                                              with: "brutally honest interview coach")
        try edited.write(to: dir.appendingPathComponent("base.md"), atomically: true, encoding: .utf8)
        try store.ensureDefaults()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("base.md"), encoding: .utf8), edited)
    }

    func testWholesaleRewrittenBaseIsUpgradedButPreserved() throws {
        // Narrowing of the old "never overwrites" contract, deliberately: a base.md with no
        // `## Scored dimensions` cannot work — dimensions(for:) throws on it, so every debrief
        // would fail. Replacing it (with the original kept as .bak) beats leaving the app
        // broken with the user's text intact but unusable.
        try store.ensureDefaults()
        try "MY CUSTOM PROMPT".write(to: dir.appendingPathComponent("base.md"), atomically: true, encoding: .utf8)
        try store.ensureDefaults()
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("base.md"), encoding: .utf8)
            .contains(PromptStore.dimensionsHeading))
        let backup = dir.appendingPathComponent("base.md").appendingPathExtension("pre-dimensions.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "MY CUSTOM PROMPT")
    }

    /// The pre-PR base.md, verbatim in shape: scored dimensions described in prose, no
    /// `## Scored dimensions` heading. This is what is sitting on disk for every user who has
    /// ever launched Debrief, and ensureDefaults used to skip it.
    private static let legacyBase = """
    # Debrief interview coach — base rubric

    Evaluate these shared dimensions, scored 1-5 (1 = serious problem, 3 = adequate, 5 = excellent):
    - answer_relevance: did the candidate answer the question actually asked, or drift?
    - structure: were answers organized?

    Base weakness tag vocabulary:
    rambling_intro, buried_lede
    """

    func testUpgradesLegacyPromptsThatPredateScoredDimensions() throws {
        try Self.legacyBase.write(to: dir.appendingPathComponent("base.md"), atomically: true, encoding: .utf8)
        try store.ensureDefaults()

        // Without the upgrade this returns [] → an empty scores schema → 0.0-average debriefs
        // on the Anthropic path and a failure on every local-LLM debrief.
        let dims = try store.dimensions(for: .technical)
        XCTAssertTrue(dims.contains("answer_relevance"))
        XCTAssertTrue(dims.contains("correctness"))

        // The old file is preserved, not silently destroyed.
        let backup = dir.appendingPathComponent("base.md").appendingPathExtension("pre-dimensions.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), Self.legacyBase)
    }

    func testUpgradeLeavesCurrentContractPromptsAlone() throws {
        try store.ensureDefaults()
        // A current-contract file the user has since edited must never be clobbered.
        let edited = DefaultPrompts.base + "\n\nMY OWN NOTE\n"
        try edited.write(to: dir.appendingPathComponent("base.md"), atomically: true, encoding: .utf8)
        try store.ensureDefaults()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("base.md"), encoding: .utf8), edited)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("base.md").appendingPathExtension("pre-dimensions.bak").path))
    }

    func testCustomRoundTypeWithoutDimensionsIsNotTouched() throws {
        try store.ensureDefaults()
        let custom = dir.appendingPathComponent("take_home_review.md")
        let text = "# My own round\n\nJust focus prose, no dimensions section.\n"
        try text.write(to: custom, atomically: true, encoding: .utf8)
        try store.ensureDefaults()
        // Not a builtin we ship — the upgrade must leave it alone, and it still coaches on
        // base's dimensions alone.
        XCTAssertEqual(try String(contentsOf: custom, encoding: .utf8), text)
        XCTAssertEqual(try store.dimensions(for: RoundType(rawValue: "take_home_review")),
                       ["answer_relevance", "structure", "conciseness", "questions_asked"])
    }

    func testEmptyDimensionsThrowsRatherThanScoringNothing() throws {
        try store.ensureDefaults()
        // A user who strips the section out of base.md must get a loud, retryable failure —
        // not a silently stored 0.0 debrief.
        try "# base\n\nno dimensions here\n".write(to: dir.appendingPathComponent("base.md"),
                                                  atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.dimensions(for: RoundType(rawValue: "nonexistent"))) { error in
            XCTAssertEqual(error as? PromptError, .noScoredDimensions(round: "nonexistent"))
        }
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
