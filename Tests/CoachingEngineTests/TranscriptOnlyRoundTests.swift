import XCTest
@testable import CoachingEngine
import Store

/// An LLM that fails the test if it is ever called. A transcript-only round reaching the
/// model is the whole bug this feature exists to prevent, and it would bill a real API
/// call per practice session.
struct NeverCalledLLM: CoachingLLM {
    func generateCoaching(systemPrompt: String, userMessage: String,
                          dimensions: [String]) async throws -> CoachingResult {
        XCTFail("transcript-only round was sent to the LLM")
        throw ClaudeError.emptyResponse
    }
}

final class TranscriptOnlyRoundTests: XCTestCase {
    var db: AppDatabase!
    var prompts: PromptStore!
    var dir: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prompts = PromptStore(directory: dir)
        try prompts.ensureDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func seedSession(roundType: RoundType) throws -> Int64 {
        let company = try db.fetchOrCreateCompany(named: "Acme")
        let session = try db.insertSession(.init(id: nil, companyId: company.id!, roundType: roundType,
                                                 date: Date(), durationSeconds: 1800,
                                                 contextNotes: "", coachingStatus: .pending))
        try db.insertSegments([
            .init(id: nil, sessionId: session.id!, speaker: .them, tStart: 10, text: "Tell me about yourself."),
            .init(id: nil, sessionId: session.id!, speaker: .you, tStart: 15, text: "Sure, I started out..."),
        ])
        return session.id!
    }

    // MARK: - Marker parsing

    func testMarkerInMetadataBlockIsDetected() {
        XCTAssertTrue(PromptStore.parseTranscriptOnly("transcript-only: true\n\n# Overlay: mock"))
        XCTAssertTrue(PromptStore.parseTranscriptOnly("  Transcript-Only:  TRUE  \n# Overlay"))
    }

    func testAbsentOrFalseMarkerScores() {
        XCTAssertFalse(PromptStore.parseTranscriptOnly("# Overlay: behavioral\n\nStuff."))
        XCTAssertFalse(PromptStore.parseTranscriptOnly("transcript-only: false\n\n# Overlay"))
    }

    /// Prose is not configuration. A rubric that discusses being transcript-only must not
    /// silently switch scoring off — that would be a hard bug to spot, since the round
    /// would simply stop producing debriefs.
    func testMarkerAfterAHeadingIsProseNotConfiguration() {
        let markdown = """
            # Overlay: behavioral

            Do not treat this as transcript-only: true is not meant here.
            """
        XCTAssertFalse(PromptStore.parseTranscriptOnly(markdown))
    }

    func testShippedMockInterviewPromptIsTranscriptOnly() {
        XCTAssertTrue(prompts.isTranscriptOnly(.mockInterview))
        XCTAssertFalse(prompts.isTranscriptOnly(.behavioral))
    }

    func testMockInterviewIsOfferedAsARoundType() {
        XCTAssertTrue(prompts.availableRoundTypes().contains(.mockInterview))
    }

    // MARK: - Toggling the marker

    func testSettingMarkerAddsRemovesAndDoesNotStack() {
        let plain = "# Overlay: thing\n\nBody."
        let on = PromptStore.settingTranscriptOnly(true, in: plain)
        XCTAssertTrue(PromptStore.parseTranscriptOnly(on))

        // Idempotent: saving twice must not produce two marker lines.
        let onTwice = PromptStore.settingTranscriptOnly(true, in: on)
        XCTAssertEqual(onTwice.components(separatedBy: "transcript-only:").count - 1, 1)

        let off = PromptStore.settingTranscriptOnly(false, in: onTwice)
        XCTAssertFalse(PromptStore.parseTranscriptOnly(off))
        XCTAssertTrue(off.hasPrefix("# Overlay: thing"), "body was mangled: \(off)")
    }

    // MARK: - Coaching behaviour

    func testTranscriptOnlyRoundIsSkippedNotCoached() async throws {
        let id = try seedSession(roundType: .mockInterview)
        let service = CoachingService(db: db, prompts: prompts, llm: NeverCalledLLM())

        try await service.coach(sessionId: id)

        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertEqual(detail.session.coachingStatus, .skipped)
        XCTAssertNil(detail.feedback, "a transcript-only round stored a debrief")
    }

    /// `skipped` is terminal. If it were treated like `pending`, every "Retry pending
    /// debriefs" would offer practice sessions forever.
    func testSkippedSessionsAreNotOfferedForRetryOrRecoach() async throws {
        let mockID = try seedSession(roundType: .mockInterview)
        let realID = try seedSession(roundType: .behavioral)
        try await CoachingService(db: db, prompts: prompts, llm: NeverCalledLLM()).coach(sessionId: mockID)

        let needing = try db.sessionsNeedingCoaching().map(\.id)
        XCTAssertFalse(needing.contains(mockID), "skipped session queued for retry")
        XCTAssertTrue(needing.contains(realID), "a genuinely pending session was dropped")

        let recoachable = try db.sessionsWithTranscript().map(\.id)
        XCTAssertFalse(recoachable.contains(mockID), "skipped session queued for re-coach")
        XCTAssertTrue(recoachable.contains(realID))
    }

    /// Retrying is what a user does after a failure; it must stay harmless for a mock.
    func testRetryAllPendingLeavesTranscriptOnlySessionsAlone() async throws {
        let id = try seedSession(roundType: .mockInterview)
        let service = CoachingService(db: db, prompts: prompts, llm: NeverCalledLLM())

        let errors = await service.retryAllPending()

        XCTAssertTrue(errors.isEmpty, "unexpected errors: \(errors)")
        // Still pending here rather than skipped: it was never selected, which is the point.
        // Coaching it directly is what marks it skipped, and that path is covered above.
        let status = try XCTUnwrap(db.sessionDetail(id: id)).session.coachingStatus
        XCTAssertNotEqual(status, .failed, "a transcript-only round was recorded as failed")
    }

    // MARK: - Editing round types

    func testNameNormalizationAndCollisionSafety() {
        XCTAssertEqual(PromptStore.normalizedRawValue(from: "Take Home Review"), "take_home_review")
        XCTAssertEqual(PromptStore.normalizedRawValue(from: "  Pair   Programming!  "), "pair_programming")
        XCTAssertNil(PromptStore.normalizedRawValue(from: "   "))
        XCTAssertNil(PromptStore.normalizedRawValue(from: "!!!"))
    }

    func testWriteAndDeleteRoundTripThroughTheTypeList() throws {
        let custom = RoundType(rawValue: "take_home_review")
        try prompts.write("transcript-only: true\n\n# Overlay: take home", for: custom)

        XCTAssertTrue(prompts.availableRoundTypes().contains(custom))
        XCTAssertTrue(prompts.isTranscriptOnly(custom))

        try prompts.delete(custom)
        XCTAssertFalse(prompts.availableRoundTypes().contains(custom))
    }

    /// base.md is the shared prompt every overlay builds on, not a selectable type.
    /// Deleting it would break every debrief, so the store refuses.
    func testDeletingBaseIsRefused() {
        XCTAssertThrowsError(try prompts.delete(RoundType(rawValue: "base"))) { error in
            XCTAssertEqual(error as? PromptError, .cannotDeleteBase)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("base.md").path))
    }

    func testSessionCountBacksTheDeleteGuard() throws {
        let custom = RoundType(rawValue: "take_home_review")
        try prompts.write("# Overlay: take home", for: custom)
        XCTAssertEqual(try db.sessionCount(forRoundType: custom), 0)

        _ = try seedSession(roundType: custom)
        XCTAssertEqual(try db.sessionCount(forRoundType: custom), 1)
    }
}
