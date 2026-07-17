import XCTest
import AVFoundation
@testable import DebriefApp
import CaptureKit
import Transcriber
import Store
import CoachingEngine

final class FakeRecorder: StreamRecorder, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    let writer: WavChunkWriter
    let seconds: Double
    init(writer: WavChunkWriter, seconds: Double) { self.writer = writer; self.seconds = seconds }

    func start() async throws {
        // Synthesize `seconds` of audio as 1s appends so the writer rolls one
        // chunk per second (a single big append would land in one oversized chunk).
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        for _ in 0..<Int(seconds) {
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000)!
            buf.frameLength = 16_000
            try writer.append(buf)
        }
    }
    func stop() async throws { try writer.finish() }
}

struct FakeTranscriber: Transcribing {
    let textForChunk: String
    func transcribe(wavURL: URL) async throws -> [TimedText] {
        [TimedText(start: 1.0, text: "\(textForChunk) \(wavURL.lastPathComponent)")]
    }
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

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func makeCoordinator(root: URL, db: AppDatabase, deleteAudio: Bool = true) throws -> RecordingCoordinator {
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        return RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root,
            chunkDuration: 1.0,
            deleteAudioOnSuccess: deleteAudio)
    }

    func testKeepAudioPreservesRecordingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db, deleteAudio: false)

        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndFinalize(
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
        XCTAssertTrue(RecordingStore.unfinalizedSessions(root: root).isEmpty)
    }

    func testFullLifecyclePersistsSessionAndDeletesAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)

        await coordinator.startRecording()
        guard case .recording = coordinator.phase else { return XCTFail("expected recording, got \(coordinator.phase)") }

        let sessionId = await coordinator.stopAndFinalize(
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
        if case .idle = coordinator.phase {} else { XCTFail("expected idle after finalize") }
    }

    func testChunkOffsetsApplied() async throws {
        // FakeRecorder writes 2s of audio with 1s chunks -> 2 chunks per stream.
        // FakeTranscriber returns start 1.0 per chunk; chunk 1 should land at 1.0 + 1*1.0 = 2.0.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)
        await coordinator.startRecording()
        let sessionId = await coordinator.stopAndFinalize(
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        let sessionId = await coordinator.stopAndFinalize(
            metadata: .init(company: "Acme", roundType: .technical, notes: ""))
        let id = try XCTUnwrap(sessionId)
        let detail = try XCTUnwrap(db.sessionDetail(id: id))
        XCTAssertLessThan(detail.session.durationSeconds, 5)
    }

    func testStreamHealthWarnsAfterSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)
        await coordinator.startRecording()
        // No level callbacks have fired (FakeRecorder never calls onLevel).
        coordinator.checkStreamHealth(now: Date().addingTimeInterval(61))
        XCTAssertNotNil(coordinator.streamWarning)
        _ = await coordinator.stopAndFinalize(metadata: .init(company: "X", roundType: .behavioral, notes: ""))
    }

    func testFinalizeReusesLiveCachedChunksAndCompletesProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let spy = CountingTranscriber()
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: spy,
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 3) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 3) },
            recordingsRoot: root,
            chunkDuration: 1.0)

        await coordinator.startRecording()
        // Deterministically run one live pass (the 5s timer won't fire in a unit test).
        await coordinator.transcribeNewChunks()
        let cached = Set(spy.callsByChunk.keys)
        XCTAssertFalse(cached.isEmpty, "live pass should have transcribed at least one closed chunk")

        _ = await coordinator.stopAndFinalize(
            metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))

        // No chunk is transcribed more than once: cached chunks are reused, and only
        // the uncached final-partial chunk gets transcribed at finalize.
        for (chunk, count) in spy.callsByChunk {
            XCTAssertEqual(count, 1, "\(chunk) transcribed \(count)x; cached chunks must not be re-transcribed")
        }
        // Progress reached completion.
        let p = try XCTUnwrap(coordinator.transcribeProgress)
        XCTAssertEqual(p.done, p.total)
        XCTAssertGreaterThan(p.total, 0)
    }
}
