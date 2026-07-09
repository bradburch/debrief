import Foundation
import AVFoundation
import CaptureKit
import Transcriber
import Store
import CoachingEngine
import os

public struct SessionMetadata: Sendable {
    public var company: String
    public var roundType: RoundType
    public var notes: String
    public init(company: String, roundType: RoundType, notes: String) {
        self.company = company; self.roundType = roundType; self.notes = notes
    }
}

public enum RecordingPhase: Equatable, Sendable {
    case idle
    case recording(started: Date)
    case finalizing(status: String)
    case failed(message: String)
}

public struct TranscribeProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

private let logger = Logger(subsystem: "com.debrief.app", category: "coordinator")

@MainActor
public final class RecordingCoordinator: ObservableObject {
    @Published public private(set) var phase: RecordingPhase = .idle
    @Published public var micLevel: Float = 0
    @Published public var systemLevel: Float = 0
    @Published public private(set) var streamWarning: String?
    @Published public private(set) var transcribeProgress: TranscribeProgress?

    private let db: AppDatabase
    /// Mutable so a Claude API key saved in Settings mid-run applies to the next
    /// auto-debrief without relaunching (AppEnvironment.rebuildCoaching reassigns it).
    public var coaching: CoachingService
    private let transcriber: Transcribing
    private let makeMicRecorder: (WavChunkWriter) -> StreamRecorder
    private let makeSystemRecorder: (WavChunkWriter) -> StreamRecorder
    private let recordingsRoot: URL
    private let chunkDuration: TimeInterval
    private let deleteAudioOnSuccess: Bool

    private var sessionDir: URL?
    private var micWriter: WavChunkWriter?
    private var sysWriter: WavChunkWriter?
    private var micRecorder: StreamRecorder?
    private var sysRecorder: StreamRecorder?
    private var chunkTranscripts: [String: [TimedText]] = [:]  // chunk filename -> accurate segments
    private var liveTask: Task<Void, Never>?
    private var lastMicAudio = Date()
    private var lastSysAudio = Date()

    public init(db: AppDatabase,
                coaching: CoachingService,
                transcriber: Transcribing,
                makeMicRecorder: @escaping (WavChunkWriter) -> StreamRecorder,
                makeSystemRecorder: @escaping (WavChunkWriter) -> StreamRecorder,
                recordingsRoot: URL = RecordingStore.recordingsRoot(),
                chunkDuration: TimeInterval = 30,
                deleteAudioOnSuccess: Bool = true) {
        self.db = db; self.coaching = coaching
        self.transcriber = transcriber
        self.makeMicRecorder = makeMicRecorder; self.makeSystemRecorder = makeSystemRecorder
        self.recordingsRoot = recordingsRoot; self.chunkDuration = chunkDuration
        self.deleteAudioOnSuccess = deleteAudioOnSuccess
    }

    public func startRecording() async {
        guard case .idle = phase else { return }
        do {
            try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
            let dir = try RecordingStore.createSessionDirectory(root: recordingsRoot)
            try RecordingStore.writeManifest(.init(startedAt: Date(), finalized: false), in: dir)
            let micW = try WavChunkWriter(directory: dir, prefix: "mic", chunkDuration: chunkDuration)
            let sysW = try WavChunkWriter(directory: dir, prefix: "sys", chunkDuration: chunkDuration)
            let mic = makeMicRecorder(micW)
            let sys = makeSystemRecorder(sysW)
            mic.onLevel = { [weak self] level in
                Task { @MainActor in
                    self?.micLevel = level
                    if level > 0.001 { self?.lastMicAudio = Date() }
                }
            }
            sys.onLevel = { [weak self] level in
                Task { @MainActor in
                    self?.systemLevel = level
                    if level > 0.001 { self?.lastSysAudio = Date() }
                }
            }
            try await mic.start()
            try await sys.start()
            sessionDir = dir; micWriter = micW; sysWriter = sysW
            micRecorder = mic; sysRecorder = sys
            lastMicAudio = Date(); lastSysAudio = Date()
            streamWarning = nil
            chunkTranscripts = [:]
            transcribeProgress = nil
            phase = .recording(started: Date())
            startLiveTranscription()
        } catch {
            phase = .failed(message: "Could not start recording: \(error.localizedDescription)")
        }
    }

