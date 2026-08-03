import XCTest
@testable import CoachingEngine
import Store

/// Real `claude -p` invocation against the installed Claude Code CLI.
///
/// This is the only check that the subscription path actually satisfies the response
/// contract. The CLI has no JSON schema, so the contract is enforced by prompt text plus a
/// key-set check — exactly the class of bug a mocked test cannot catch, and the same reason
/// `CoachingIntegrationTests` exists for the Anthropic client.
///
/// Run explicitly: DEBRIEF_RUN_INTEGRATION=1 swift test --filter ClaudeCodeCLIIntegrationTests
/// Skipped unless DEBRIEF_RUN_INTEGRATION=1. Consumes real Claude subscription quota.
final class ClaudeCodeCLIIntegrationTests: XCTestCase {
    func testRealCLIReturnsAContractValidDebrief() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEBRIEF_RUN_INTEGRATION"] == "1")
        let cli = try XCTUnwrap(ClaudeCodeCLIClient.locate(), "Claude Code CLI not installed")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompts = PromptStore(directory: dir)
        try prompts.ensureDefaults()

        // Use the real assembled prompt and real dimensions, not a toy pair — the failure
        // mode being tested is the model ignoring the declared key set.
        let dimensions = try prompts.dimensions(for: .behavioral)
        XCTAssertFalse(dimensions.isEmpty, "no dimensions to enforce — test would be vacuous")
        let system = try prompts.assembleSystemPrompt(roundType: .behavioral,
                                                      historyTags: [], customInstructions: "")

        let client = ClaudeCodeCLIClient(executable: cli, timeout: 600)
        let result = try await client.generateCoaching(
            systemPrompt: system,
            userMessage: """
                Interview metadata:
                - Company: Acme
                - Round type: Behavioral
                - Duration: 5 minutes

                Transcript:
                THEM: Tell me about a time you disagreed with a teammate.
                YOU: Um, so, there was this one time, we disagreed about the database. I \
                thought Postgres, he thought Mongo. We talked about it. It worked out fine.
                THEM: What was the outcome for the project?
                YOU: Yeah it was fine, we shipped it.
                """,
            dimensions: dimensions)

        // The contract, checked the way the schema would have.
        XCTAssertEqual(Set(result.scores.keys), Set(dimensions),
                       "CLI returned the wrong dimension keys — the prose contract failed")
        for (key, score) in result.scores {
            XCTAssertTrue((1...5).contains(score), "\(key) scored \(score), outside 1–5")
        }
        XCTAssertFalse(result.proseDebrief.isEmpty)
        XCTAssertNotEqual(result.proseDebrief, OpenAICompatibleClient.exampleProse,
                          "model echoed the format appendix example instead of answering")
        XCTAssertTrue(Advancement.allCases.contains(result.advancement))
        // A transcript this thin should not read as a strong pass; guards against a model
        // that returns well-formed JSON without actually reading the transcript.
        XCTAssertLessThan(result.overallScore, 4.5, "implausibly high score for a vague transcript")
    }
}
