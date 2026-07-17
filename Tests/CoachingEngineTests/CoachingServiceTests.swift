import XCTest
@testable import CoachingEngine
import Store

struct StubLLM: CoachingLLM {
    let result: Result<CoachingResult, ClaudeError>
    func generateCoaching(systemPrompt: String, userMessage: String,
                          dimensions: [String]) async throws -> CoachingResult {
        // Assert prompt layering happened by embedding markers.
        guard systemPrompt.contains("weakness_tags") else { throw ClaudeError.emptyResponse }
        guard userMessage.contains("THEM:") || userMessage.contains("YOU:") else { throw ClaudeError.emptyResponse }
        return try result.get()
    }
}

struct RequireMarkerLLM: CoachingLLM {
    let marker: String
    func generateCoaching(systemPrompt: String, userMessage: String,
                          dimensions: [String]) async throws -> CoachingResult {
        guard systemPrompt.contains(marker) else { throw ClaudeError.emptyResponse }
        return CoachingResult(proseDebrief: "ok",
                              scores: Dictionary(uniqueKeysWithValues: dimensions.map { ($0, 3) }),
                              advancement: .leanYes, advancementRationale: "ok",
                              weaknessTags: [], highlights: [], actionItems: [])
    }
}

/// Throws the error a torn-down URLSession call throws when the user hits Stop.
struct CancellingLLM: CoachingLLM {
    func generateCoaching(systemPrompt: String, userMessage: String,
                          dimensions: [String]) async throws -> CoachingResult {
        throw URLError(.cancelled)
    }
}