    private func startLiveTranscription() {
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.transcribeNewChunks()
            }
        }
    }

    func transcribeNewChunks() async {
        let chunks = (micWriter?.completedChunks ?? []) + (sysWriter?.completedChunks ?? [])
        for url in chunks where chunkTranscripts[url.lastPathComponent] == nil {
            // Cache only on success; a thrown failure stays uncached so it is retried
            // (here on the next poll, and again at finalize). A successful-but-empty
            // result caches as [] and counts as done.
            if let segments = try? await transcriber.transcribe(wavURL: url) {
                chunkTranscripts[url.lastPathComponent] = segments
            }
        }
        let done = chunks.filter { chunkTranscripts[$0.lastPathComponent] != nil }.count
        transcribeProgress = TranscribeProgress(done: done, total: chunks.count)
    }

    public func checkStreamHealth(now: Date) {
        guard case .recording = phase else { streamWarning = nil; return }
        var warnings: [String] = []
        if now.timeIntervalSince(lastMicAudio) > 60 { warnings.append("No audio on mic stream for 60s") }
        if now.timeIntervalSince(lastSysAudio) > 60 { warnings.append("No audio on system stream for 60s") }
        streamWarning = warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    public func stopAndFinalize(metadata: SessionMetadata) async -> Int64? {
        guard case .recording(let started) = phase, let dir = sessionDir,
              micWriter != nil, sysWriter != nil else { return nil }
        phase = .finalizing(status: "Stopping recorders…")
        liveTask?.cancel()
        // stop() failures (e.g. a final flush that couldn't write its last partial
        // chunk) are logged, not thrown: whatever chunks DID make it to disk before
        // the failure are still the best transcript data available, and surfacing a
        // hard failure here would also discard those already-flushed chunks. We
        // continue finalizing with whatever's on disk rather than losing everything.
        do { try await micRecorder?.stop() } catch { logger.error("mic recorder stop() failed: \(error, privacy: .public)") }
        do { try await sysRecorder?.stop() } catch { logger.error("sys recorder stop() failed: \(error, privacy: .public)") }

        // After stop(), on-disk chunks and the writers' completedChunks are
        // identical, so runFinalize (which reads via RecordingStore) produces
        // the same result here as it does for a recovered (crashed) session.
        // runFinalize always leaves phase in a terminal state (.idle or .failed).
        let result = await runFinalize(dir: dir, startedAt: started, metadata: metadata,
                                        durationSeconds: Int(Date().timeIntervalSince(started)))
        cleanupState()
        return result
    }

    /// Crash-recovery entry point for a session directory left behind by a
    /// previous, ungracefully-terminated launch (`AppEnvironment.recover`,
    /// `RecoveryTests`).
    ///
    /// Recovery only ever starts from `.idle`: the guard and the claim of
    /// `.finalizing(status: "Recovering…")` happen back-to-back with no `await`
    /// between them, so — since `RecordingCoordinator` is `@MainActor` — that
    /// pair is atomic and only the caller that wins the guard can ever reach
    /// `runFinalize`. There is deliberately no branch here that trusts an
    /// already-`.finalizing` phase as "someone else claimed it, proceed": that
    /// used to exist to let `stopAndFinalize` delegate into this method, but it
    /// meant a *second* concurrent `finalizeFromDisk` call would observe the
    /// first call's `.finalizing` phase value and take the same "proceed"
    /// branch, running alongside it. Delegation from `stopAndFinalize` now goes
    /// directly to the private `runFinalize` core instead, which assumes its
    /// caller already owns the `.finalizing` phase by construction rather than
    /// by re-checking a value that a racing caller could equally observe.
    @discardableResult
    public func finalizeFromDisk(dir: URL, startedAt: Date, metadata: SessionMetadata,
                                  durationSeconds explicitDurationSeconds: Int? = nil) async -> Int64? {
        guard case .idle = phase else { return nil } // recording, or already finalizing/failed; refuse.
        phase = .finalizing(status: "Recovering…") // claim atomically before any await.
        return await runFinalize(dir: dir, startedAt: startedAt, metadata: metadata,
                                  durationSeconds: explicitDurationSeconds)
    }

    /// Transcribes chunks found on disk under `dir`, merges, persists a session +
    /// segments, deletes the audio on success (if configured), and runs coaching.
    /// Used both by `stopAndFinalize` (post-stop, disk == completedChunks) and by
    /// `finalizeFromDisk` (crash recovery). Assumes the caller already owns
    /// `phase == .finalizing` -- it does not check or claim phase itself, so
    /// callers must have claimed it atomically (no `await` between the guard and
    /// the claim) before calling in.
    ///
    /// `durationSeconds`, when non-nil, is the exact wall-clock duration of a live
    /// session (passed by `stopAndFinalize`); recovery callers leave it nil and get
    /// a chunkCount * chunkDuration approximation instead, since the real start/stop
    /// times aren't known for a crashed session.
    private func runFinalize(dir: URL, startedAt: Date, metadata: SessionMetadata,
                              durationSeconds explicitDurationSeconds: Int?) async -> Int64? {
        let micChunks = RecordingStore.chunkURLs(in: dir, prefix: "mic")
        let sysChunks = RecordingStore.chunkURLs(in: dir, prefix: "sys")

        if micChunks.isEmpty, sysChunks.isEmpty, explicitDurationSeconds == nil {
            // Zero-chunk recovery: no audio ever made it to disk. Creating a
            // segment-less session with a fallback duration computed "now" (days
            // after the crash) would be nonsense. Leave the dir for the user to
            // Discard from the recovery banner instead.
            logger.error("finalizeFromDisk: zero chunks on both streams for recovered dir \(dir.path, privacy: .public); skipping")
            phase = .idle
            return nil
        }

        // Tracked across the do/catch below so the catch block can compensate for a
        // session row that got inserted but whose segments then failed to persist.
        var insertedSessionId: Int64?
        var segmentsInserted = false

        do {
            phase = .finalizing(status: "Transcribing…")
            transcribeProgress = TranscribeProgress(done: 0, total: micChunks.count + sysChunks.count)
            let you = await transcribeStream(chunks: micChunks)
            let them = await transcribeStream(chunks: sysChunks)
            let lines = TranscriptMerger.merge(you: you, them: them)

            phase = .finalizing(status: "Saving…")
            let company = try db.fetchOrCreateCompany(named: metadata.company)
            let durationSeconds = explicitDurationSeconds
                ?? Int(Double(max(micChunks.count, sysChunks.count)) * chunkDuration)
            let session = try db.insertSession(InterviewSession(
                id: nil, companyId: company.id!, roundType: metadata.roundType, date: startedAt,
                durationSeconds: durationSeconds,
                contextNotes: metadata.notes, coachingStatus: .pending))
            insertedSessionId = session.id
            try db.insertSegments(lines.map { line in
                TranscriptSegmentRecord(id: nil, sessionId: session.id!,
                                        speaker: line.speaker == .you ? .you : .them,
                                        tStart: line.start, text: line.text)
            })
            segmentsInserted = true
            try RecordingStore.writeManifest(.init(startedAt: startedAt, finalized: true), in: dir)
            if deleteAudioOnSuccess { try? RecordingStore.deleteSession(at: dir) }

            phase = .finalizing(status: "Coaching…")
            try? await coaching.coach(sessionId: session.id!)  // failure leaves session retryable

            phase = .idle
            return session.id
        } catch {
            // If the session row was inserted but its segments never made it in,
            // don't leave an orphaned, segment-less session behind.
            if let id = insertedSessionId, !segmentsInserted {
                do {
                    try db.deleteSession(id: id)
                } catch {
                    logger.error("failed to delete orphaned session \(id, privacy: .public): \(error, privacy: .public)")
                }
            }
            phase = .failed(message: "Finalize failed: \(error.localizedDescription). Audio kept at \(dir.path)")
            return nil
        }
    }

    /// Build one stream's transcript, offsetting each chunk's segment times by its
    /// position. Reuses the accurate result the live loop already cached; only
    /// transcribes chunks not yet cached (the final partial chunk, an un-polled tail,
    /// or — on crash recovery — every chunk, since a fresh process has no cache).
    private func transcribeStream(chunks: [URL]) async -> [TimedText] {
        var all: [TimedText] = []
        for (index, url) in chunks.enumerated() {
            let offset = Double(index) * chunkDuration
            let segments: [TimedText]
            if let cached = chunkTranscripts[url.lastPathComponent] {
                segments = cached
            } else if let fresh = try? await transcriber.transcribe(wavURL: url) {
                segments = fresh
            } else {
                // ponytail: base.en fallback removed. A chunk that fails the accurate
                // model both live and here yields empty text; failures are correlated
                // (same audio/lib), so this is rare. Upgrade path: re-add a lighter
                // fallback model only if empties show up in practice.
                segments = []
            }
            all += segments.map { TimedText(start: $0.start + offset, text: $0.text) }
            transcribeProgress = transcribeProgress.map { TranscribeProgress(done: $0.done + 1, total: $0.total) }
        }
        return all
    }

    private func cleanupState() {
        sessionDir = nil; micWriter = nil; sysWriter = nil
        micRecorder = nil; sysRecorder = nil
        liveTask = nil; chunkTranscripts = [:]
        micLevel = 0; systemLevel = 0; streamWarning = nil
    }
}
