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
}
public struct CompanyPipeline: Equatable, Sendable, Identifiable {
    public var id: Int64 { company.id ?? 0 }
    public let company: Company; public let sessions: [SessionSummary]
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

    public func insertSession(_ s: InterviewSession) throws -> InterviewSession {
        try dbWriter.write { db in var s = s; try s.insert(db); return s }
    }

    public func insertSegments(_ segs: [TranscriptSegmentRecord]) throws {
        try dbWriter.write { db in for var seg in segs { try seg.insert(db) } }
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
                guard let rt = RoundType(rawValue: row["roundType"]) else { continue }
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
                    SELECT s.id AS id, s.roundType AS roundType, s.date AS date, f.overallScore AS overallScore
                    FROM session s LEFT JOIN feedback f ON f.sessionId = s.id
                    WHERE s.companyId = ? ORDER BY s.date
                    """, arguments: [co.id])
                let sessions = rows.compactMap { row -> SessionSummary? in
                    guard let rt = RoundType(rawValue: row["roundType"]) else { return nil }
                    return SessionSummary(id: row["id"], roundType: rt, date: row["date"], overallScore: row["overallScore"])
                }
                return CompanyPipeline(company: co, sessions: sessions)
            }
        }
    }

    public func allSessionSummaries() throws -> [(session: InterviewSession, companyName: String, overallScore: Double?)] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, c.name AS companyName, f.overallScore AS feedbackScore
                FROM session s
                JOIN company c ON c.id = s.companyId
                LEFT JOIN feedback f ON f.sessionId = s.id
                ORDER BY s.date DESC
                """)
            return try rows.map { (try InterviewSession(row: $0), $0["companyName"], $0["feedbackScore"]) }
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