/// Captures the dimensions the service resolved for a round, so a test can assert the
/// overlay's declared dimensions actually reach the client.
final class CapturingLLM: CoachingLLM, @unchecked Sendable {
    var seenDimensions: [String] = []
    func generateCoaching(systemPrompt: String, userMessage: String,
                          dimensions: [String]) async throws -> CoachingResult {
        seenDimensions = dimensions
        return CoachingResult(proseDebrief: "ok",
                              scores: Dictionary(uniqueKeysWithValues: dimensions.map { ($0, 3) }),
                              advancement: .strongNo, advancementRationale: "ok",
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
                       advancement: .leanNo, advancementRationale: "Stories had no result.",
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
        // The verdict is the headline signal — it must survive the round-trip, and must NOT
        // be recomputed from overallScore (3.25 would round to a "yes"; the model said no).
        XCTAssertEqual(detail.feedback?.advancementValue, .leanNo)
        XCTAssertEqual(detail.feedback?.advancementRationale, "Stories had no result.")
    }

    func testCancellingARerunLeavesTheSessionCompleteNotFailed() async throws {
        let id = try seedSession()
        // Give the session a good debrief first, the way a real re-run would find it.
        try await CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(goodResult())))
            .coach(sessionId: id)
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .complete)

        // Hitting Stop tears down the in-flight request. That is not a failed debrief: the
        // session still holds its previous feedback, and flipping it to `failed` would show a
        // spurious error badge and drag it into "Retry pending debriefs".
        let stopped = CoachingService(db: db, prompts: prompts, llm: CancellingLLM())
        do { try await stopped.coach(sessionId: id); XCTFail("expected throw") }
        catch { XCTAssertTrue(CoachingService.isCancellation(error)) }

        let after = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertEqual(after.session.coachingStatus, .complete, "Stop marked a good session failed")
        XCTAssertEqual(after.feedback?.proseDebrief, "Decent.", "previous debrief was lost")
    }

    func testCancelledRerunIsNotReportedAsAFailure() async throws {
        _ = try seedSession()
        // recoachAll surfaces per-session errors to the UI; a cancellation must not appear
        // there, or Stop would always read as "1 failed".
        let errors = await CoachingService(db: db, prompts: prompts, llm: CancellingLLM()).recoachAll()
        XCTAssertTrue(errors.isEmpty, "cancellation reported as a session failure: \(errors)")
    }

    func testRealFailuresAreStillMarkedFailed() async throws {
        // The guard must be narrow: a refusal is a genuine failure and must stay retryable.
        let id = try seedSession()
        let service = CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .failure(.refusal)))
        do { try await service.coach(sessionId: id); XCTFail("expected throw") } catch {}
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .failed)
    }

    func testProcessNotesPersistAndDefaultEmpty() async throws {
        let id = try seedSession()
        var result = goodResult()
        result.processNotes = [Highlight(t: "00:41:05", note: "Two more rounds; decision by Friday.")]
        try await CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(result)))
            .coach(sessionId: id)
        let f = try XCTUnwrap(db.sessionDetail(id: id)?.feedback)
        let notes = try JSONDecoder().decode([Highlight].self, from: Data(f.processNotesJSON.utf8))
        XCTAssertEqual(notes.first?.note, "Two more rounds; decision by Friday.")
        XCTAssertEqual(notes.first?.t, "00:41:05")

        // The common case: nobody mentioned the process. Must round-trip as a valid empty
        // list, since the pipeline query treats "[]" as "nothing to show".
        try await CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(goodResult())))
            .coach(sessionId: id)
        let empty = try XCTUnwrap(db.sessionDetail(id: id)?.feedback)
        XCTAssertEqual(empty.processNotesJSON, "[]")
    }

    func testPipelineGathersProcessNotesNewestRoundFirst() async throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        var ids: [Int64] = []
        for (i, round) in [RoundType.recruiterScreen, .behavioral].enumerated() {
            let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: round,
                                               date: Date().addingTimeInterval(Double(i) * 86_400),
                                               durationSeconds: 60, contextNotes: "",
                                               coachingStatus: .pending))
            try db.insertSegments([.init(id: nil, sessionId: s.id!, speaker: .you, tStart: 1, text: "hi")])
            ids.append(s.id!)
        }
        for (i, id) in ids.enumerated() {
            var r = goodResult()
            r.processNotes = [Highlight(t: "00:0\(i):00", note: "note from round \(i)")]
            try await CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(r)))
                .coach(sessionId: id)
        }
        let pipe = try XCTUnwrap(db.pipeline().first { $0.company.id == co.id })
        XCTAssertEqual(pipe.processNotesJSON.count, 2)
        // Newest round first — the latest word on the process is the one that still applies.
        XCTAssertEqual(pipe.processNotesJSON.first?.roundType, .behavioral)
        XCTAssertTrue(pipe.processNotesJSON.first!.json.contains("round 1"))
    }

    func testPipelineOmitsCompaniesWithNoProcessNotes() throws {
        let co = try db.fetchOrCreateCompany(named: "Quiet")
        _ = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                       date: Date(), durationSeconds: 60, contextNotes: "",
                                       coachingStatus: .pending))
        let pipe = try XCTUnwrap(db.pipeline().first { $0.company.id == co.id })
        // An uncoached session has NULL processNotesJSON; a coached-but-silent one has "[]".
        // Neither may render an empty "Process & next steps" block.
        XCTAssertTrue(pipe.processNotesJSON.isEmpty)
    }

    func testRoundSpecificDimensionsReachTheClient() async throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .productSense,
                                           date: Date(), durationSeconds: 1800, contextNotes: "",
                                           coachingStatus: .pending))
        try db.insertSegments([.init(id: nil, sessionId: s.id!, speaker: .you, tStart: 1, text: "hi")])
        let llm = CapturingLLM()
        try await CoachingService(db: db, prompts: prompts, llm: llm).coach(sessionId: s.id!)
        // The overlay's declared dimensions, not a hardcoded set, decide the response contract.
        XCTAssertTrue(llm.seenDimensions.contains("mission_framing"), "\(llm.seenDimensions)")
        XCTAssertTrue(llm.seenDimensions.contains("success_metrics"), "\(llm.seenDimensions)")
        XCTAssertFalse(llm.seenDimensions.contains("correctness"), "leaked another round's dimension")
    }

    func testRecoachAllReportsProgress() async throws {
        for i in 0..<3 {
            let co = try db.fetchOrCreateCompany(named: "Co\(i)")
            let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                               date: Date(), durationSeconds: 60, contextNotes: "",
                                               coachingStatus: .pending))
            try db.insertSegments([.init(id: nil, sessionId: s.id!, speaker: .you, tStart: 1, text: "hi")])
        }
        let service = CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(goodResult())))
        actor Log { var seen: [(Int, Int)] = []; func add(_ p: (Int, Int)) { seen.append(p) } }
        let log = Log()
        _ = await service.recoachAll { done, total in
            Task { await log.add((done, total)) }
        }
        // Give the detached logging tasks a beat to land.
        try await Task.sleep(nanoseconds: 100_000_000)
        let seen = await log.seen
        // Total is published BEFORE the first slow call, so the bar starts determinate at 0/3
        // rather than jumping once the first ~30s debrief lands.
        XCTAssertEqual(seen.first?.0, 0)
        XCTAssertEqual(seen.first?.1, 3)
        XCTAssertEqual(seen.last?.0, 3, "final progress must reach the total")
        XCTAssertEqual(seen.map(\.0), [0, 1, 2, 3], "progress must advance once per session, in order")
    }

    func testRecoachAllProgressAdvancesEvenWhenASessionFails() async throws {
        let id = try seedSession()
        // A failing debrief must still advance the bar, or a run with one bad session
        // looks stuck forever.
        let service = CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .failure(.refusal)))
        actor Log { var last = -1; func set(_ v: Int) { last = v } }
        let log = Log()
        let errors = await service.recoachAll { done, _ in Task { await log.set(done) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.keys.first, id)
        let last = await log.last
        XCTAssertEqual(last, 1, "progress stalled on a failed session")
    }

    func testRecoachAllRerunsAlreadyCompleteSessions() async throws {
        let id = try seedSession()
        let service = CoachingService(db: db, prompts: prompts, llm: StubLLM(result: .success(goodResult())))
        try await service.coach(sessionId: id)
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .complete)
        // retryAllPending skips complete sessions, so a rubric change would never reach them.
        let retryErrors = await service.retryAllPending()
        XCTAssertTrue(retryErrors.isEmpty)

        let fresh = CoachingService(db: db, prompts: prompts, llm: RequireMarkerLLM(marker: "weakness_tags"))
        let recoachErrors = await fresh.recoachAll()
        XCTAssertTrue(recoachErrors.isEmpty)
        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertEqual(detail.feedback?.proseDebrief, "ok", "complete session was not re-coached")
        XCTAssertEqual(detail.tags, [], "stale tags must be replaced, not accumulated")
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
