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
                                                          historyTags: history)
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
            let result = try await llm.generateCoaching(systemPrompt: system, userMessage: user)

            let encoder = JSONEncoder()
            let feedback = FeedbackRecord(
                id: nil, sessionId: sessionId,
                proseDebrief: result.proseDebrief,
                scoresJSON: String(data: try encoder.encode(result.scores), encoding: .utf8)!,
                highlightsJSON: String(data: try encoder.encode(result.highlights), encoding: .utf8)!,
                actionItemsJSON: String(data: try encoder.encode(result.actionItems), encoding: .utf8)!,
                overallScore: result.overallScore)
            try db.saveFeedback(feedback, tags: result.weaknessTags)
        } catch {
            try? db.markCoachingFailed(sessionId: sessionId)
            throw error
        }
    }

    /// Retries every session that has a transcript but no completed coaching.
    /// Returns per-session errors; an empty dictionary means no failures among
    /// attempted sessions. Note: if the initial fetch of pending sessions fails,
    /// no sessions are attempted and this also returns empty as a conservative
    /// no-op, not as a signal that everything succeeded.
    public func retryAllPending() async -> [Int64: Error] {
        var errors: [Int64: Error] = [:]
        let sessions = (try? db.sessionsNeedingCoaching()) ?? []
        for session in sessions {
            guard let id = session.id else { continue }
            do { try await coach(sessionId: id) } catch { errors[id] = error }
        }
        return errors
    }
}
