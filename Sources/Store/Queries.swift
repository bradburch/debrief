import Foundation
import GRDB

public struct TagMonthCount: Equatable, Sendable, Identifiable {
    public let month: String; public let tag: String; public let count: Int
    public var id: String { "\(month)|\(tag)" }
}
public struct ScorePoint: Equatable, Sendable {
    public let date: Date; public let dimension: String; public let score: Int; public let roundType: RoundType
}
public struct SessionSummary: Equatable, Sendable, Identifiable {
    public let id: Int64; public let roundType: RoundType; public let date: Date; public let overallScore: Double?
    /// nil for a debrief written before the verdict existed, or not yet coached.
    public let advancement: Advancement?
}
public struct CompanyPipeline: Equatable, Sendable, Identifiable {
    public var id: Int64 { company.id ?? 0 }
    public let company: Company; public let sessions: [SessionSummary]
    /// Process/next-steps notes across ALL of this company's sessions, newest round first.
    /// Kept as raw JSON because decoding needs `Highlight`, which lives in CoachingEngine —
    /// Store can't import it, and the views already decode highlightsJSON the same way.
    public let processNotesJSON: [(roundType: RoundType, date: Date, json: String)]

    public static func == (a: CompanyPipeline, b: CompanyPipeline) -> Bool {
        a.company == b.company && a.sessions == b.sessions
            && a.processNotesJSON.map(\.json) == b.processNotesJSON.map(\.json)
    }
}
public struct SessionDetail: Sendable {
    public let session: InterviewSession
    public let company: Company
    public let segments: [TranscriptSegmentRecord]
    public let feedback: FeedbackRecord?
    public let tags: [String]

    public init(session: InterviewSession, company: Company, segments: [TranscriptSegmentRecord],
                feedback: FeedbackRecord?, tags: [String]) {
        self.session = session
        self.company = company
        self.segments = segments
        self.feedback = feedback
        self.tags = tags
    }
}

