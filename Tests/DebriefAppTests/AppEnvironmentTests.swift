import XCTest
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
        try await waitUntil("the recorded plan was never consumed") { env.plannedCalls.isEmpty }
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
        // Let the consume follow-up run; it must decide *not* to delete.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertTrue(try db.allSessionSummaries().isEmpty, "the orphaned session row must be gone")
        XCTAssertEqual(try db.plannedCalls().map(\.id), [plan.id],
                       "a failed finalize consumed the plan, losing the criteria for the retry")

        // And the recovery prompt's path can still apply and consume it.
        let dir = try XCTUnwrap(env.recoverableSessions.first)
        env.apply(plan)
        await env.recover(dir, metadata: .init(company: "Acme", roundType: .technical, notes: "",
                                               customInstructions: "GRADE_MARKER_XYZ"),
                          plannedCallId: plan.id)
        await env.coordinator.awaitAllFinalizes()
        // Still no transcript possible with a throwing transcriber, so the plan stays.
        XCTAssertEqual(try db.plannedCalls().count, 1)
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
