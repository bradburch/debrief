import XCTest
import AVFoundation
@testable import DebriefApp
import CaptureKit
import Transcriber
import Store
import CoachingEngine

/// Per-session recorder sizes, so one coordinator can produce a long session A and a short
/// session B (`FakeRecorder` is built by a closure the coordinator holds for its lifetime).
final class RecorderPlan: @unchecked Sendable {
    var seconds: Double = 2
    /// Audio written at `stop()` rather than `start()`, standing in for the chunks that only
    /// exist once the recording ends — the ones a finalize must transcribe itself.
    var tailSeconds: Double = 0
    /// When set, recorders built from this plan park in `stop()` on the "stop" token, so a
    /// test can hold a session open in the middle of stopping.
    var stopGate: Gate?
}

final class FakeRecorder: StreamRecorder, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    let writer: WavChunkWriter
    let seconds: Double
    let tailSeconds: Double
    let stopGate: Gate?
    init(writer: WavChunkWriter, seconds: Double, tailSeconds: Double = 0, stopGate: Gate? = nil) {
        self.writer = writer; self.seconds = seconds; self.tailSeconds = tailSeconds
        self.stopGate = stopGate
    }

    func start() async throws { try write(seconds) }
    func stop() async throws {
        await stopGate?.wait("stop")
        try write(tailSeconds)
        try writer.finish()
    }

    /// Synthesizes `count` seconds of audio as 1s appends so the writer rolls one
    /// chunk per second (a single big append would land in one oversized chunk).
    private func write(_ count: Double) throws {
        guard count > 0 else { return }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        for _ in 0..<Int(count) {
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000)!
            buf.frameLength = 16_000
            try writer.append(buf)
        }
    }
}

/// Counts `stop()` calls across the recorders one test builds, so it can assert that a start
/// which failed part-way did not leave a live one behind.
final class StopSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var stops: Int { lock.lock(); defer { lock.unlock() }; return count }
    func record() { lock.lock(); count += 1; lock.unlock() }
}

/// Starts cleanly, writes nothing, and reports being stopped.
final class SpyRecorder: StreamRecorder, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    let writer: WavChunkWriter
    let spy: StopSpy
    init(writer: WavChunkWriter, spy: StopSpy) { self.writer = writer; self.spy = spy }
    func start() async throws {}
    func stop() async throws { spy.record(); try writer.finish() }
}

/// The system tap being refused: `start()` throws after the other stream is already live.
final class FailingStartRecorder: StreamRecorder, @unchecked Sendable {
    struct Refused: Error {}
    var onLevel: (@Sendable (Float) -> Void)?
    func start() async throws { throw Refused() }
    func stop() async throws {}
}

struct FakeTranscriber: Transcribing {
    let textForChunk: String
    func transcribe(wavURL: URL) async throws -> [TimedText] {
        [TimedText(start: 1.0, text: "\(textForChunk) \(wavURL.lastPathComponent)")]
    }
}

