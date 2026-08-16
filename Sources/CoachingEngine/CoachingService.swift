import Foundation
import Store

public struct CoachingService: Sendable {
    let db: AppDatabase
    let prompts: PromptStore
    let llm: CoachingLLM
    let historyWindow: Int

    public init(db: AppDatabase, prompts: PromptStore, llm: CoachingLLM, historyWindow: Int = 10) {
        self.db = db; self.prompts = prompts; self.llm = llm; self.historyWindow = historyWindow
    }

    public func coach(sessionId: Int64) async throws {
        // Restored if the call is cancelled: a stopped re-run must leave the session exactly
        // as it was, including a `complete` it already held. Set from what `claimCoaching`
        // reports the row held inside the claiming transaction — a status read before the
        // claim can already be stale by the time the claim lands.
        var statusBeforeClaim: CoachingStatus?
        do {
            guard let detail = try db.sessionDetail(id: sessionId) else {
                throw ClaudeError.emptyResponse
            }
            // Claim the session before anything else touches its status. `claimCoaching` reads
            // and writes in one transaction and returns nil when the session was already
            // `running`: someone else — a finalize job, most likely, with the user hitting
            // "Re-run debriefs" meanwhile — has an LLM call out for it. Bailing is what makes
            // `running` an actual claim rather than a label: two calls would bill twice and
            // race to write the same feedback row. Not an error; the debrief in flight is the
            // one that lands. `running` is cleared by whichever call owns it, or by the launch
            // sweep if that process died.
            //
            // This is deliberately the FIRST write, ahead of the transcript-only check below.
            // The reachable case is a round type changed to a transcript-only one while a
            // debrief for that session is in flight (SessionsView's type picker re-coaches):
            // checking first would stamp `skipped` over a live claim, and the call still in
            // flight would then overwrite it with `complete` and a debrief the round type says
            // must not exist.
            guard let previousStatus = try db.claimCoaching(sessionId: sessionId) else { return }
            statusBeforeClaim = previousStatus
            // Transcript-only round types stop here: recorded and transcribed, never scored.
            // The guard lives in coach() rather than at the call sites because all three
            // paths — finalize, retryAllPending, and recoachAll — funnel through here, so
            // one check keeps a practice round from ever billing an LLM call. `skipped` is
            // terminal, so the retry sweeps stop offering it too.
            if prompts.isTranscriptOnly(detail.session.roundType) {
                try db.markCoachingSkipped(sessionId: sessionId)
                return
            }
            // Someone else already has an LLM call out for this session — a finalize job,
            // most likely, with the user hitting "Re-run debriefs" meanwhile. Bailing is what
            // makes `running` an actual claim rather than a label: two calls would bill twice
            // and race to write the same feedback row. Not an error; the debrief in flight is
            // the one that lands. `running` is cleared by whichever call owns it, or by the
            // launch sweep if that process died.
            if detail.session.coachingStatus == .running { return }
            let history = try db.recentWeaknessTags(limitSessions: historyWindow)
            let system = try prompts.assembleSystemPrompt(roundType: detail.session.roundType,
                                                          historyTags: history,
                                                          customInstructions: detail.session.customInstructions)
            let dimensions = try prompts.dimensions(for: detail.session.roundType)
            let transcript = try db.transcriptText(sessionId: sessionId)
            let user = """
            Interview metadata:
            - Company: \(detail.company.name)
            - Round type: \(detail.session.roundType.displayName)
            - Duration: \(detail.session.durationSeconds / 60) minutes
            - Candidate notes: \(detail.session.contextNotes.isEmpty ? "none" : detail.session.contextNotes)

            Transcript:
            \(transcript)
            """
            // Claimed before the await, not after: coaching now runs concurrently with a
            // later recording's finalize and with the Retry sweep, and `running` is what
            // keeps a second caller from billing a duplicate call for this session.
            statusBeforeClaim = detail.session.coachingStatus
            try db.setCoachingStatus(sessionId: sessionId, .running)
            let result = try await llm.generateCoaching(systemPrompt: system, userMessage: user,
                                                        dimensions: dimensions)

            let encoder = JSONEncoder()
            let feedback = FeedbackRecord(
                id: nil, sessionId: sessionId,
                proseDebrief: result.proseDebrief,
                scoresJSON: String(data: try encoder.encode(result.scores), encoding: .utf8)!,
                highlightsJSON: String(data: try encoder.encode(result.highlights), encoding: .utf8)!,
                actionItemsJSON: String(data: try encoder.encode(result.actionItems), encoding: .utf8)!,
                overallScore: result.overallScore,
                advancement: result.advancement.rawValue,
                advancementRationale: result.advancementRationale,
                processNotesJSON: String(data: try encoder.encode(result.processNotes), encoding: .utf8)!)
            try db.saveFeedback(feedback, tags: result.weaknessTags)
        } catch {
            // A cancelled debrief is not a failed one. Stopping a re-run cancels the in-flight
            // URLSession call, and marking that session `failed` would flip a session that
            // still holds perfectly good feedback into an error state the user has to clean
            // up — the exact opposite of what Stop should do.
            //
            // Keyed on Task.isCancelled, not the error type: a URLError.cancelled with no task
            // cancellation behind it (a proxy or the OS killing the connection) is a genuine
            // failure and must stay retryable.
            if !Task.isCancelled {
                try? db.markCoachingFailed(sessionId: sessionId)
            } else if let statusBeforeClaim {
                // Undo the `running` claim. Leaving it would be worse than the old no-op:
                // `running` is excluded from every sweep, so a stopped re-run would strand
                // the session until the next launch reclaimed it. Restoring `running` itself
                // would strand it the same way — unreachable, since `claimCoaching` never
                // returns `running`, but clamped rather than trusted, because the cost of
                // being wrong is a session no sweep will ever pick up.
                try? db.setCoachingStatus(sessionId: sessionId,
                                          statusBeforeClaim == .running ? .pending : statusBeforeClaim)
            }
            throw error
        }
    }

