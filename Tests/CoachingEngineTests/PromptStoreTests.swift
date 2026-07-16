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
