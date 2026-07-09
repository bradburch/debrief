import XCTest
import AVFoundation
@testable import DebriefApp
import CaptureKit
import Store
import CoachingEngine
import Transcriber

/// A `Transcribing` that sleeps briefly before returning, so tests can force a
/// `finalizeFromDisk` call to be suspended mid-transcription -- long enough for
/// a second concurrent call to observe the in-progress `.finalizing` phase.
private struct SlowFakeTranscriber: Transcribing {
    let textForChunk: String
    func transcribe(wavURL: URL) async throws -> [TimedText] {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return [TimedText(start: 1.0, text: "\(textForChunk) \(wavURL.lastPathComponent)")]
    }
}

@MainActor
final class RecoveryTests: XCTestCase {
    func testFinalizeFromDiskRecoversOrphanedChunks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.writeManifest(.init(startedAt: Date(timeIntervalSinceNow: -300), finalized: false), in: dir)

        // Orphaned chunks from a "crashed" session.
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        for prefix in ["mic", "sys"] {
            let writer = try WavChunkWriter(directory: dir, prefix: prefix, chunkDuration: 1.0)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000)!
            buf.frameLength = 16_000
            try writer.append(buf)
            try writer.finish()
        }

        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir); try prompts.ensureDefaults()
        let coordinator = RecordingCoordinator(
            db: db, coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "recovered"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            recordingsRoot: root, chunkDuration: 1.0)

        let id = await coordinator.finalizeFromDisk(
            dir: dir, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered"))
        let sessionId = try XCTUnwrap(id)
        let detail = try XCTUnwrap(db.sessionDetail(id: sessionId))
        XCTAssertTrue(detail.segments.contains { $0.text.contains("recovered") })
        XCTAssertTrue(RecordingStore.unfinalizedSessions(root: root).isEmpty)
    }

    /// finalizeFromDisk must refuse to run concurrently with (or during) a live
    /// recording: two Recover taps, or a Recover while another flow is active,
    /// must not both proceed and fight over `phase`/the on-disk session.
    func testRecoveryRefusedWhileNotIdle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Seed an orphaned session directory to attempt recovery on.
        let orphanDir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.writeManifest(.init(startedAt: Date(timeIntervalSinceNow: -300), finalized: false), in: orphanDir)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        for prefix in ["mic", "sys"] {
            let writer = try WavChunkWriter(directory: orphanDir, prefix: prefix, chunkDuration: 1.0)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000)!
            buf.frameLength = 16_000
            try writer.append(buf)
            try writer.finish()
        }

        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir); try prompts.ensureDefaults()
        let coordinator = RecordingCoordinator(
            db: db, coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "recovered"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            recordingsRoot: root, chunkDuration: 1.0)

        // A separate live recording is in flight (a different session dir, live
        // under `root` too, but that's irrelevant -- what matters is `phase`).
        await coordinator.startRecording()
        guard case .recording = coordinator.phase else {
            return XCTFail("expected recording, got \(coordinator.phase)")
        }

        let id = await coordinator.finalizeFromDisk(
            dir: orphanDir, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered"))
        XCTAssertNil(id, "finalizeFromDisk must refuse while phase is not .idle or .finalizing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanDir.path), "orphan dir must be left untouched")

        // Clean up the live recording.
        _ = await coordinator.stopAndFinalize(metadata: .init(company: "Acme", roundType: .technical, notes: ""))
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
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir); try prompts.ensureDefaults()
        let coordinator = RecordingCoordinator(
            db: db, coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "recovered"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            recordingsRoot: root, chunkDuration: 1.0)

        let id = await coordinator.finalizeFromDisk(
            dir: dir, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered"))
        XCTAssertNil(id)
        XCTAssertTrue(try db.allSessionSummaries().isEmpty, "no session should be created for a zero-chunk recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "dir must be left for the user to Discard")
        if case .idle = coordinator.phase {} else { XCTFail("expected phase back to .idle, got \(coordinator.phase)") }
    }

    /// A second `finalizeFromDisk` call racing an in-flight one must be refused,
    /// not just a call racing a live `.recording`. The old phase guard trusted
    /// `.finalizing` as "delegated from stopAndFinalize, proceed" regardless of
    /// *who* claimed it, so a second recovery call landing while the first was
    /// still suspended mid-transcription would see phase == .finalizing and take
    /// that same "proceed" branch, running concurrently with the first.
    func testConcurrentRecoveryRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func seedOrphanDir() throws -> URL {
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

        let dir1 = try seedOrphanDir()
        let dir2 = try seedOrphanDir()

        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir); try prompts.ensureDefaults()
        let coordinator = RecordingCoordinator(
            db: db, coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: SlowFakeTranscriber(textForChunk: "recovered"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 1) },
            recordingsRoot: root, chunkDuration: 1.0)

        async let first: Int64? = coordinator.finalizeFromDisk(
            dir: dir1, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered"))

        // Let the first call claim `.finalizing` and suspend inside transcription
        // (which sleeps 300ms) before the second call is issued.
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .finalizing = coordinator.phase else {
            return XCTFail("expected first call to have claimed .finalizing by now, got \(coordinator.phase)")
        }

        let second = await coordinator.finalizeFromDisk(
            dir: dir2, startedAt: Date(timeIntervalSinceNow: -300),
            metadata: .init(company: "Acme", roundType: .technical, notes: "recovered"))
        XCTAssertNil(second, "a second finalizeFromDisk racing an in-flight one must be refused")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir2.path), "dir2 must be left untouched")

        let firstResult = await first
        let firstId = try XCTUnwrap(firstResult, "the first, legitimately-delegated call must still succeed")
        XCTAssertNotNil(try db.sessionDetail(id: firstId))
    }
}
