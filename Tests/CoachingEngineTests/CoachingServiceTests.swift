import XCTest
@testable import CoachingEngine
import Store

struct StubLLM: CoachingLLM {
    let result: Result<CoachingResult, ClaudeError>
    func generateCoaching(systemPrompt: String, userMessage: String) async throws -> CoachingResult {
        // Assert prompt layering happened by embedding markers.
        guard systemPrompt.contains("weakness_tags") else { throw ClaudeError.emptyResponse }
        guard userMessage.contains("THEM:") || userMessage.contains("YOU:") else { throw ClaudeError.emptyResponse }
        return try result.get()
    }
}

struct RequireMarkerLLM: CoachingLLM {
    let marker: String
    func generateCoaching(systemPrompt: String, userMessage: String) async throws -> CoachingResult {
        guard systemPrompt.contains(marker) else { throw ClaudeError.emptyResponse }
        return CoachingResult(proseDebrief: "ok",
                              scores: ["answer_relevance": 3, "structure": 3, "conciseness": 3, "questions_asked": 3],
                              weaknessTags: [], highlights: [], actionItems: [])
    }
}

final class CoachingServiceTests: XCTestCase {
    var db: AppDatabase!
    var prompts: PromptStore!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prompts = PromptStore(directory: dir)
        try prompts.ensureDefaults()
    }

    func seedSession() throws -> Int64 {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                           date: Date(), durationSeconds: 1800, contextNotes: "onsite",
                                           coachingStatus: .pending))
        try db.insertSegments([
            .init(id: nil, sessionId: s.id!, speaker: .them, tStart: 10, text: "Walk me through your resume."),
            .init(id: nil, sessionId: s.id!, speaker: .you, tStart: 15, text: "Sure, so, um, I started..."),
        ])
        return s.id!
    }

    func goodResult() -> CoachingResult {
        CoachingResult(proseDebrief: "Decent.",
                       scores: ["answer_relevance": 4, "structure": 2, "conciseness": 3, "questions_asked": 4],
                       weaknessTags: ["rambling_intro"],
                       highlights: [Highlight(t: "00:00:15", note: "ok")],
                       actionItems: ["Practice intro"])
    }

    func testCoachPersistsFeedbackAndTags() async throws {
        let id = try seedSession()
        let service = CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(goodResult())))
        try await service.coach(sessionId: id)
        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertEqual(detail.session.coachingStatus, .complete)
        XCTAssertEqual(detail.feedback?.proseDebrief, "Decent.")
        XCTAssertEqual(detail.feedback?.overallScore ?? 0, 3.25, accuracy: 0.001)
        XCTAssertEqual(detail.tags, ["rambling_intro"])
        let scores = try JSONDecoder().decode([String: Int].self,
                                              from: detail.feedback!.scoresJSON.data(using: .utf8)!)
        XCTAssertEqual(scores["structure"], 2)
    }

    func testCoachFailureMarksFailedAndRethrows() async throws {
        let id = try seedSession()
        let service = CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .failure(.refusal)))
        do { try await service.coach(sessionId: id); XCTFail("expected throw") }
        catch let e as ClaudeError { XCTAssertEqual(e, .refusal) }
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .failed)
    }

    func testRetryAllPendingCoachesFailedAndPending() async throws {
        let id = try seedSession()
        try db.markCoachingFailed(sessionId: id)
        let service = CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(goodResult())))
        let errors = await service.retryAllPending()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .complete)
    }

    func testCoachForwardsCustomInstructionsIntoSystemPrompt() async throws {
        let id = try seedSession()
        try db.updateSessionCriteria(id: id, "GRADE_MARKER_XYZ")
        let service = CoachingService(db: db, prompts: prompts, llm: RequireMarkerLLM(marker: "GRADE_MARKER_XYZ"))
        try await service.coach(sessionId: id)  // throws emptyResponse if the marker never reached the system prompt
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .complete)
    }
}