/// Parks callers on a token until the test releases them, so the interleaving under test is
/// exact rather than merely likely. An actor rather than flags plus sleeps, for that reason.
/// Tokens are a session directory (transcription) or "stop" (recorder shutdown).
actor Gate {
    private var held: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { waiters.count }

    /// Everything arriving on `token` from here on parks until `open()`.
    func hold(_ token: String) { held.insert(token) }

    func open() {
        held = []
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait(_ token: String) async {
        guard held.contains(token) else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Echoes the chunk's **directory** as well as its filename.
///
/// The directory is the point: every session's first chunk is named `mic-0000.wav`, so a
/// fake that echoed only `lastPathComponent` would produce identical text for two different
/// sessions and pass a cross-contamination test that a shared transcript cache would fail.
struct DirEchoTranscriber: Transcribing {
    var gate: Gate?

    func transcribe(wavURL: URL) async throws -> [TimedText] {
        let dir = wavURL.deletingLastPathComponent().lastPathComponent
        await gate?.wait(dir)
        return [TimedText(start: 1.0, text: "seg \(dir) \(wavURL.lastPathComponent)")]
    }
}

struct ThrowingTranscriber: Transcribing {
    struct Boom: Error {}
    func transcribe(wavURL: URL) async throws -> [TimedText] { throw Boom() }
}

/// Records how many times each chunk filename is transcribed, to prove the
/// finalize pass reuses live-cached chunks instead of re-transcribing them.
final class CountingTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callsByChunk: [String: Int] = [:]
    func transcribe(wavURL: URL) async throws -> [TimedText] {
        lock.lock(); callsByChunk[wavURL.lastPathComponent, default: 0] += 1; lock.unlock()
        return [TimedText(start: 1.0, text: "final \(wavURL.lastPathComponent)")]
    }
}

struct OKStubLLM: CoachingLLM {
    func generateCoaching(systemPrompt: String, userMessage: String,
                          dimensions: [String]) async throws -> CoachingResult {
        // Score whatever dimensions the round asked for, as a real client must.
        CoachingResult(proseDebrief: "ok",
                       scores: Dictionary(uniqueKeysWithValues: dimensions.map { ($0, 3) }),
                       advancement: .leanYes, advancementRationale: "ok",
                       weaknessTags: [], highlights: [], actionItems: [])
    }
}

/// Captures the system prompt each debrief was written against, so a test can prove the
/// criteria a session was *recorded* with reached its first debrief — not just the row.
final class PromptSpyLLM: CoachingLLM, @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    var systemPrompts: [String] { lock.lock(); defer { lock.unlock() }; return prompts }

    func generateCoaching(systemPrompt: String, userMessage: String,
                          dimensions: [String]) async throws -> CoachingResult {
        lock.lock(); prompts.append(systemPrompt); lock.unlock()
        return CoachingResult(proseDebrief: "ok",
                              scores: Dictionary(uniqueKeysWithValues: dimensions.map { ($0, 3) }),
                              advancement: .leanYes, advancementRationale: "ok",
                              weaknessTags: [], highlights: [], actionItems: [])
    }
}

@MainActor
extension RecordingCoordinator {
    /// Test convenience for the common "stop and wait for the debrief" shape. Production
    /// code deliberately does not wait — `stopAndFinalize` returns as soon as the audio is
    /// on disk so the next interview can start.
    func stopAndAwait(metadata: SessionMetadata) async -> Int64? {
        guard let job = await stopAndFinalize(metadata: metadata) else { return nil }
        return await awaitFinalize(job)
    }
}

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func makeCoordinator(root: URL, db: AppDatabase, deleteAudio: Bool = true,
                         transcriber: Transcribing = FakeTranscriber(textForChunk: "final"),
                         llm: CoachingLLM = OKStubLLM(),
                         plan: RecorderPlan = RecorderPlan()) throws -> RecordingCoordinator {
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        return RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: llm),
            transcriber: transcriber,
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: plan.seconds, tailSeconds: plan.tailSeconds,
                                           stopGate: plan.stopGate) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: plan.seconds, tailSeconds: plan.tailSeconds,
                                               stopGate: plan.stopGate) },
            recordingsRoot: root,
            chunkDuration: 1.0,
            deleteAudioOnSuccess: deleteAudio)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testKeepAudioPreservesRecordingDirectory() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db, deleteAudio: false)

        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        XCTAssertNotNil(sessionId)

        // Audio kept: exactly one session dir remains, with its wav chunks.
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, 1, "recording dir should survive finalize when keep-audio is on")
        let kept = try XCTUnwrap(dirs.first)
        XCTAssertFalse(RecordingStore.chunkURLs(in: kept, prefix: "mic").isEmpty)
        XCTAssertFalse(RecordingStore.chunkURLs(in: kept, prefix: "sys").isEmpty)
        // But it is finalized, so it must NOT be offered for crash recovery.
        XCTAssertEqual(RecordingStore.readManifest(in: kept)?.finalized, true)
        // And it names the row it produced, so a recovery scan can tell it apart from a
        // directory whose session never landed.
        XCTAssertEqual(RecordingStore.readManifest(in: kept)?.sessionId, sessionId)
        XCTAssertTrue(RecordingStore.unfinalizedSessions(root: root).isEmpty)
    }

    func testFullLifecyclePersistsSessionAndDeletesAudio() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)

        await coordinator.startRecording()
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("expected recording, got \(coordinator.recordingPhase)")
        }

        let sessionId = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .technical, notes: "phone screen"))
        let id = try XCTUnwrap(sessionId)

        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertEqual(detail.company.name, "Acme")
        XCTAssertEqual(detail.session.roundType, .technical)
        XCTAssertFalse(detail.segments.isEmpty)
        // Final transcriber output used (not live).
        XCTAssertTrue(detail.segments.allSatisfy { $0.text.contains("final") })
        // Both speakers present.
        XCTAssertTrue(detail.segments.contains { $0.speaker == .you })
        XCTAssertTrue(detail.segments.contains { $0.speaker == .them })
        // Coaching ran (stub) -> complete.
        XCTAssertEqual(detail.session.coachingStatus, .complete)
        // Audio deleted.
        XCTAssertTrue(RecordingStore.unfinalizedSessions(root: root).isEmpty)
        let leftoverDirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftoverDirs.isEmpty, "audio dir should be deleted on success")
        // Recording is idle from the moment the audio is on disk, and the job that produced
        // the session reports it.
        if case .idle = coordinator.recordingPhase {} else { XCTFail("expected idle after stop") }
        XCTAssertEqual(coordinator.finalizeJobs.first?.sessionId, id)
        XCTAssertNil(coordinator.finalizeJobs.first?.failure)
        XCTAssertFalse(coordinator.hasActiveJobs)
        XCTAssertTrue(coordinator.activeDirs.isEmpty, "the claim must be released when the job ends")
    }

    /// Grading criteria entered before the call (from a planned call, or the recovery prompt)
    /// must be on the session row by the time finalize coaches it. Feedback is written once,
    /// during finalize — criteria that only land on the row afterwards reach the debrief on a
    /// re-coach and never on the first one, which is the whole point of planning ahead.
    func testPreEnteredCriteriaReachTheFirstDebriefNotJustTheRow() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let spy = PromptSpyLLM()
        let coordinator = try makeCoordinator(root: root, db: db, llm: spy)

        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndAwait(metadata: .init(
            company: "Acme", roundType: .behavioral, notes: "Role: Staff iOS — onsite",
            customInstructions: "GRADE_MARKER_XYZ"))
        let id = try XCTUnwrap(sessionId)

        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertEqual(detail.session.customInstructions, "GRADE_MARKER_XYZ")
        XCTAssertEqual(detail.session.contextNotes, "Role: Staff iOS — onsite")
        XCTAssertEqual(detail.session.coachingStatus, .complete)
        XCTAssertEqual(spy.systemPrompts.count, 1)
        XCTAssertTrue(spy.systemPrompts.contains { $0.contains("GRADE_MARKER_XYZ") },
                      "the criteria never reached the system prompt of the first debrief")
    }

    func testChunkOffsetsApplied() async throws {
        // FakeRecorder writes 2s of audio with 1s chunks -> 2 chunks per stream.
        // FakeTranscriber returns start 1.0 per chunk; chunk 1 should land at 1.0 + 1*1.0 = 2.0.
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)
        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        let id = try XCTUnwrap(sessionId)
        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        let youStarts = detail.segments.filter { $0.speaker == .you }.map(\.tStart).sorted()
        XCTAssertEqual(youStarts, [1.0, 2.0])
    }

    /// Live sessions must record the exact wall-clock duration, not
    /// chunkCount * chunkDuration. Uses the 30s default chunkDuration with only
    /// 2s of synthesized audio, so a single partial chunk is flushed at
    /// stop() -- the chunk-count approximation would report ~30s while the
    /// real elapsed wall-clock time is a small fraction of a second.
    func testLiveFinalizeUsesExactWallClockDuration() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root)
            // chunkDuration defaults to 30s; the approximation would yield ~30.

        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .technical, notes: ""))
        let id = try XCTUnwrap(sessionId)
        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertLessThan(detail.session.durationSeconds, 5)
    }

    func testStreamHealthWarnsAfterSilence() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)
        await coordinator.startRecording()
        // No level callbacks have fired (FakeRecorder never calls onLevel).
        coordinator.checkStreamHealth(now: Date().addingTimeInterval(61))
        XCTAssertNotNil(coordinator.streamWarning)
        _ = await coordinator.stopAndAwait(metadata: .init(company: "X", roundType: .behavioral, notes: ""))
    }

    func testFinalizeReusesLiveCachedChunksAndCompletesProgress() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let spy = CountingTranscriber()
        let coordinator = try makeCoordinator(root: root, db: db, transcriber: spy,
                                              plan: { let p = RecorderPlan(); p.seconds = 3; return p }())

        await coordinator.startRecording()
        // Deterministically run one live pass (the 5s timer won't fire in a unit test).
        await coordinator.transcribeNewChunks()
        let cached = Set(spy.callsByChunk.keys)
        XCTAssertFalse(cached.isEmpty, "live pass should have transcribed at least one closed chunk")

        _ = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))

        // No chunk is transcribed more than once: cached chunks are reused, and only
        // the uncached final-partial chunk gets transcribed at finalize.
        for (chunk, count) in spy.callsByChunk {
            XCTAssertEqual(count, 1, "\(chunk) transcribed \(count)x; cached chunks must not be re-transcribed")
        }
        // Progress reached completion, on the job that did the work.
        let p = try XCTUnwrap(coordinator.finalizeJobs.first?.progress)
        XCTAssertEqual(p.done, p.total)
        XCTAssertGreaterThan(p.total, 0)
    }

    func testFinalizeExportsMarkdownWhenDirectoryConfigured() async throws {
        let root = try makeRoot()
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root,
            chunkDuration: 1.0,
            exportDirectory: { exportDir })

        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        XCTAssertNotNil(sessionId)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        XCTAssertEqual(files.count, 1, "finalize should write exactly one markdown export")
    }

    func testFinalizeDoesNotExportWhenDirectoryNotConfigured() async throws {
        // Default exportDirectory reads UserDefaults key "exportDirectory"; under a
        // clean UserDefaults it must return nil, so existing/other tests (which don't
        // pass exportDirectory) never write files as a side effect.
        UserDefaults.standard.removeObject(forKey: "exportDirectory")
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)

        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        XCTAssertNotNil(sessionId)
        // No exportDirectory configured -> no export call, nothing to assert on disk
        // beyond "finalize still succeeds", which the non-nil sessionId already proves.
    }

    /// The headline of the concurrency change, and the sharpest hazard in it: session B
    /// records — and runs its own live transcription — while session A is still finalizing,
    /// and the two transcripts must not cross.
    ///
    /// They can cross because the per-chunk cache is keyed by bare filename and every
    /// session has a `mic-0000.wav`. The interleaving is forced rather than hoped for: A's
    /// finalize parks on its first tail chunk until the gate opens, B records and caches
    /// `mic-0000`/`sys-0000` of its own in the meantime, and only then is A released to read
    /// *its* `sys-0000`. Against a cache shared between sessions, A's "them" track comes back
    /// in B's words — which is visible only because the transcriber echoes the session
    /// directory. A filename-echo fake reports identical text for both and proves nothing.
    func testRecordsWhileEarlierSessionFinalizesWithoutCrossingTranscripts() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let plan = RecorderPlan()
        plan.seconds = 2       // chunks 0-1, cached by A's live pass below
        plan.tailSeconds = 4   // chunks 2-5, on disk only at stop() — A's finalize transcribes these
        let gate = Gate()
        let coordinator = try makeCoordinator(
            root: root, db: db, deleteAudio: false,
            transcriber: DirEchoTranscriber(gate: gate), plan: plan)

        await coordinator.startRecording()
        let dirA = try XCTUnwrap(coordinator.activeDirs.first)
        await coordinator.transcribeNewChunks()
        // From here A's own chunks park, so its finalize stalls part-way through.
        await gate.hold(dirA)
        let queuedA = await coordinator.stopAndFinalize(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        let jobA = try XCTUnwrap(queuedA)

        // B is a different directory, so nothing it records is gated.
        plan.seconds = 1
        plan.tailSeconds = 0
        await coordinator.startRecording()
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("B must be recordable while A finalizes, got \(coordinator.recordingPhase)")
        }
        XCTAssertTrue(coordinator.hasActiveJobs, "A's finalize must still be in flight")
        let dirB = try XCTUnwrap(coordinator.activeDirs.subtracting([dirA]).first)
        XCTAssertNotEqual(dirA, dirB)
        await coordinator.transcribeNewChunks()  // B caches its own mic-0000 / sys-0000

        // Release A into the rest of its transcript while B is still recording — the window
        // where a shared cache hands A the wrong session's audio.
        await gate.open()
        let resultA = await coordinator.awaitFinalize(jobA)
        let idA = try XCTUnwrap(resultA)
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("B must still be recording after A's debrief lands")
        }

        let queuedB = await coordinator.stopAndFinalize(
            metadata: .init(company: "Globex", roundType: .behavioral, notes: ""))
        let jobB = try XCTUnwrap(queuedB)
        let resultB = await coordinator.awaitFinalize(jobB)
        let idB = try XCTUnwrap(resultB)
        XCTAssertNotEqual(idA, idB)

        let detailA = try XCTUnwrap(db.sessionDetail(id: idA))
        let detailB = try XCTUnwrap(db.sessionDetail(id: idB))
        XCTAssertEqual(detailA.company.name, "Acme")
        XCTAssertEqual(detailB.company.name, "Globex")
        XCTAssertFalse(detailA.segments.isEmpty)
        XCTAssertFalse(detailB.segments.isEmpty)
        XCTAssertTrue(detailA.segments.allSatisfy { $0.text.contains(dirA) },
                      "session A holds text from another session's audio: \(detailA.segments.map(\.text))")
        XCTAssertTrue(detailB.segments.allSatisfy { $0.text.contains(dirB) },
                      "session B holds text from another session's audio: \(detailB.segments.map(\.text))")
        XCTAssertTrue(coordinator.activeDirs.isEmpty, "both claims must be released")
    }

    /// The other half of the same hazard, from the live loop's side: a transcription pass
    /// that was still suspended when its session ended must not file its result under the
    /// session that is live by the time it resumes. In production that pass is the live
    /// loop's in-flight `transcribe`, which `stopAndFinalize` cancels and awaits — but
    /// cancellation cannot un-suspend it, and the next recording may start during that await.
    /// Driven here by an explicit parked pass, which is the same thing without the timing.
    func testLatePassFromAnEndedSessionDoesNotWriteIntoTheNextOne() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let plan = RecorderPlan()
        plan.seconds = 1
        let gate = Gate()
        let coordinator = try makeCoordinator(
            root: root, db: db, deleteAudio: false,
            transcriber: DirEchoTranscriber(gate: gate), plan: plan)

        await coordinator.startRecording()
        let dirA = try XCTUnwrap(coordinator.activeDirs.first)
        await gate.hold(dirA)
        let parked = Task { await coordinator.transcribeNewChunks() }
        for _ in 0..<1000 where await gate.waitingCount == 0 { await Task.yield() }
        let parkedCount = await gate.waitingCount
        XCTAssertEqual(parkedCount, 1, "the pass under test never reached the gate")

        let queuedA = await coordinator.stopAndFinalize(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        let jobA = try XCTUnwrap(queuedA)

        await coordinator.startRecording()
        let dirB = try XCTUnwrap(coordinator.activeDirs.subtracting([dirA]).first)
        await coordinator.transcribeNewChunks()  // B caches its own mic-0000 / sys-0000

        // A's stranded pass resumes here, holding session A's segments for a filename that
        // session B also has.
        await gate.open()
        await parked.value

        let queuedB = await coordinator.stopAndFinalize(
            metadata: .init(company: "Globex", roundType: .behavioral, notes: ""))
        let jobB = try XCTUnwrap(queuedB)
        let resultB = await coordinator.awaitFinalize(jobB)
        let idB = try XCTUnwrap(resultB)
        _ = await coordinator.awaitFinalize(jobA)

        let detailB = try XCTUnwrap(db.sessionDetail(id: idB))
        XCTAssertFalse(detailB.segments.isEmpty)
        XCTAssertTrue(detailB.segments.allSatisfy { $0.text.contains(dirB) },
                      "a stranded pass from session A landed in session B: \(detailB.segments.map(\.text))")
    }

    /// A failed finalize is confined to its job. It used to land on the single `phase`,
    /// which left the app unable to record at all until relaunch.
    func testFailedFinalizeLeavesRecordingUsable() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        // Every transcription throws -> no segments land -> finalize fails after inserting
        // the session row, which it then has to compensate away.
        let coordinator = try makeCoordinator(root: root, db: db, deleteAudio: false,
                                              transcriber: ThrowingTranscriber())

        await coordinator.startRecording()
        let dirA = try XCTUnwrap(coordinator.activeDirs.first)
        let queued = await coordinator.stopAndFinalize(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
        let jobA = try XCTUnwrap(queued)

        // B records through A's failure.
        await coordinator.startRecording()
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("expected B to be recording, got \(coordinator.recordingPhase)")
        }
        let failedResult = await coordinator.awaitFinalize(jobA)
        XCTAssertNil(failedResult)
        let failed = try XCTUnwrap(coordinator.finalizeJobs.first { $0.id == jobA })
        XCTAssertNotNil(failed.failure)
        XCTAssertTrue(try db.allSessionSummaries().isEmpty, "the orphaned session row must be removed")
        XCTAssertNil(try db.findCompany(named: "Acme"),
                     "compensation must also remove the company row it created, or Pipeline shows a zero-session company")
        let keptDir = root.appendingPathComponent(dirA, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptDir.path),
                      "audio must be kept for a failed finalize")
        // The stamp goes with the row it named. Left behind, it would tell every future
        // recovery scan that this directory had already become a session.
        XCTAssertNil(RecordingStore.readManifest(in: keptDir)?.sessionId,
                     "a compensated-away session must not leave its id stamped on the dir")
        XCTAssertFalse(coordinator.activeDirs.contains(dirA), "a failed job still releases its claim")

        // And recording keeps working afterwards.
        guard case .recording = coordinator.recordingPhase else { return XCTFail("B stopped recording") }
        _ = await coordinator.stopAndFinalize(metadata: .init(company: "Globex", roundType: .behavioral, notes: ""))
        await coordinator.awaitAllFinalizes()
        await coordinator.startRecording()
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("recording must be startable after a failed finalize, got \(coordinator.recordingPhase)")
        }
        _ = await coordinator.stopAndFinalize(metadata: .init(company: "Initech", roundType: .behavioral, notes: ""))
        await coordinator.awaitAllFinalizes()
    }

    /// Stopping is not instant — the recorders have a final flush, and the mic and the system
    /// tap are torn down one after the other. A start attempted inside that window must be
    /// refused, which means `recordingPhase` cannot go `.idle` until the recorders are down.
    ///
    /// If it goes idle first, the main actor is free for the whole teardown and a second mic
    /// and system tap open while the first pair is still capturing: session A's `sys-*.wav`
    /// keeps growing after A stopped, and `runFinalize` re-reads A's directory from disk — so
    /// the opening of interview B is transcribed into interview A's THEM track.
    func testStartRefusedWhileTheRecordersAreStillStopping() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let gate = Gate()
        let plan = RecorderPlan()
        plan.seconds = 1
        plan.stopGate = gate
        await gate.hold("stop")
        let coordinator = try makeCoordinator(root: root, db: db, deleteAudio: false, plan: plan)

        await coordinator.startRecording()
        let dirA = try XCTUnwrap(coordinator.activeDirs.first)
        plan.stopGate = nil  // only session A's recorders are held

        let stopping = Task { await coordinator.stopAndFinalize(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: "")) }
        for _ in 0..<1000 where await gate.waitingCount == 0 { await Task.yield() }
        let parked = await gate.waitingCount
        XCTAssertEqual(parked, 1, "the stop never reached the recorder teardown")

        // The main actor is free right now — this is the window the bug lived in.
        await coordinator.startRecording()
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("session A must still count as recording until its recorders are down")
        }
        XCTAssertEqual(coordinator.activeDirs, [dirA], "a second capture started while A was still stopping")
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, 1, "a second session directory was opened mid-stop")

        await gate.open()
        let queued = await stopping.value
        let jobA = try XCTUnwrap(queued)
        let idA = await coordinator.awaitFinalize(jobA)
        XCTAssertNotNil(idA)

        // And once the stop really is finished, recording starts normally again.
        await coordinator.startRecording()
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("recording must be startable once the stop completes")
        }
        XCTAssertEqual(coordinator.activeDirs.count, 1)
        _ = await coordinator.stopAndAwait(metadata: .init(company: "Globex", roundType: .behavioral, notes: ""))
    }

    /// A start that fails half-way — in practice the system tap being refused after the mic
    /// engine is already running — must tear the started half down. `.failed` is a startable
    /// state, so a retry that leaves the first mic engine live stacks orphaned recorders that
    /// nothing holds a reference to and nothing can stop, all still capturing.
    func testAFailedStartStopsTheRecorderThatDidStart() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let micSpy = StopSpy()
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { SpyRecorder(writer: $0, spy: micSpy) },
            makeSystemRecorder: { _ in FailingStartRecorder() },
            recordingsRoot: root,
            chunkDuration: 1.0)

        await coordinator.startRecording()

        guard case .failed = coordinator.recordingPhase else {
            return XCTFail("expected a failed start, got \(coordinator.recordingPhase)")
        }
        XCTAssertEqual(micSpy.stops, 1, "the mic recorder was abandoned still running")

        // And a retry — legal from `.failed` — does not stack a second live recorder on it.
        await coordinator.startRecording()
        XCTAssertEqual(micSpy.stops, 2, "a retry left the previous attempt's recorder running")
    }

    /// Two Record taps in the same frame. The claim is taken before the first `await`, so
    /// the second is refused; without that, both passed the guard and the second session's
    /// recorders replaced the first's, orphaning a directory mid-write.
    func testConcurrentStartsProduceOneRecording() async throws {
        let root = try makeRoot()
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db, deleteAudio: false)

        async let first: Void = coordinator.startRecording()
        async let second: Void = coordinator.startRecording()
        _ = await (first, second)

        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("expected recording, got \(coordinator.recordingPhase)")
        }
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, 1, "a second concurrent start must not open a second session")
        XCTAssertEqual(coordinator.activeDirs.count, 1)
        _ = await coordinator.stopAndAwait(metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))
    }
}
