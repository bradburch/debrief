import XCTest
@testable import CoachingEngine
import Store

/// Hits the real Anthropic API with the real prompts. Nothing else proves the dynamically
/// built JSON schema is one the API accepts — mocked tests happily pass against a schema the
/// API rejects with a 400 (range keywords on integer types were exactly that bug) — nor that
/// the rubric actually elicits what it asks for.
///
/// Run explicitly: ANTHROPIC_API_KEY=… DEBRIEF_RUN_INTEGRATION=1 swift test --filter CoachingIntegrationTests
/// Skipped unless DEBRIEF_RUN_INTEGRATION=1.
final class CoachingIntegrationTests: XCTestCase {
    /// Strong delivery, mediocre substance: clarifying questions, clean think-aloud, correct
    /// brute force, self-traced — but three escalating hints to reach the hash map, no Big-O,
    /// optimal solution never written. The profile the delivery-only rubric scored 4.25 (green)
    /// and a real interviewer would not advance. Also states NO process, so it doubles as the
    /// negative case for process_notes.
    static let codingTranscript = """
    [00:00:05] THEM: Given an array of integers, find two numbers that add up to a target.
    [00:00:12] YOU: Sure. Let me make sure I understand — the array is unsorted, and I should
    return the indices of the two numbers. Can there be duplicates, and is exactly one
    solution guaranteed?
    [00:00:28] THEM: Unsorted, return indices, assume exactly one solution.
    [00:00:35] YOU: Got it. Let me think out loud. The straightforward approach is to check
    every pair — for each element, scan the rest of the array for its complement. Let me start
    there and we can refine.
    [00:01:10] YOU: def two_sum(nums, target):
    [00:01:15] YOU:     for i in range(len(nums)):
    [00:01:20] YOU:         for j in range(i+1, len(nums)):
    [00:01:25] YOU:             if nums[i] + nums[j] == target: return [i, j]
    [00:01:40] YOU: That's correct — it checks every pair exactly once and returns the indices.
    Let me trace it on [2,7,11,15] with target 9: i=0, j=1, 2+7=9, returns [0,1]. Correct.
    [00:02:20] THEM: Good. Can you do better than that?
    [00:02:25] YOU: Hmm. Let me think about that for a moment.
    [00:02:50] YOU: I could sort the array first and use two pointers from each end. That would
    be faster than checking every pair.
    [00:03:05] THEM: What happens to the indices if you sort?
    [00:03:12] YOU: Right, good point, sorting loses the original positions. I'd need to keep
    track of them somehow. Maybe store pairs of value and index before sorting.
    [00:03:40] THEM: Is there a way to do it in one pass?
    [00:03:48] YOU: One pass... I'm not immediately seeing it. Could you give me a nudge?
    [00:03:55] THEM: Think about what you'd want to look up as you walk the array.
    [00:04:10] YOU: Oh — a hash map. As I go, I store each number I've seen, and check whether
    the complement is already in the map. That would be one pass.
    [00:04:30] THEM: What's the complexity of that?
    [00:04:35] YOU: The hash map one would be faster than the nested loops, since I'm not
    rescanning. I'd have to think about the exact big-O.
    [00:04:50] YOU: I'd probably go with the hash map version in production. Should I code it up?
    [00:05:00] THEM: We're about out of time. Any questions for me?
    [00:05:05] YOU: Yes — how does the team balance shipping speed against code review depth?
    And what does the first 90 days look like for someone in this role?
    """

    /// A recruiter laying out the process explicitly: round count, each round's content, a
    /// named final interviewer, a follow-up cadence, a deadline, and an ask of the candidate.
    static let processTranscript = """
    [00:00:05] THEM: Thanks for making time. I'm a recruiter here at Acme.
    [00:00:20] YOU: Happy to be here. I've been a backend engineer for six years, most
    recently at Globex where I owned the billing platform.
    [00:00:50] THEM: Great. Let me walk you through what's next. There are three more
    rounds after this one: a coding screen next week, then a system design round, and
    finally a panel with the VP of Engineering, Dana Liu.
    [00:01:20] THEM: The coding screen is 60 minutes in CoderPad, Python or Go.
    [00:01:35] YOU: Got it. When would the coding screen be scheduled?
    [00:01:42] THEM: I'll send times for Tuesday or Wednesday. We want to close the loop
    by end of month, and I'll get back to you with feedback within two business days of
    each round.
    [00:02:10] THEM: One thing I need from you — send me your GitHub link by Friday, the
    hiring manager wants to look at it before the coding screen.
    [00:02:30] YOU: Will do. What's the comp band for the role?
    [00:02:35] THEM: It's 180 to 210 base, plus equity.
    [00:02:50] YOU: That works for me.
    """

