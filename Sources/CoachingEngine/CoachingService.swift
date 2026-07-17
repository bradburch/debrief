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
        do {
            guard let detail = try db.sessionDetail(id: sessionId) else {
                throw ClaudeError.emptyResponse
            }
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
        await coachEach((try? db.sessionsWithTranscript()) ?? [], onProgress: onProgress)
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
    public func exportAll(to directory: URL) -> [Int64: Error] {
        var errors: [Int64: Error] = [:]
        for session in (try? db.sessionsWithTranscript()) ?? [] {
            guard let id = session.id else { continue }
            do { try exportSession(id: id, to: directory) } catch { errors[id] = error }
        }
        return errors
    }

}