public func formatTimestamp(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

extension AppDatabase {
    public func fetchOrCreateCompany(named name: String) throws -> Company {
        try dbWriter.write { db in
            if let existing = try Company.filter(Column("name") == name).fetchOne(db) { return existing }
            var c = Company(name: name)
            try c.insert(db)
            return c
        }
    }

    public func updateCompanyStatus(id: Int64, status: CompanyStatus) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE company SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    /// Re-point a session to a company with the given name (created if new). Renaming this way
    /// affects only this session — mutating company.name would rename every session sharing it,
    /// which is how all "Unknown" sessions used to change titles together.
    @discardableResult
    public func renameSession(id sessionId: Int64, companyNamed name: String) throws -> Company {
        try dbWriter.write { db in
            let company: Company
            if let existing = try Company.filter(Column("name") == name).fetchOne(db) {
                company = existing
            } else {
                var c = Company(name: name); try c.insert(db); company = c
            }
            try db.execute(sql: "UPDATE session SET companyId = ? WHERE id = ?",
                           arguments: [company.id, sessionId])
            return company
        }
    }

    public func updateSessionCriteria(id: Int64, _ text: String) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE session SET customInstructions = ? WHERE id = ?", arguments: [text, id])
        }
    }

    /// Re-labels a session's round type. Only the type changes here; callers re-coach
    /// afterwards so the debrief's scored dimensions match the new round's rubric.
    public func updateSessionRoundType(id: Int64, _ roundType: RoundType) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE session SET roundType = ? WHERE id = ?",
                           arguments: [roundType.rawValue, id])
        }
    }

    public func insertSession(_ s: InterviewSession) throws -> InterviewSession {
        try dbWriter.write { db in var s = s; try s.insert(db); return s }
    }

    /// Strips Whisper's non-speech markers and drops segments that were nothing else, so the
    /// transcript table holds speech only. Done here rather than at the call site because both
    /// the live-stop and crash-recovery paths funnel through it — see TranscriptArtifacts.
    ///
    /// Returns the number of rows actually written, which can be 0 even for a non-empty input
    /// (a recording whose every segment was `[BLANK_AUDIO]`). Callers must not assume the
    /// input count — a session with no transcript still gets coached, and the LLM will
    /// confabulate a debrief for an interview it cannot see.
    @discardableResult
    public func insertSegments(_ segs: [TranscriptSegmentRecord]) throws -> Int {
        let cleaned = segs.compactMap { seg -> TranscriptSegmentRecord? in
            let text = TranscriptArtifacts.clean(seg.text)
            guard !text.isEmpty else { return nil }
            var seg = seg
            seg.text = text
            return seg
        }
        try dbWriter.write { db in for var seg in cleaned { try seg.insert(db) } }
        return cleaned.count
    }

    public func deleteSession(id: Int64) throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [id])
        }
    }

    public func saveFeedback(_ f: FeedbackRecord, tags: [String]) throws {
        try dbWriter.write { db in
            var f = f
            try db.execute(sql: "DELETE FROM feedback WHERE sessionId = ?", arguments: [f.sessionId])
            try db.execute(sql: "DELETE FROM weaknessTag WHERE sessionId = ?", arguments: [f.sessionId])
            try f.insert(db)
            for tag in tags { var t = WeaknessTagRecord(sessionId: f.sessionId, tag: tag); try t.insert(db) }
            try db.execute(sql: "UPDATE session SET coachingStatus = 'complete' WHERE id = ?", arguments: [f.sessionId])
        }
    }

    public func markCoachingFailed(sessionId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE session SET coachingStatus = 'failed' WHERE id = ?", arguments: [sessionId])
        }
    }

    public func sessionsNeedingCoaching() throws -> [InterviewSession] {
        try dbWriter.read { db in
            try InterviewSession
                .filter(Column("coachingStatus") != "complete")
                .filter(sql: "id IN (SELECT DISTINCT sessionId FROM transcriptSegment)")
                .order(Column("date"))
                .fetchAll(db)
        }
    }

    /// Every session with a transcript, including ones already coached — the re-coach path.
    /// A rubric change only reaches existing debriefs by re-running them, since feedback is
    /// written once at finalize.
    public func sessionsWithTranscript() throws -> [InterviewSession] {
        try dbWriter.read { db in
            try InterviewSession
                .filter(sql: "id IN (SELECT DISTINCT sessionId FROM transcriptSegment)")
                .order(Column("date"))
                .fetchAll(db)
        }
    }

    public func recentWeaknessTags(limitSessions: Int) throws -> [(tag: String, count: Int)] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tag, COUNT(*) AS n FROM weaknessTag
                WHERE sessionId IN (SELECT id FROM session ORDER BY date DESC LIMIT ?)
                GROUP BY tag ORDER BY n DESC, tag
                """, arguments: [limitSessions])
            return rows.map { ($0["tag"], $0["n"]) }
        }
    }

    public func tagFrequencyByMonth() throws -> [TagMonthCount] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT strftime('%Y-%m', s.date) AS month, w.tag AS tag, COUNT(*) AS n
                FROM weaknessTag w JOIN session s ON s.id = w.sessionId
                GROUP BY month, tag ORDER BY month, n DESC
                """)
            return rows.map { TagMonthCount(month: $0["month"], tag: $0["tag"], count: $0["n"]) }
        }
    }

    public func scoresByDate(roundType: RoundType?) throws -> [ScorePoint] {
        try dbWriter.read { db in
            var sql = """
                SELECT s.date AS date, s.roundType AS roundType, f.scoresJSON AS scoresJSON
                FROM feedback f JOIN session s ON s.id = f.sessionId
                """
            var args: StatementArguments = []
            if let rt = roundType { sql += " WHERE s.roundType = ?"; args = [rt.rawValue] }
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            var points: [ScorePoint] = []
            for row in rows {
                let date: Date = row["date"]
                let rt = RoundType(rawValue: row["roundType"])
                let data = (row["scoresJSON"] as String).data(using: .utf8) ?? Data()
                let scores = (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
                for (dim, score) in scores {
                    points.append(ScorePoint(date: date, dimension: dim, score: score, roundType: rt))
                }
            }
            return points.sorted { $0.date < $1.date }
        }
    }

    public func pipeline() throws -> [CompanyPipeline] {
        try dbWriter.read { db in
            let companies = try Company.order(Column("name")).fetchAll(db)
            return try companies.map { co in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT s.id AS id, s.roundType AS roundType, s.date AS date,
                           f.overallScore AS overallScore, f.advancement AS advancement,
                           f.processNotesJSON AS processNotesJSON
                    FROM session s LEFT JOIN feedback f ON f.sessionId = s.id
                    WHERE s.companyId = ? ORDER BY s.date
                    """, arguments: [co.id])
                let sessions = rows.map { row in
                    SessionSummary(id: row["id"], roundType: RoundType(rawValue: row["roundType"]),
                                   date: row["date"], overallScore: row["overallScore"],
                                   advancement: (row["advancement"] as String?).flatMap(Advancement.init))
                }
                // Newest round first: the latest thing said about the process is the one that
                // still applies. "[]" and NULL (uncoached session) both mean nothing to show.
                let notes = rows.reversed().compactMap { row -> (RoundType, Date, String)? in
                    guard let json: String = row["processNotesJSON"], json != "[]", !json.isEmpty else { return nil }
                    return (RoundType(rawValue: row["roundType"]), row["date"], json)
                }
                return CompanyPipeline(company: co, sessions: sessions, processNotesJSON: notes)
            }
        }
    }

    public func allSessionSummaries() throws
        -> [(session: InterviewSession, companyName: String, overallScore: Double?, advancement: Advancement?)] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, c.name AS companyName, f.overallScore AS feedbackScore,
                       f.advancement AS advancement
                FROM session s
                JOIN company c ON c.id = s.companyId
                LEFT JOIN feedback f ON f.sessionId = s.id
                ORDER BY s.date DESC
                """)
            return try rows.map { (try InterviewSession(row: $0), $0["companyName"], $0["feedbackScore"],
                                   ($0["advancement"] as String?).flatMap(Advancement.init)) }
        }
    }

    public func sessionDetail(id: Int64) throws -> SessionDetail? {
        try dbWriter.read { db in
            guard let session = try InterviewSession.fetchOne(db, key: id),
                  let company = try Company.fetchOne(db, key: session.companyId) else { return nil }
            let segments = try TranscriptSegmentRecord
                .filter(Column("sessionId") == id).order(Column("tStart")).fetchAll(db)
            let feedback = try FeedbackRecord.filter(Column("sessionId") == id).fetchOne(db)
            let tags = try String.fetchAll(db, sql: "SELECT tag FROM weaknessTag WHERE sessionId = ?", arguments: [id])
            return SessionDetail(session: session, company: company, segments: segments, feedback: feedback, tags: tags)
        }
    }

    public func transcriptText(sessionId: Int64) throws -> String {
        guard let detail = try sessionDetail(id: sessionId) else { return "" }
        return detail.segments
            .map { "[\(formatTimestamp($0.tStart))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }
}