    private func coach(_ transcript: String, round: RoundType) async throws -> CoachingResult {
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
                                "set ANTHROPIC_API_KEY")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PromptStore(directory: dir)
        try store.ensureDefaults()
        return try await AnthropicClient(apiKey: key).generateCoaching(
            systemPrompt: try store.assembleSystemPrompt(roundType: round, historyTags: []),
            userMessage: "Round type: \(round.displayName)\n\nTranscript:\n\(transcript)",
            dimensions: try store.dimensions(for: round))
    }

    func testRealAPIAcceptsRoundSpecificSchemaAndSeparatesVerdictFromDelivery() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEBRIEF_RUN_INTEGRATION"] == "1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PromptStore(directory: dir)
        try store.ensureDefaults()
        let dims = try store.dimensions(for: .technical)

        let result = try await coach(Self.codingTranscript, round: .technical)

        // The API accepted the schema and pinned this round's dimensions.
        XCTAssertEqual(Set(result.scores.keys), Set(dims))
        // The point of the rubric: substance is scored below delivery on this transcript, and
        // the verdict follows substance rather than the flattering average.
        XCTAssertFalse(result.advancement.advances,
                       "verdict tracked delivery, not substance — got \(result.advancement.rawValue)")
        XCTAssertLessThan(result.scores["correctness"]!, result.scores["conciseness"]!,
                          "correctness should not outscore delivery on a brute-force-only answer")
        XCTAssertFalse(result.advancementRationale.isEmpty)
        // This transcript's only close is "any questions for me?" — no process, no timeline.
        // The rubric must not manufacture next steps out of a polite sign-off.
        XCTAssertTrue(result.processNotes.isEmpty,
                      "invented process notes from a transcript with none: \(result.processNotes)")
    }

    /// The other half of the process_notes contract: when the interviewer DOES lay out the
    /// process, it should be captured with its specifics rather than paraphrased into mush.
    ///
    /// THIS TEST IS A RECALL PROBE AND CAN FLAKE. Extraction recall is a model behaviour, not a
    /// branch — measured misses on this transcript at roughly 2 in 7 before the prompt was
    /// rebalanced (the instruction spent three sentences on *not* inventing notes and one on
    /// capturing them, which suppressed recall; the guard now sits after the positive
    /// instruction, not in front of it). A failure here means "recall regressed or is having a
    /// bad day", not "the build is broken" — re-run before believing it, and treat a
    /// consistent failure as a prompt regression worth bisecting.
    ///
    /// Deliberately not weakened to always-pass: a probe that cannot fail measures nothing.
    /// It is opt-in (DEBRIEF_RUN_INTEGRATION) and excluded from `--skip IntegrationTests`, so
    /// it never flakes the default suite.
    func testRealAPIExtractsProcessNotesWhenStated() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEBRIEF_RUN_INTEGRATION"] == "1")
        let result = try await coach(Self.processTranscript, round: .recruiterScreen)

        XCTAssertFalse(result.processNotes.isEmpty, "stated process was not captured")
        let blob = result.processNotes.map(\.note).joined(separator: " ").lowercased()
        // The specifics a candidate would actually plan around.
        XCTAssertTrue(blob.contains("friday"), "missed the GitHub-by-Friday ask: \(blob)")
        XCTAssertTrue(blob.contains("panel") || blob.contains("dana"), "missed the final round: \(blob)")
        XCTAssertTrue(blob.contains("three") || blob.contains("3"), "missed the round count: \(blob)")
        for n in result.processNotes {
            XCTAssertTrue(n.t.contains(":"), "process note lacks a real timestamp: \(n)")
        }
        print("PROCESS NOTES:")
        for n in result.processNotes { print("  \(n.t)  \(n.note)") }
    }
}
