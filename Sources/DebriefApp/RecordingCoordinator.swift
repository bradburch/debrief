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
    /// Per-interview grading criteria, carried from a planned call (or the recovery prompt)
    /// into the session row at insert time. It has to travel with the metadata rather than
    /// being typed in afterwards, because feedback is written once during finalize: criteria
    /// added to the row later only reach the debrief on a re-coach.
    public var customInstructions: String
    public init(company: String, roundType: RoundType, notes: String,
                customInstructions: String = "") {
        self.company = company; self.roundType = roundType; self.notes = notes
        self.customInstructions = customInstructions
    }
}

public enum FinalizeError: LocalizedError, Equatable {
    /// Every transcribed segment was non-speech, so there is nothing to coach on.
    case noSpeechInRecording

    public var errorDescription: String? {
        switch self {
        case .noSpeechInRecording:
            return "no speech was transcribed (check the mic and system-audio permissions)"
        }
    }
}

/// Recording state only. Finalize no longer has a phase here: it runs as a job (see
/// `FinalizeJob`) so a second interview can be recorded while the first is still being
/// transcribed and coached. `.failed` covers a failed *start* — a failed finalize lands on
/// its job, which is what stops one bad debrief from bricking recording until relaunch.
public enum RecordingPhase: Equatable, Sendable {
    case idle
    case recording(started: Date)
    case failed(message: String)
}

public struct TranscribeProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// One session's post-recording work — transcribe, persist, coach, export — as display
/// state. Jobs are drained serially (they contend on the Whisper pipeline and the database)
/// but run concurrently with recording.
///
/// This is a *view* of the work, never the lock: `RecordingCoordinator.claimedDirs` is the
/// lock, and a job stays in this array after it finishes so its outcome is readable.
public struct FinalizeJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let dir: URL
    public let company: String
    public internal(set) var status: String
    public internal(set) var progress: TranscribeProgress?
    /// Non-nil only on a failed finalize; the audio is kept in `dir` when it is.
    public internal(set) var failure: String?
    public internal(set) var sessionId: Int64?
    public internal(set) var isFinished = false
}

private let logger = Logger(subsystem: "com.debrief.app", category: "coordinator")

@MainActor
public final class RecordingCoordinator: ObservableObject {
    /// Everything belonging to the one recording in flight. Collapsed into a single
    /// optional — rather than a field per writer/recorder/task — so handing a session to a
    /// finalize is one assignment: a session that starts while an earlier one is finalizing
    /// cannot inherit half of the earlier one's state.
    private struct LiveSession {
        /// Session-directory UUID. Identity is compared on this, never on the URL: URLs
        /// differ by /var vs /private/var depending on how they were derived (see the
        /// comment in `RecordingStore.unfinalizedSessions`).
        let key: String
        let dir: URL
        let micWriter: WavChunkWriter
        let sysWriter: WavChunkWriter
        let micRecorder: StreamRecorder
        let sysRecorder: StreamRecorder
        var liveTask: Task<Void, Never>?
        var chunkTranscripts: [String: [TimedText]] = [:]  // chunk filename -> accurate segments
        var micLevel: Float = 0
        var systemLevel: Float = 0
        var lastMicAudio = Date()
        var lastSysAudio = Date()
        var streamWarning: String?
        var transcribeProgress: TranscribeProgress?
    }

    @Published public private(set) var recordingPhase: RecordingPhase = .idle
    @Published public private(set) var finalizeJobs: [FinalizeJob] = []
    /// Bumped every time a job reaches a terminal state. Views observe this to know a
    /// session may have appeared — there is no longer a phase returning to `.idle` to key
    /// off, and a counter fires for failures too (a `lastFinalizedSessionId` would not).
    @Published public private(set) var finalizeCompletions = 0

    @Published private var live: LiveSession?

    public var micLevel: Float { live?.micLevel ?? 0 }
    public var systemLevel: Float { live?.systemLevel ?? 0 }
    public var streamWarning: String? { live?.streamWarning }
    /// Live-loop progress for the recording in flight. Finalize progress lives on the job.
    public var transcribeProgress: TranscribeProgress? { live?.transcribeProgress }
    public var hasActiveJobs: Bool { finalizeJobs.contains { !$0.isFinished } }

    /// Session directories that must not be touched by anything else — the live recording's
    /// plus every claimed finalize. Crash recovery filters its scan through this.
    public var activeDirs: Set<String> {
        var dirs = claimedDirs
        if let live { dirs.insert(live.key) }
        return dirs
    }

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
    private let exportDirectory: @Sendable () -> URL?