    /// Retries every session that has a transcript but no completed coaching.
    /// Returns per-session errors; an empty dictionary means no failures among
    /// attempted sessions. Note: if the initial fetch of pending sessions fails,
    /// no sessions are attempted and this also returns empty as a conservative
    /// no-op, not as a signal that everything succeeded.
    public func retryAllPending() async -> [Int64: Error] {
        await coachEach((try? db.sessionsNeedingCoaching()) ?? [])
    }

    /// Re-runs coaching for EVERY session with a transcript, including already-complete
    /// ones. This is how a rubric change (new scored dimensions, the advancement verdict)
    /// reaches existing debriefs — without it, old and new sessions carry incomparable
    /// scores in the same column. Idempotent: saveFeedback replaces the row and its tags.
    ///
    /// Costs one LLM call per session and overwrites debrief prose the user may have read.
    /// Callers should confirm first.
    ///
    /// `onProgress(completed, total)` fires once before the first call (with 0) so a caller
    /// can show a determinate total immediately, then after each session settles. One LLM
    /// call runs ~30s, so a multi-minute run without this reads as a hang.
    /// Honors cancellation between sessions: sessions already re-coached keep their new
    /// feedback, and the rest stay on the old rubric until re-run.
    public func recoachAll(onProgress: @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async -> [Int64: Error] {
        // Filtered here rather than in the query: `sessionsWithTranscript` is shared with
        // exportAll, which must keep transcript-only sessions. Re-coaching them would bill
        // an LLM call per practice session to produce nothing — coach() would skip them
        // anyway, but they'd still inflate the progress total the user watches.
        let sessions = ((try? db.sessionsWithTranscript()) ?? [])
            .filter { $0.coachingStatus != .skipped }
        return await coachEach(sessions, onProgress: onProgress)
    }

    private func coachEach(_ sessions: [InterviewSession],
                           onProgress: @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async -> [Int64: Error] {
        var errors: [Int64: Error] = [:]
        await onProgress(0, sessions.count)
        for (i, session) in sessions.enumerated() {
            if Task.isCancelled { break }
            if let id = session.id {
                do { try await coach(sessionId: id) }
                catch {
                    // Stop lands here (the in-flight request throws). It is not a per-session
                    // failure and must not be reported as one, or Stop would always look like
                    // "1 failed". Gated on Task.isCancelled rather than the error type:
                    // retryAllPending shares this loop and has no Stop button, so a stray
                    // URLError.cancelled there must be recorded, not silently end the run.
                    if Task.isCancelled { break }
                    errors[id] = error
                }
            }
            // Outside the `if let` so a malformed row can't stall the caller's progress bar.
            await onProgress(i + 1, sessions.count)
        }
        return errors
    }

    /// Writes one session's markdown to `directory` (created if needed), overwriting the
    /// deterministic per-session filename so re-exports don't pile up. No-op if the session
    /// or its detail is missing.
    public func exportSession(id: Int64, to directory: URL) throws {
        guard let detail = try db.sessionDetail(id: id) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(SessionMarkdown.filename(for: detail))
        try SessionMarkdown.render(detail).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Exports every session that has a transcript. Returns per-session errors; keeps going
    /// past a failure so one unwritable file can't abort the batch.
    ///
    /// Creates `directory` once up front rather than relying on each `exportSession`'s own
    /// (idempotent) createDirectory: if the directory is genuinely unwritable, that failure
    /// would otherwise recur once per session and mask the single root cause behind N
    /// identical per-session errors. On that failure, returns a single sentinel entry (key
    /// -1, which is never a real session id) instead of iterating at all.
    public func exportAll(to directory: URL) -> [Int64: Error] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return [-1: error]
        }
        var errors: [Int64: Error] = [:]
        for session in (try? db.sessionsWithTranscript()) ?? [] {
            guard let id = session.id else { continue }
            do { try exportSession(id: id, to: directory) } catch { errors[id] = error }
        }
        return errors
    }

}
