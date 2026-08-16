import XCTest
import AVFoundation
@testable import DebriefApp
import CaptureKit
import Store
import CoachingEngine
import Transcriber

/// A `Transcribing` that sleeps briefly before returning, so tests can keep a finalize job
/// suspended mid-transcription long enough for a second call to race it.
private struct SlowFakeTranscriber: Transcribing {
    let textForChunk: String
    func transcribe(wavURL: URL) async throws -> [TimedText] {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return [TimedText(start: 1.0, text: "\(textForChunk) \(wavURL.lastPathComponent)")]
    }
}

@MainActor
final class RecoveryTests: XCTestCase {
    /// An orphaned session directory with one chunk on each stream.
    private func seedOrphanDir(root: URL) throws -> URL {
        let dir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.writeManifest(.init(startedAt: Date(timeIntervalSinceNow: -300), finalized: false), in: dir)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        for prefix in ["mic", "sys"] {
            let writer = try WavChunkWriter(directory: dir, prefix: prefix, chunkDuration: 1.0)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000)!
            buf.frameLength = 16_000
            try writer.append(buf)
            try writer.finish()
        }
        return dir
    }

    private func makeCoordinator(root: URL, db: AppDatabase,
                                 transcriber: Transcribing = FakeTranscriber(textForChunk: "recovered")) throws
        -> RecordingCoordinator {
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir); try prompts.ensureDefaults()
        return RecordingCoordinator(
            db: db, coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: transcriber,
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            recordingsRoot: root, chunkDuration: 1.0)
    }

    func testFinalizeFromDiskRecoversOrphanedChunks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = try seedOrphanDir(root: root)

        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)

        let job = try XCTUnwrap(coordinator.finalizeFromDisk(
            dir: dir, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered")))
        // The directory is claimed the moment the job is queued, not when it starts running.
        XCTAssertTrue(coordinator.activeDirs.contains(dir.lastPathComponent))

        let finished = await coordinator.awaitFinalize(job)
        let sessionId = try XCTUnwrap(finished)
        let detail = try XCTUnwrap(db.sessionDetail(id: sessionId))
        XCTAssertTrue(detail.segments.contains { $0.text.contains("recovered") })
        XCTAssertTrue(RecordingStore.unfinalizedSessions(root: root).isEmpty)
        XCTAssertFalse(coordinator.activeDirs.contains(dir.lastPathComponent))
    }

    /// Recovering an old directory while an unrelated session records is now ALLOWED — the
    /// exclusive resource is a session directory, not the app. What must still be refused is
    /// recovery of the directory the live recording is writing into.
    func testRecoveryRunsDuringAnUnrelatedRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let orphanDir = try seedOrphanDir(root: root)

        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)

        await coordinator.startRecording()
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("expected recording, got \(coordinator.recordingPhase)")
        }
        let liveKey = try XCTUnwrap(coordinator.activeDirs.first)

        let job = try XCTUnwrap(coordinator.finalizeFromDisk(
            dir: orphanDir, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered")))
        let recovered = await coordinator.awaitFinalize(job)
        let recoveredId = try XCTUnwrap(recovered, "recovery of an unrelated dir must run during a recording")
        XCTAssertNotNil(try db.sessionDetail(id: recoveredId))

        // Still recording, untouched by the recovery.
        guard case .recording = coordinator.recordingPhase else {
            return XCTFail("recovery must not disturb the live recording, got \(coordinator.recordingPhase)")
        }
        // The live directory itself is off limits.
        XCTAssertNil(coordinator.finalizeFromDisk(
            dir: root.appendingPathComponent(liveKey, isDirectory: false),
            startedAt: Date(), metadata: .init(company: "Nope", roundType: .technical, notes: "")),
                     "the live session's own dir must never be recoverable")

        let liveId = await coordinator.stopAndAwait(
            metadata: .init(company: "Acme", roundType: .technical, notes: ""))
        XCTAssertNotEqual(liveId, recoveredId)
        XCTAssertEqual(try db.allSessionSummaries().count, 2)
    }

    /// A recovered directory with a manifest but no chunks on either stream must
    /// not produce a segment-less session with a nonsense fallback duration.
    func testZeroChunkRecoveryReturnsNilAndKeepsDir() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.writeManifest(.init(startedAt: Date(timeIntervalSinceNow: -300), finalized: false), in: dir)
        // No wav chunks written -- manifest only.

        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db)

        let job = try XCTUnwrap(coordinator.finalizeFromDisk(
            dir: dir, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered")))
        let zeroChunkResult = await coordinator.awaitFinalize(job)
        XCTAssertNil(zeroChunkResult)
        XCTAssertTrue(try db.allSessionSummaries().isEmpty, "no session should be created for a zero-chunk recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "dir must be left for the user to Discard")
        XCTAssertNotNil(coordinator.finalizeJobs.first?.failure, "the early return must still finish the job")
        // The early return releases the claim like every other exit.
        XCTAssertTrue(coordinator.activeDirs.isEmpty)
        if case .idle = coordinator.recordingPhase {} else {
            XCTFail("recording must be unaffected, got \(coordinator.recordingPhase)")
        }
    }

    /// The lock is the session directory. A second recovery of the SAME dir is refused;
    /// recoveries of two different dirs both run (serially) and both complete.
    func testSameDirRecoveryRefusedAndDifferentDirsBothComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir1 = try seedOrphanDir(root: root)
        let dir2 = try seedOrphanDir(root: root)

        let db = try AppDatabase.inMemory()
        let coordinator = try makeCoordinator(root: root, db: db,
                                              transcriber: SlowFakeTranscriber(textForChunk: "recovered"))
        let metadata = SessionMetadata(company: "Acme", roundType: .technical, notes: "recovered")

        let first = try XCTUnwrap(coordinator.finalizeFromDisk(
            dir: dir1, startedAt: Date(timeIntervalSinceNow: -300), metadata: metadata))
        XCTAssertNil(coordinator.finalizeFromDisk(dir: dir1, startedAt: Date(timeIntervalSinceNow: -300),
                                                  metadata: metadata),
                     "a second recovery of a claimed dir must be refused")
        let second = try XCTUnwrap(coordinator.finalizeFromDisk(
            dir: dir2, startedAt: Date(timeIntervalSinceNow: -300), metadata: metadata),
                                   "a different dir is not blocked by the first claim")

        let firstResult = await coordinator.awaitFinalize(first)
        let secondResult = await coordinator.awaitFinalize(second)
        let firstId = try XCTUnwrap(firstResult)
        let secondId = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(firstId, secondId)
        XCTAssertEqual(try db.allSessionSummaries().count, 2)
        XCTAssertTrue(coordinator.activeDirs.isEmpty)
        // Re-claiming a dir is possible once its job has released the claim; there is
        // nothing left to recover, though, because the audio is gone.
        XCTAssertTrue(RecordingStore.unfinalizedSessions(root: root).isEmpty)
    }
}