    /// **The lock.** The exclusive resource is a session directory, not the app: exactly one
    /// flow at a time may transcribe, persist, or delete a given dir. Keyed by directory
    /// UUID for the reason spelled out on `LiveSession.key`.
    ///
    /// Check-and-claim happens with no `await` in between, which is atomic because this
    /// class is `@MainActor` — the same argument the old single `phase` lock rested on,
    /// narrowed from "one flow in the app" to "one flow per directory". Claims are released
    /// in exactly one place: the `defer` at the top of `runFinalize`, which covers every
    /// exit including the zero-chunk early return.
    ///
    /// Private and non-published on purpose. `finalizeJobs` is display state and must never
    /// be consulted to decide whether a dir is claimed — a job stays in that array after it
    /// finishes and its claim is long gone.
    private var claimedDirs: Set<String> = []
    /// Tail of the finalize chain: each job awaits the previous one, so jobs run serially
    /// with each other while running concurrently with recording.
    private var finalizeChain: Task<Void, Never>?
    /// Per-job result handles for `awaitFinalize`. Dropped when the job is dismissed.
    private var jobTasks: [UUID: Task<Int64?, Never>] = [:]

    public init(db: AppDatabase,
                coaching: CoachingService,
                transcriber: Transcribing,
                makeMicRecorder: @escaping (WavChunkWriter) -> StreamRecorder,
                makeSystemRecorder: @escaping (WavChunkWriter) -> StreamRecorder,
                recordingsRoot: URL = RecordingStore.recordingsRoot(),
                chunkDuration: TimeInterval = 30,
                deleteAudioOnSuccess: Bool = true,
                exportDirectory: @escaping @Sendable () -> URL? = {
                    guard let p = UserDefaults.standard.string(forKey: "exportDirectory"), !p.isEmpty else { return nil }
                    return URL(fileURLWithPath: p)
                }) {
        self.db = db; self.coaching = coaching
        self.transcriber = transcriber
        self.makeMicRecorder = makeMicRecorder; self.makeSystemRecorder = makeSystemRecorder
        self.recordingsRoot = recordingsRoot; self.chunkDuration = chunkDuration
        self.deleteAudioOnSuccess = deleteAudioOnSuccess
        self.exportDirectory = exportDirectory
    }

    public func startRecording() async {
        // Claimed before the first `await`, and rolled back on failure. Two Record taps in
        // the same frame both used to pass this guard, since it was only re-read after the
        // recorders had started. `.failed` is startable: a start failure is a message to the
        // user, not a state the app has to be relaunched out of.
        guard live == nil else { return }
        switch recordingPhase {
        case .idle, .failed: break
        case .recording: return
        }
        let startedAt = Date()
        recordingPhase = .recording(started: startedAt)
        // Held outside the `do` so the catch can stop whatever was already started. `.failed`
        // is a startable state, so without this a retry after a half-started pair leaves the
        // first recorder's tap live — orphaned recorders stack up, keep capturing, and the
        // next session's audio is written by a recorder nothing holds a reference to.
        var mic: StreamRecorder?
        var sys: StreamRecorder?
        do {
            try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
            let dir = try RecordingStore.createSessionDirectory(root: recordingsRoot)
            let key = dir.lastPathComponent
            try RecordingStore.writeManifest(.init(startedAt: startedAt, finalized: false), in: dir)
            let micW = try WavChunkWriter(directory: dir, prefix: "mic", chunkDuration: chunkDuration)
            let sysW = try WavChunkWriter(directory: dir, prefix: "sys", chunkDuration: chunkDuration)
            let micRecorder = makeMicRecorder(micW)
            let sysRecorder = makeSystemRecorder(sysW)
            mic = micRecorder
            sys = sysRecorder
            // Pinned to `key`: a level callback queued by the previous session's recorder can
            // land after that session has been handed off, and must not drive this one's meter.
            micRecorder.onLevel = { [weak self] level in
                Task { @MainActor in self?.recordLevel(level, stream: .mic, for: key) }
            }
            sysRecorder.onLevel = { [weak self] level in
                Task { @MainActor in self?.recordLevel(level, stream: .system, for: key) }
            }
            try await micRecorder.start()
            try await sysRecorder.start()
            live = LiveSession(key: key, dir: dir, micWriter: micW, sysWriter: sysW,
                               micRecorder: micRecorder, sysRecorder: sysRecorder)
            live?.liveTask = startLiveTranscription(owner: key)
        } catch {
            live = nil
            // Tear down the half-started pair — the usual failure is the system tap being
            // refused *after* the mic engine is already running. Both stops are safe on a
            // recorder that never started (SystemAudioRecorder.releaseDevices is idempotent,
            // and finishing an empty writer is a no-op) and their failures are irrelevant
            // here: the start has already failed. `recordingPhase` is still `.recording`
            // across these awaits, so a second Record tap meanwhile still bails.
            try? await mic?.stop()
            try? await sys?.stop()
            recordingPhase = .failed(message: "Could not start recording: \(error.localizedDescription)")
        }
    }

