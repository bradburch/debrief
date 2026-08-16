import XCTest
import AVFoundation
import Combine
@testable import DebriefApp
import CaptureKit
import Store
import CoachingEngine
import Transcriber

// Regression test for the nested-ObservableObject gap: AppEnvironment wraps a
// `coordinator: RecordingCoordinator` (a plain `let`, not @Published), so
// SwiftUI views observing AppEnvironment never see coordinator's own
// @Published changes (phase, micLevel, systemLevel, streamWarning) unless
// AppEnvironment forwards coordinator.objectWillChange into its own.
final class FakeAlerts: CallAlerting {
    var detectedCount = 0
    var clearCount = 0
    func callDetected() { detectedCount += 1 }
    func clear() { clearCount += 1 }
}

@MainActor
final class AppEnvironmentTests: XCTestCase {
    /// Coordinator + env built exactly the way RecordingCoordinatorTests.makeCoordinator does.
    func makeEnv(db: AppDatabase, alerts: CallAlerting? = nil, root: URL? = nil,
                 transcriber: Transcribing = FakeTranscriber(textForChunk: "final"),
                 plan: RecorderPlan = RecorderPlan()) throws -> AppEnvironment {
        let root = try root ?? makeRoot()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let coaching = CoachingService(db: db, prompts: prompts, llm: OKStubLLM())
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: coaching,
            transcriber: transcriber,
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: plan.seconds, stopGate: plan.stopGate) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: plan.seconds, stopGate: plan.stopGate) },
            recordingsRoot: root,
            chunkDuration: 1.0)
        return AppEnvironment(db: db, prompts: prompts, coaching: coaching, coordinator: coordinator,
                              alerts: alerts, recordingsRoot: root)
    }

    /// An orphaned session directory with one chunk on each stream — what a crash leaves
    /// behind. Same shape RecoveryTests seeds.
    func seedOrphanDir(root: URL) throws -> URL {
        let dir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.writeManifest(.init(startedAt: Date(timeIntervalSinceNow: -300),
                                               finalized: false), in: dir)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        for prefix in ["mic", "sys"] {
            let writer = try WavChunkWriter(directory: dir, prefix: prefix, chunkDuration: 1.0)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000)!
            buf.frameLength = 16_000
            try writer.append(buf)
            try writer.finish()
        }
        return dir
    }

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Polls a main-actor condition. Needed because the recovery rescan is delivered
    /// asynchronously on the main queue — deliberately, see the sink in AppEnvironment.init.
    func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let satisfied = condition()
        XCTAssertTrue(satisfied, description)
    }

    func testCoordinatorPhaseChangeForwardsToEnvironmentObjectWillChange() async throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let coordinator = env.coordinator

        var fired = false
        let cancellable = env.objectWillChange.sink { _ in fired = true }
        defer { cancellable.cancel() }

        await coordinator.startRecording()

        XCTAssertTrue(
            fired,
            "AppEnvironment.objectWillChange should fire when the nested coordinator's @Published phase changes")
    }

    func testCallEndAutoStopsAndFinalizesRecording() async throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let t0 = Date()

        // Meeting app + mic → call starts immediately (no confirmation window).
        await env.pollDetection(.init(micInUse: true, meetingAppRunning: true), at: t0)
        XCTAssertTrue(env.callDetected)

        await env.coordinator.startRecording()
        env.recordCompany = "Acme"

        // Mic freed: first poll arms the 10s confirmation window — still recording.
        await env.pollDetection(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(60))
        guard case .recording = env.coordinator.recordingPhase else {
            return XCTFail("should still be recording inside the confirmation window")
        }

        // Confirmation elapsed → call ended → recording auto-stops and queues the debrief.
        await env.pollDetection(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(71))
        XCTAssertFalse(env.callDetected)
        guard case .idle = env.coordinator.recordingPhase else {
            return XCTFail("call end should stop the recording, got \(env.coordinator.recordingPhase)")
        }
        // The session lands when its finalize job does — auto-stop no longer waits for it.
        await env.coordinator.awaitAllFinalizes()
        let sessions = try db.allSessionSummaries()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.companyName, "Acme")
        XCTAssertEqual(env.recordCompany, "", "metadata should clear after auto-stop, like manual stop")
    }

    func testResolveLLMDispatchesOnProvider() {
        let d = UserDefaults.standard
        defer {
            d.removeObject(forKey: "coachingProvider")
            d.removeObject(forKey: "openAICompatBaseURL")
            d.removeObject(forKey: "openAICompatModel")
        }
        d.set("openai_compat", forKey: "coachingProvider")
        d.set("http://localhost:1234/v1", forKey: "openAICompatBaseURL")
        d.set("qwen2.5:14b", forKey: "openAICompatModel")
        XCTAssertTrue(AppEnvironment.resolveLLM() is OpenAICompatibleClient)

        d.set("anthropic", forKey: "coachingProvider")
        XCTAssertTrue(AppEnvironment.resolveLLM() is AnthropicClient)

        d.removeObject(forKey: "coachingProvider")  // default: anthropic
        XCTAssertTrue(AppEnvironment.resolveLLM() is AnthropicClient)
    }

    func testCallStartPostsAlertAndCallEndClearsIt() async throws {
        let db = try AppDatabase.inMemory()
        let alerts = FakeAlerts()
        let env = try makeEnv(db: db, alerts: alerts)
        let t0 = Date()

        // Call starts while idle → alert posted.
        await env.pollDetection(.init(micInUse: true, meetingAppRunning: true), at: t0)
        XCTAssertEqual(alerts.detectedCount, 1)
        XCTAssertEqual(alerts.clearCount, 0)

        // Call ends (mic free past the 10s confirmation) → alert cleared.
        await env.pollDetection(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(60))
        await env.pollDetection(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(71))
        XCTAssertEqual(alerts.clearCount, 1)
    }

    func testStartRecordingClearsDeliveredAlert() async throws {
        let db = try AppDatabase.inMemory()
        let alerts = FakeAlerts()
        let env = try makeEnv(db: db, alerts: alerts)

        await env.pollDetection(.init(micInUse: true, meetingAppRunning: true), at: Date())
        XCTAssertEqual(alerts.detectedCount, 1)

        await env.startRecording()
        XCTAssertEqual(alerts.clearCount, 1, "starting a recording should clear the call-detected notification")
        guard case .recording = env.coordinator.recordingPhase else {
            return XCTFail("startRecording() should start the coordinator, got \(env.coordinator.recordingPhase)")
        }
    }

    /// A call starting while an earlier session is still being debriefed now alerts, because
    /// the new session is recordable. The old single-phase check suppressed it, and the
    /// detector never re-fired once finalize ended.
    func testCallStartDuringFinalizeStillPostsAlert() async throws {
        let db = try AppDatabase.inMemory()
        let alerts = FakeAlerts()
        let env = try makeEnv(db: db, alerts: alerts)

        await env.coordinator.startRecording()
        _ = await env.coordinator.stopAndFinalize(metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        XCTAssertTrue(env.coordinator.hasActiveJobs)

        await env.pollDetection(.init(micInUse: true, meetingAppRunning: true), at: Date())
        XCTAssertEqual(alerts.detectedCount, 1, "a call detected during a finalize must still be offered")
        await env.coordinator.awaitAllFinalizes()
    }

    /// Stopping now takes as long as the recorder teardown and the last in-flight decode, and
    /// the next interview can be started and typed into during that window. The stop form has
    /// to be read and cleared before the wait, or it wipes what the user typed for the *new*
    /// recording — and the wiped fields are the company name of a live interview.
    func testStopClearsTheFormBeforeWaitingForTheStopToFinish() async throws {
        let db = try AppDatabase.inMemory()
        let gate = Gate()
        let plan = RecorderPlan()
        plan.seconds = 1
        plan.stopGate = gate
        await gate.hold("stop")
        let env = try makeEnv(db: db, plan: plan)

        await env.coordinator.startRecording()
        env.recordCompany = "Acme"
        env.recordNotes = "first call"
        let stopping = Task { await env.stopAndDebrief() }
        for _ in 0..<1000 where await gate.waitingCount == 0 { await Task.yield() }

        XCTAssertEqual(env.recordCompany, "", "the form must be cleared before the stop is waited on")
        XCTAssertEqual(env.recordNotes, "")
        // The user starts typing the next interview while the last one is still stopping.
        env.recordCompany = "Globex"

        await gate.open()
        await stopping.value
        XCTAssertEqual(env.recordCompany, "Globex", "the next recording's company was wiped by the previous stop")

        await env.coordinator.awaitAllFinalizes()
        let sessions = try db.allSessionSummaries()
        XCTAssertEqual(sessions.map(\.companyName), ["Acme"], "the stopped session kept the metadata it was stopped with")
    }

    /// A failed finalize has to put its directory back in the recovery banner: the failure
    /// message it shows tells the user to discard the audio from that very prompt.
    ///
    /// The rescan runs off a @Published signal, which Combine delivers synchronously *inside*
    /// the mutation — while `runFinalize` is still on the stack and its `defer` has not
    /// released the directory claim. Rescanning there sees the dir as still active and drops
    /// it, permanently: nothing else triggers another scan.
    func testFailedFinalizeReturnsItsDirectoryToTheRecoveryList() async throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot()
        let env = try makeEnv(db: db, root: root)

        // A manifest with no chunks: recoverable, and its finalize is guaranteed to fail.
        let dir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.writeManifest(.init(startedAt: Date(timeIntervalSinceNow: -300), finalized: false), in: dir)
        env.refreshRecoverables()
        XCTAssertEqual(env.recoverableSessions, [dir])

        await env.recover(dir, metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        XCTAssertTrue(env.recoverableSessions.isEmpty, "a claimed dir must leave the banner while it is worked on")

        await env.coordinator.awaitAllFinalizes()
        try await waitUntil("a failed finalize left its audio unreachable from the recovery prompt") {
            env.recoverableSessions == [dir]
        }
    }

    /// Recovery skips a directory whose transcript already landed — but a session ROW alone
    /// is not that. A crash between the session insert and the segment insert leaves an empty
    /// row, which the coaching sweeps skip for having no transcript; if recovery also skipped
    /// the directory, the interview would be unreachable by every path at once.
    func testRecoveryFiltersOnTheTranscriptNotOnTheSessionRow() async throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot()
        let env = try makeEnv(db: db, root: root)
        let company = try db.fetchOrCreateCompany(named: "Acme")

        func seedStampedDir(withTranscript: Bool) throws -> URL {
            let session = try db.insertSession(.init(
                id: nil, companyId: company.id!, roundType: .behavioral, date: Date(),
                durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
            if withTranscript {
                try db.insertSegments([.init(id: nil, sessionId: session.id!, speaker: .you,
                                             tStart: 0, text: "hello there")])
            }
            let dir = try RecordingStore.createSessionDirectory(root: root)
            try RecordingStore.writeManifest(.init(startedAt: Date(), finalized: false,
                                                   sessionId: session.id), in: dir)
            return dir
        }

        let transcribed = try seedStampedDir(withTranscript: true)
        let rowOnly = try seedStampedDir(withTranscript: false)
        env.refreshRecoverables()

        XCTAssertFalse(env.recoverableSessions.contains(transcribed),
                       "a dir whose transcript already landed must not be offered again")
        XCTAssertTrue(env.recoverableSessions.contains(rowOnly),
                      "a dir whose session row has no transcript is still the only copy of that interview")
    }

    /// `running` is not terminal: a process that dies mid-coach leaves the row in a state
    /// every sweep skips, so launch has to hand it back to the retry paths.
    func testLaunchResetsRunningCoachingToPending() async throws {
        let db = try AppDatabase.inMemory()
        let company = try db.fetchOrCreateCompany(named: "Acme")
        let session = try db.insertSession(InterviewSession(
            id: nil, companyId: company.id!, roundType: .behavioral, date: Date(),
            durationSeconds: 60, contextNotes: "", coachingStatus: .running))
        let id = try XCTUnwrap(session.id)

        _ = try makeEnv(db: db)  // launch-time work runs in AppEnvironment.init

        let after = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertEqual(after.session.coachingStatus, .pending)
    }

    /// The point of planning a call: everything typed in beforehand — round type, notes,
    /// role, and the grading criteria — is on the session row the finalize inserts, so it
    /// reaches the first debrief instead of only a re-coach.
    func testPlannedCallPreFillsTheStopFormAndReachesTheSession() async throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", role: "Staff iOS",
                                                  roundType: .technical, scheduledDate: Date(),
                                                  notes: "panel of two",
                                                  customInstructions: "GRADE_MARKER_XYZ"))
        env.refreshPlannedCalls()

        env.apply(plan)
        XCTAssertEqual(env.recordCompany, "Acme")
        XCTAssertEqual(env.recordRoundType, .technical)
        XCTAssertEqual(env.recordCriteria, "GRADE_MARKER_XYZ")
        // The role has no session column; it is folded into the notes the debrief reads.
        XCTAssertEqual(env.recordNotes, "Role: Staff iOS — panel of two")

        await env.coordinator.startRecording()
        await env.stopAndDebrief()
        await env.coordinator.awaitAllFinalizes()

        let summaries = try db.allSessionSummaries()
        XCTAssertEqual(summaries.count, 1)
        let session = try XCTUnwrap(summaries.first?.session)
        XCTAssertEqual(summaries.first?.companyName, "Acme")
        XCTAssertEqual(session.roundType, .technical)
        XCTAssertEqual(session.customInstructions, "GRADE_MARKER_XYZ")
        XCTAssertEqual(session.contextNotes, "Role: Staff iOS — panel of two")
        // Consumed once the finalize produced a session, and the form left clean.
        await env.awaitPlanConsumption()
        XCTAssertTrue(env.plannedCalls.isEmpty, "the recorded plan was never consumed")
        XCTAssertEqual(try db.plannedCalls().count, 0)
        XCTAssertEqual(env.recordCriteria, "")
    }

    /// A finalize that fails deletes the session row it had inserted and keeps the audio for
    /// recovery — so the plan has to survive too. Consuming it at stop would throw away the
    /// company, round type and criteria of a call that still needs recovering.
    func testFailedFinalizeKeepsThePlannedCallForTheRecovery() async throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot()
        // Every transcription throws -> no segments -> the finalize fails after inserting
        // the session row, then compensates it away.
        let env = try makeEnv(db: db, root: root, transcriber: ThrowingTranscriber())
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .technical,
                                                  scheduledDate: Date(),
                                                  customInstructions: "GRADE_MARKER_XYZ"))
        env.refreshPlannedCalls()
        env.apply(plan)

        await env.coordinator.startRecording()
        await env.stopAndDebrief()
        await env.coordinator.awaitAllFinalizes()
        // Await the consume follow-up's *decision*, not a yield count: asserting an absence
        // behind a bounded wait passes for free whenever the task simply hasn't run.
        await env.awaitPlanConsumption()

        XCTAssertTrue(try db.allSessionSummaries().isEmpty, "the orphaned session row must be gone")
        XCTAssertEqual(try db.plannedCalls().map(\.id), [plan.id],
                       "a failed finalize consumed the plan, losing the criteria for the retry")
        XCTAssertFalse(env.recoverableSessions.isEmpty, "the audio must still be recoverable")
    }

    /// Recovering a crashed planned call consumes its plan on exactly the same terms as a
    /// live stop: only because a session came back. The failing half of this is covered
    /// above; this is the half that can silently stop working, since `recover` not passing
    /// the plan through at all looks identical to a finalize that failed.
    func testRecoveringACrashedPlannedCallConsumesItsPlan() async throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot()
        let env = try makeEnv(db: db, root: root)
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", role: "Staff iOS",
                                                  roundType: .technical, scheduledDate: Date(),
                                                  customInstructions: "GRADE_MARKER_XYZ"))
        env.refreshPlannedCalls()

        // A directory a crashed launch left behind, with audio on both streams.
        let dir = try seedOrphanDir(root: root)
        env.refreshRecoverables()
        XCTAssertEqual(env.recoverableSessions, [dir])

        env.apply(plan)
        await env.recover(dir, metadata: .init(company: env.recordCompany, roundType: env.recordRoundType,
                                               notes: env.recordNotes,
                                               customInstructions: env.recordCriteria),
                          plannedCallId: plan.id)
        await env.coordinator.awaitAllFinalizes()
        await env.awaitPlanConsumption()

        let summaries = try db.allSessionSummaries()
        XCTAssertEqual(summaries.count, 1)
        let recovered = try XCTUnwrap(summaries.first?.session)
        XCTAssertEqual(recovered.customInstructions, "GRADE_MARKER_XYZ",
                       "a recovered planned call lost its grading criteria")
        XCTAssertEqual(recovered.contextNotes, "Role: Staff iOS")
        XCTAssertTrue(try db.plannedCalls().isEmpty, "a recovered plan must be consumed too")
    }

    /// Changing your mind: apply a plan, then pick a calendar entry instead. The calendar
    /// path has to drop both the criteria and the remembered plan, or the session is graded
    /// on a rubric written for a different interview *and* that interview's plan is deleted
    /// for a call it never covered.
    func testApplyingACalendarEntryAfterAPlanDropsThePlansCriteriaAndClaim() async throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", role: "Staff iOS",
                                                  roundType: .technical, scheduledDate: Date(),
                                                  customInstructions: "GRADE_MARKER_XYZ"))
        env.refreshPlannedCalls()

        env.apply(plan)
        env.apply(UpcomingInterview(company: "Globex", roundType: "behavioral",
                                    start: Date(), notes: "phone screen"))
        XCTAssertEqual(env.recordCompany, "Globex")
        XCTAssertEqual(env.recordCriteria, "", "the abandoned plan's rubric is still armed")

        await env.coordinator.startRecording()
        await env.stopAndDebrief()
        await env.coordinator.awaitAllFinalizes()
        await env.awaitPlanConsumption()

        let session = try XCTUnwrap(try db.allSessionSummaries().first?.session)
        XCTAssertEqual(session.customInstructions, "",
                       "Globex was graded on the rubric written for the Acme interview")
        XCTAssertEqual(try db.plannedCalls().map(\.id), [plan.id],
                       "recording a different interview consumed the Acme plan")
    }

    /// The headline of the concurrency work, applied to plans: stop A, start B, stop B. Each
    /// session must carry the criteria of the plan *it* was recorded under, and each plan is
    /// consumed by its own finalize — a single shared "applied plan" or a single consume task
    /// crosses them, and the symptom is one interview graded on another's rubric.
    func testOverlappingRecordingsEachKeepTheirOwnPlanAndCriteria() async throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let planP = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .technical,
                                                   scheduledDate: Date(), customInstructions: "CRITERIA_P"))
        let planQ = try db.insertPlannedCall(.init(companyName: "Globex", roundType: .behavioral,
                                                   scheduledDate: Date(), customInstructions: "CRITERIA_Q"))
        env.refreshPlannedCalls()

        env.apply(planP)
        await env.coordinator.startRecording()
        await env.stopAndDebrief()          // deliberately NOT awaited to completion

        // B starts while A is still finalizing — the whole point of the job queue.
        await env.coordinator.startRecording()
        env.apply(planQ)
        await env.stopAndDebrief()

        await env.coordinator.awaitAllFinalizes()
        await env.awaitPlanConsumption()

        let rows = try db.allSessionSummaries()
        XCTAssertEqual(rows.count, 2)
        let acme = try XCTUnwrap(rows.first { $0.companyName == "Acme" }?.session)
        let globex = try XCTUnwrap(rows.first { $0.companyName == "Globex" }?.session)
        XCTAssertEqual(acme.customInstructions, "CRITERIA_P", "session A was graded on B's rubric")
        XCTAssertEqual(globex.customInstructions, "CRITERIA_Q", "session B was graded on A's rubric")
        XCTAssertEqual(acme.roundType, .technical)
        XCTAssertEqual(globex.roundType, .behavioral)
        let leftover = try db.plannedCalls()
        XCTAssertTrue(leftover.isEmpty,
                      "both plans were recorded; a consume follow-up was dropped: \(leftover.map(\.companyName))")
    }

    /// Applying a plan arms a rubric and marks a row for deletion. Both halves are invisible
    /// in the form, so a mis-click mid-call needs an undo that releases the claim as well as
    /// the criteria — otherwise the wrong plan is deleted when this interview stops.
    func testDismissingTheAppliedCriteriaReleasesThePlanClaimToo() async throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .technical,
                                                  scheduledDate: Date(),
                                                  customInstructions: "GRADE_MARKER_XYZ"))
        env.refreshPlannedCalls()

        env.apply(plan)
        XCTAssertEqual(env.appliedPlannedCallId, plan.id)
        env.clearAppliedPlan()
        XCTAssertEqual(env.recordCriteria, "")
        XCTAssertNil(env.appliedPlannedCallId)
        // Company/round/notes are visibly editable, so they are deliberately left alone.
        XCTAssertEqual(env.recordCompany, "Acme")

        await env.coordinator.startRecording()
        await env.stopAndDebrief()
        await env.coordinator.awaitAllFinalizes()
        await env.awaitPlanConsumption()

        XCTAssertEqual(try XCTUnwrap(db.allSessionSummaries().first?.session).customInstructions, "",
                       "the dismissed rubric was still applied to the recording")
        XCTAssertEqual(try db.plannedCalls().map(\.id), [plan.id],
                       "the dismissed plan was consumed by a recording that didn't use it")
    }

    /// Deleting the plan that is currently pre-filled has to release the claim: the row is
    /// gone, and a claim on a dead id is a delete aimed at whatever comes to occupy it.
    func testDeletingTheAppliedPlanReleasesTheClaim() throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .technical,
                                                  scheduledDate: Date(), customInstructions: "X"))
        env.refreshPlannedCalls()
        env.apply(plan)
        XCTAssertEqual(env.appliedPlannedCallId, plan.id)

        env.deletePlannedCall(id: try XCTUnwrap(plan.id))
        XCTAssertNil(env.appliedPlannedCallId, "a claim survived the row it pointed at")
    }

    /// The sheet is modal to the window, and the call it plans can end — consuming the row —
    /// while it is open. Saving then updates nothing, and the typing is gone. Re-insert it
    /// instead: a duplicate row is one right-click away, lost typing isn't recoverable.
    func testSavingAnEditToAConsumedPlanKeepsTheTypingAsANewPlan() throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .technical,
                                                  scheduledDate: Date(timeIntervalSinceNow: 3_600)))
        env.refreshPlannedCalls()

        var draft = PlannedCallDraft(plan)
        draft.customInstructions = "Grade on API design."
        try db.deletePlannedCall(id: XCTUnwrap(plan.id))   // the call ran and finalized meanwhile
        env.savePlannedCall(draft)

        let saved = try XCTUnwrap(env.plannedCalls.first)
        XCTAssertEqual(env.plannedCalls.count, 1)
        XCTAssertEqual(saved.customInstructions, "Grade on API design.", "the edit was silently discarded")
        XCTAssertNotEqual(saved.id, plan.id, "the consumed row cannot be resurrected under its old id")
    }

    /// Whitespace-only criteria must not survive to the row: `assembleSystemPrompt` trims
    /// them away and appends nothing, so storing them would light the "criteria applied"
    /// badge over a rubric the debrief never sees.
    func testPlannedCallDraftTrimsEveryFieldOnItsWayToTheRow() {
        var draft = PlannedCallDraft()
        draft.companyName = "  Acme  "
        draft.role = "  Staff iOS\n"
        draft.notes = "  panel of two  "
        draft.customInstructions = "   \n  "
        let plan = draft.plannedCall
        XCTAssertEqual(plan.companyName, "Acme")
        XCTAssertEqual(plan.role, "Staff iOS")
        XCTAssertEqual(plan.notes, "panel of two")
        XCTAssertEqual(plan.customInstructions, "")
        XCTAssertFalse(PlannedCallDraft().isValid, "a plan with no company can't pre-fill anything")
    }

    func testContextNotesFoldsTheRoleInWithoutInventingSeparators() {
        XCTAssertEqual(AppEnvironment.contextNotes(role: "Staff iOS", notes: "panel of two"),
                       "Role: Staff iOS — panel of two")
        XCTAssertEqual(AppEnvironment.contextNotes(role: "Staff iOS", notes: ""), "Role: Staff iOS")
        XCTAssertEqual(AppEnvironment.contextNotes(role: "  ", notes: "panel of two"), "panel of two")
        XCTAssertEqual(AppEnvironment.contextNotes(role: "", notes: ""), "")
    }

    /// Editing and deleting go through the environment so the published list stays in step
    /// with the table — a stale list would keep offering a plan that no longer exists.
    func testPlannedCallEditsAndDeletesRepublishTheList() throws {
        let db = try AppDatabase.inMemory()
        let env = try makeEnv(db: db)

        var draft = PlannedCallDraft()
        draft.companyName = "Acme"
        draft.roundType = .behavioral
        env.savePlannedCall(draft)
        XCTAssertEqual(env.plannedCalls.map(\.companyName), ["Acme"])

        var edit = PlannedCallDraft(try XCTUnwrap(env.plannedCalls.first))
        edit.companyName = "Acme Corp"
        env.savePlannedCall(edit)
        XCTAssertEqual(env.plannedCalls.map(\.companyName), ["Acme Corp"])
        XCTAssertEqual(env.plannedCalls.count, 1, "editing a plan must update it, not add a second")

        env.deletePlannedCall(id: try XCTUnwrap(env.plannedCalls.first?.id))
        XCTAssertTrue(env.plannedCalls.isEmpty)
    }

    func testCallStartWhileRecordingDoesNotPostAlert() async throws {
        let db = try AppDatabase.inMemory()
        let alerts = FakeAlerts()
        let env = try makeEnv(db: db, alerts: alerts)

        await env.coordinator.startRecording()  // bypass the wrapper so clearCount stays 0
        await env.pollDetection(.init(micInUse: true, meetingAppRunning: true), at: Date())

        XCTAssertTrue(env.callDetected)
        XCTAssertEqual(alerts.detectedCount, 0, "no Record pop-up while already recording")
        _ = await env.coordinator.stopAndAwait(metadata: .init(company: "X", roundType: .behavioral, notes: ""))
    }
}