    private enum LevelStream { case mic, system }

    private func recordLevel(_ level: Float, stream: LevelStream, for key: String) {
        guard live?.key == key else { return }
        switch stream {
        case .mic:
            live?.micLevel = level
            if level > 0.001 { live?.lastMicAudio = Date() }
        case .system:
            live?.systemLevel = level
            if level > 0.001 { live?.lastSysAudio = Date() }
        }
    }

    private func startLiveTranscription(owner key: String) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.transcribeNewChunks(owner: key)
            }
        }
    }

    /// Transcribes closed chunks the live loop hasn't cached yet, into the live session's
    /// own cache. `owner` pins every write to the session the loop belongs to: this method
    /// resumes from an `await` long after `live` may have been handed to a finalize or
    /// replaced by the next recording, and every session's first chunk is named
    /// `mic-0000.wav`, so an unpinned write files one interview's speech under another's.
    /// Passing nil means "whatever is live now", which only the tests do.
    func transcribeNewChunks(owner key: String? = nil) async {
        guard let session = live, key == nil || key == session.key else { return }
        let owner = session.key
        let chunks = session.micWriter.completedChunks + session.sysWriter.completedChunks
        for url in chunks where live?.chunkTranscripts[url.lastPathComponent] == nil {
            // Cancellation is checked per chunk, not only by the enclosing loop: without it
            // `stopAndFinalize`'s await of the cancelled task blocks for a whole chunk.
            if Task.isCancelled { return }
            // Cache only on success; a thrown failure stays uncached so it is retried
            // (here on the next poll, and again at finalize). A successful-but-empty
            // result caches as [] and counts as done.
            guard let segments = try? await transcriber.transcribe(wavURL: url) else { continue }
            guard live?.key == owner else { return }
            live?.chunkTranscripts[url.lastPathComponent] = segments
        }
        guard live?.key == owner else { return }
        let done = chunks.filter { live?.chunkTranscripts[$0.lastPathComponent] != nil }.count
        live?.transcribeProgress = TranscribeProgress(done: done, total: chunks.count)
    }

    public func checkStreamHealth(now: Date) {
        guard case .recording = recordingPhase, let session = live else {
            live?.streamWarning = nil
            return
        }
        var warnings: [String] = []
        if now.timeIntervalSince(session.lastMicAudio) > 60 { warnings.append("No audio on mic stream for 60s") }
        if now.timeIntervalSince(session.lastSysAudio) > 60 { warnings.append("No audio on system stream for 60s") }
        live?.streamWarning = warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    /// Stops the recorders and queues the session's finalize, returning the job's id (nil if
    /// nothing was recording). It deliberately does NOT wait for transcription, coaching, or
    /// export: recording is startable again as soon as this returns. Await the result with
    /// `awaitFinalize(_:)`.
    ///
    /// The order below is the contract, and the order matters in both directions:
    /// 1. claim the directory and cancel the live loop — before the first `await`, so the
    ///    claim is atomic;
    /// 2. stop the recorders, flushing the last partial chunk, **while `recordingPhase` still
    ///    says `.recording`**. Publishing `.idle` any earlier frees the main actor for the
    ///    duration of those stops, and `startRecording` would open a second mic and system
    ///    tap while this session's are still capturing — the first session's `sys-*.wav`
    ///    keeps growing past its own stop, and `runFinalize` re-reads the directory from
    ///    disk, so the *next* interview's opening lands in this one's THEM track;
    /// 3. snapshot the transcript cache, then release: `.idle` and `live = nil` together;
    /// 4. await the cancelled live loop, so no transcription is in flight at hand-off;
    /// 5. enqueue the finalize with the by-value cache.
    ///
    /// Step 4 can take as long as **two** chunk decodes — WhisperKit decodes are not
    /// cancellation-responsive, and they run through one `SerialQueue`, so the live loop's own
    /// decode may itself be queued behind a decode a concurrent finalize job is holding — but
    /// recording is already startable by then, and the directory is claimed throughout, so it
    /// is neither offered for recovery nor visible as a job for that moment. A chunk the loop was decoding is dropped from the snapshot: its
    /// write lands nowhere by design, and the job simply decodes it again. One chunk slower,
    /// against never letting a late write pick a session.
    @discardableResult
    public func stopAndFinalize(metadata: SessionMetadata) async -> UUID? {
        guard case .recording(let started) = recordingPhase, let session = live else { return nil }
        guard !claimedDirs.contains(session.key) else { return nil }
        claimedDirs.insert(session.key)
        session.liveTask?.cancel()

        // stop() failures (e.g. a final flush that couldn't write its last partial
        // chunk) are logged, not thrown: whatever chunks DID make it to disk before
        // the failure are still the best transcript data available, and surfacing a
        // hard failure here would also discard those already-flushed chunks. We
        // continue finalizing with whatever's on disk rather than losing everything.
        do { try await session.micRecorder.stop() } catch { logger.error("mic recorder stop() failed: \(error, privacy: .public)") }
        do { try await session.sysRecorder.stop() } catch { logger.error("sys recorder stop() failed: \(error, privacy: .public)") }

        // Fresher than the copy taken at the guard — the live loop may have cached another
        // chunk during the stops above — and still unambiguously this session's, because
        // `.recording` held until now.
        let cache = live?.chunkTranscripts ?? session.chunkTranscripts
        recordingPhase = .idle
        live = nil
        await session.liveTask?.value

        // After stop(), on-disk chunks and the writers' completedChunks are
        // identical, so runFinalize (which reads via RecordingStore) produces
        // the same result here as it does for a recovered (crashed) session.
        return enqueueFinalize(dir: session.dir, startedAt: started, metadata: metadata,
                               durationSeconds: Int(Date().timeIntervalSince(started)),
                               cache: cache)
    }

    /// Crash-recovery entry point for a session directory left behind by a previous,
    /// ungracefully-terminated launch (`AppEnvironment.recover`, `RecoveryTests`). Returns
    /// the queued job's id, or nil if the directory is already spoken for.
    ///
    /// **The claim contract, restated for the per-directory lock.** What must never happen
    /// twice concurrently is work on *one session directory* — two flows transcribing the
    /// same chunks, inserting the same interview, or one deleting the audio the other is
    /// reading. It is no longer "one flow in the app": recovering an old directory while a
    /// different session records, or while a different session finalizes, is safe and now
    /// deliberately allowed.
    ///
    /// So the guard is membership in `claimedDirs` (plus the live session's own dir), and
    /// the check and the insert happen back-to-back with no `await` between them — atomic,
    /// since this class is `@MainActor`. There is deliberately no branch that infers a claim
    /// from `finalizeJobs`: that array keeps finished jobs, so it would refuse a directory
    /// whose claim was released long ago, and it is written for display rather than for
    /// exclusion. `stopAndFinalize` claims by the identical two lines rather than delegating
    /// here, so neither path can ever observe a claim the other is midway through making.
    @discardableResult
    public func finalizeFromDisk(dir: URL, startedAt: Date, metadata: SessionMetadata,
                                 durationSeconds explicitDurationSeconds: Int? = nil) -> UUID? {
        let key = dir.lastPathComponent
        guard !activeDirs.contains(key) else { return nil }
        claimedDirs.insert(key)
        return enqueueFinalize(dir: dir, startedAt: startedAt, metadata: metadata,
                               durationSeconds: explicitDurationSeconds, cache: [:])
    }

    /// The session id a finalize job produced, or nil if it failed. Returns nil for an
    /// unknown id (including one whose job has been dismissed).
    public func awaitFinalize(_ id: UUID) async -> Int64? {
        guard let task = jobTasks[id] else { return nil }
        return await task.value
    }

    /// Waits for every finalize queued *so far* — the chain's tail only completes once each
    /// earlier job has. Jobs enqueued after the call are not awaited.
    public func awaitAllFinalizes() async {
        await finalizeChain?.value
    }

    /// Removes a finished job (and its result handle) from the display list.
    public func dismissJob(_ id: UUID) {
        guard let i = finalizeJobs.firstIndex(where: { $0.id == id }), finalizeJobs[i].isFinished else { return }
        finalizeJobs.remove(at: i)
        jobTasks[id] = nil
    }

    /// Queues one finalize behind the others. Note the claim on `dir` is held from *enqueue*,
    /// not from the moment this job starts running: a job stuck at the head of the queue
    /// (worst case an LLM call sitting out its client's 600s timeout) delays every job behind
    /// it and keeps their directories claimed — so not recoverable — for that whole time.
    /// Deliberate: those directories are going to be finalized, just not yet, and offering
    /// them for recovery meanwhile would be offering a second flow over the same audio.
    private func enqueueFinalize(dir: URL, startedAt: Date, metadata: SessionMetadata,
                                 durationSeconds: Int?, cache: [String: [TimedText]]) -> UUID {
        let job = FinalizeJob(id: UUID(), dir: dir, company: metadata.company, status: "Waiting…")
        finalizeJobs.append(job)
        let previous = finalizeChain
        let task = Task { [weak self] () -> Int64? in
            // Serial with other finalizes: they share one Whisper pipeline and one database
            // writer, and running them in parallel buys nothing.
            await previous?.value
            guard let self else { return nil }
            return await self.runFinalize(jobId: job.id, dir: dir, startedAt: startedAt,
                                          metadata: metadata, durationSeconds: durationSeconds,
                                          cache: cache)
        }
        jobTasks[job.id] = task
        finalizeChain = Task { _ = await task.value }
        return job.id
    }

    private func updateJob(_ id: UUID, _ mutate: (inout FinalizeJob) -> Void) {
        guard let i = finalizeJobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&finalizeJobs[i])
    }

    private func finishJob(_ id: UUID, sessionId: Int64?, status: String, failure: String? = nil) {
        // Progress is left at its final value rather than cleared: "4/4 chunks" under a
        // finished job is the evidence that the transcript is complete.
        updateJob(id) {
            $0.sessionId = sessionId
            $0.status = status
            $0.failure = failure
            $0.isFinished = true
        }
        finalizeCompletions += 1
    }

    /// Transcribes chunks found on disk under `dir`, merges, persists a session +
    /// segments, deletes the audio on success (if configured), and runs coaching.
    /// Used both by `stopAndFinalize` (post-stop, disk == completedChunks) and by
    /// `finalizeFromDisk` (crash recovery). Its caller has already claimed `dir`; this is
    /// the only place that claim is released.
    ///
    /// `cache` is the live loop's per-chunk transcripts, passed **by value**. It must not be
    /// read off `live`: the cache is keyed by bare filename, every session's first chunk is
    /// `mic-0000.wav`, and by the time this runs `live` may well be the *next* interview.
    ///
    /// `durationSeconds`, when non-nil, is the exact wall-clock duration of a live
    /// session (passed by `stopAndFinalize`); recovery callers leave it nil and get
    /// a chunkCount * chunkDuration approximation instead, since the real start/stop
    /// times aren't known for a crashed session.
    private func runFinalize(jobId: UUID, dir: URL, startedAt: Date, metadata: SessionMetadata,
                             durationSeconds explicitDurationSeconds: Int?,
                             cache: [String: [TimedText]]) async -> Int64? {
        // The single release site for the claim taken by stopAndFinalize/finalizeFromDisk,
        // covering every exit below including the zero-chunk return and the catch.
        defer { claimedDirs.remove(dir.lastPathComponent) }

        let micChunks = RecordingStore.chunkURLs(in: dir, prefix: "mic")
        let sysChunks = RecordingStore.chunkURLs(in: dir, prefix: "sys")

        if micChunks.isEmpty, sysChunks.isEmpty, explicitDurationSeconds == nil {
            // Zero-chunk recovery: no audio ever made it to disk. Creating a
            // segment-less session with a fallback duration computed "now" (days
            // after the crash) would be nonsense. Leave the dir for the user to
            // Discard from the recovery banner instead.
            logger.error("finalizeFromDisk: zero chunks on both streams for recovered dir \(dir.path, privacy: .public); skipping")
            finishJob(jobId, sessionId: nil, status: "No audio found",
                      failure: "No audio was found in \(dir.path) — discard it from the recovery prompt.")
            return nil
        }

        // Tracked across the do/catch below so the catch block can compensate for a
        // session row that got inserted but whose segments then failed to persist.
        var insertedSessionId: Int64?
        var segmentsInserted = false

        do {
            updateJob(jobId) {
                $0.status = "Transcribing…"
                $0.progress = TranscribeProgress(done: 0, total: micChunks.count + sysChunks.count)
            }
            let you = await transcribeStream(chunks: micChunks, cache: cache, jobId: jobId)
            let them = await transcribeStream(chunks: sysChunks, cache: cache, jobId: jobId)
            let lines = TranscriptMerger.merge(you: you, them: them)

            updateJob(jobId) { $0.status = "Saving…" }
            let company = try db.fetchOrCreateCompany(named: metadata.company)
            let durationSeconds = explicitDurationSeconds
                ?? Int(Double(max(micChunks.count, sysChunks.count)) * chunkDuration)
            let session = try db.insertSession(InterviewSession(
                id: nil, companyId: company.id!, roundType: metadata.roundType, date: startedAt,
                durationSeconds: durationSeconds,
                contextNotes: metadata.notes, coachingStatus: .pending,
                customInstructions: metadata.customInstructions))
            insertedSessionId = session.id
            // Stamped before the segments land, while the dir still reads as unfinalized: a
            // crash from here on leaves a directory that recovery must NOT offer again, and
            // the session id is how it knows (see AppEnvironment.refreshRecoverables).
            try? RecordingStore.writeManifest(.init(startedAt: startedAt, finalized: false,
                                                    sessionId: session.id), in: dir)
            let inserted = try db.insertSegments(lines.map { line in
                TranscriptSegmentRecord(id: nil, sessionId: session.id!,
                                        speaker: line.speaker == .you ? .you : .them,
                                        tStart: line.start, text: line.text)
            })
            // insertSegments drops non-speech, so `lines` being non-empty does not mean any
            // row landed — a call recorded with the mic muted transcribes to nothing but
            // [BLANK_AUDIO]. Throwing routes into the catch below, which deletes the orphaned
            // session and keeps the audio. Without this the session persists with an empty
            // transcript and still gets coached, and the LLM invents a debrief for an
            // interview it never saw.
            guard inserted > 0 else { throw FinalizeError.noSpeechInRecording }
            segmentsInserted = true
            // `try?`, unlike the writes above: by this point the session and its transcript are
            // in the database, which is the truth — the manifest is only a hint to the recovery
            // scan, and the scan's own `sessionHasTranscript` filter already suppresses this
            // directory whether or not the stamp lands. Throwing here would route into the
            // catch, report a finished debrief as "Failed", and (with audio kept) offer the
            // same interview for recovery again, inserting it twice.
            try? RecordingStore.writeManifest(.init(startedAt: startedAt, finalized: true,
                                                    sessionId: session.id), in: dir)
            if deleteAudioOnSuccess { try? RecordingStore.deleteSession(at: dir) }

            updateJob(jobId) { $0.status = "Coaching…" }
            try? await coaching.coach(sessionId: session.id!)  // failure leaves session retryable

            // Export a Cowork-readable markdown copy if an export folder is configured.
            // Non-fatal, same contract as coaching above: a failed export never fails finalize.
            if let exportDir = exportDirectory() {
                try? coaching.exportSession(id: session.id!, to: exportDir)
            }

            finishJob(jobId, sessionId: session.id, status: "Debriefed \(metadata.company)")
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
                // Outside the do/catch on purpose: the stamp must go even when the delete
                // fails. A stamp naming a row that isn't there — or one that is there with no
                // transcript — would otherwise keep suppressing recovery of this directory.
                try? RecordingStore.writeManifest(.init(startedAt: startedAt, finalized: false), in: dir)
            }
            finishJob(jobId, sessionId: nil, status: "Failed",
                      failure: "Finalize failed: \(error.localizedDescription). Audio kept at \(dir.path)")
            return nil
        }
    }

    /// Build one stream's transcript, offsetting each chunk's segment times by its
    /// position. Reuses the accurate result the live loop already cached; only
    /// transcribes chunks not yet cached (the final partial chunk, an un-polled tail,
    /// or — on crash recovery — every chunk, since a fresh process has no cache).
    private func transcribeStream(chunks: [URL], cache: [String: [TimedText]],
                                  jobId: UUID) async -> [TimedText] {
        var all: [TimedText] = []
        for (index, url) in chunks.enumerated() {
            let offset = Double(index) * chunkDuration
            let segments: [TimedText]
            if let cached = cache[url.lastPathComponent] {
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
            updateJob(jobId) { job in
                job.progress = job.progress.map { TranscribeProgress(done: $0.done + 1, total: $0.total) }
            }
        }
        return all
    }
}
