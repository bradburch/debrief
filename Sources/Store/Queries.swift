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
    public let durationSeconds: Int
    public let coachingStatus: CoachingStatus
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
/// Everything the Pipeline's per-company overview shows, in one read.
public struct CompanyOverview: Sendable {
    public let company: Company
    /// Oldest first — the order the rounds happened in.
    public let sessions: [SessionSummary]
    /// Same shape and order as `CompanyPipeline.processNotesJSON`: newest round first.
    public let processNotesJSON: [(roundType: RoundType, date: Date, json: String)]
    /// Each coached round's action items as raw `[String]` JSON, newest round first. Raw for
    /// symmetry with the process notes; empty and "[]" rows are already dropped.
    public let actionItemsJSON: [(roundType: RoundType, date: Date, json: String)]
    /// Weakness tags across this company's rounds, most frequent first — "recurring" is
    /// the caller's call (count > 1), since one round is the common case.
    public let weaknessTags: [(tag: String, count: Int)]
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

    public func findCompany(named name: String) throws -> Company? {
        try dbWriter.read { db in
            try Company.filter(Column("name") == name).fetchOne(db)
        }
    }

    /// Deletes a company only if no session references it. Used by the no-speech
    /// compensation path: `fetchOrCreateCompany` runs before segments are inserted, so a
    /// finalize that fails and deletes its session row would otherwise leave a stray
    /// zero-session company behind in Pipeline.
    public func deleteCompanyIfUnused(id: Int64) throws {
        try dbWriter.write { db in
            let inUse = try Int.fetchOne(
                db, sql: "SELECT 1 FROM session WHERE companyId = ? LIMIT 1", arguments: [id])
            if inUse == nil {
                try db.execute(sql: "DELETE FROM company WHERE id = ?", arguments: [id])
            }
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
            // The old company row is kept even if now empty: deleting it would lose its
            // status. Pipeline hides zero-session companies and suggestions skip them.
            return company
        }
    }

    /// Re-spells a company in place — every session and its status come along. Used for a
    /// case-only fix ("acme" → "Acme"), which `renameSession` would instead split in two.
    public func renameCompany(id: Int64, to name: String) throws -> Company {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE company SET name = ? WHERE id = ?", arguments: [name, id])
            return try Company.fetchOne(db, key: id)!
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

    /// Used by crash recovery to decide whether a leftover directory has already been turned
    /// into a session. Asks about the transcript, not the row: a crash between the session
    /// insert and the segment insert leaves a row with nothing in it, and that row must not
    /// suppress recovery — it is excluded from the coaching sweeps too (they require a
    /// transcript), so the interview would otherwise be unreachable by every path at once.
    public func sessionHasTranscript(id: Int64) throws -> Bool {
        try dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM transcriptSegment WHERE sessionId = ? LIMIT 1",
                              arguments: [id]) ?? false
        }
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

    /// Writes a status directly. Used to claim `running` immediately before an LLM call goes
    /// out — so a concurrent sweep can see the session is already being coached — and to put
    /// the previous status back when that call is *cancelled* rather than failed.
    public func setCoachingStatus(sessionId: Int64, _ status: CoachingStatus) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE session SET coachingStatus = ? WHERE id = ?",
                           arguments: [status.rawValue, sessionId])
        }
    }

    /// **Claims a session for coaching, atomically.** Returns the status it held *before* the
    /// claim, or nil if it was already `running` — someone else owns the LLM call, and the
    /// caller must not make one.
    ///
    /// Read and write happen in a single write transaction because `CoachingService` is a
    /// nonisolated struct: a finalize job and a Retry/Re-run sweep coach from different
    /// threads, so a plain "read the status, then write `running`" leaves a window in which
    /// both read `pending`, both write `running`, and both bill a call and race to write the
    /// same feedback row. Nothing about being on the main actor protects this — the coaching
    /// path never touches it.
    ///
    /// The returned prior status is also the only trustworthy one to restore on cancellation:
    /// a status fetched before the transaction can be stale by the time the claim lands.
    public func claimCoaching(sessionId: Int64) throws -> CoachingStatus? {
        try dbWriter.write { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT coachingStatus FROM session WHERE id = ?",
                                                arguments: [sessionId]) else { return nil }
            // An unrecognised value is treated as `pending` rather than refused: the column
            // has no CHECK constraint, and refusing would strand the session in every sweep.
            let previous = CoachingStatus(rawValue: raw) ?? .pending
            guard previous != .running else { return nil }
            try db.execute(sql: "UPDATE session SET coachingStatus = 'running' WHERE id = ?",
                           arguments: [sessionId])
            return previous
        }
    }

    /// Launch-time reclaim: a `running` row can only be left behind by a process that died
    /// mid-coach, since nothing survives the crash to finish it. Returns it to the retry
    /// sweeps rather than stranding it in a state they all skip.
    @discardableResult
    public func resetRunningCoaching() throws -> Int {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE session SET coachingStatus = 'pending' WHERE coachingStatus = 'running'")
            return db.changesCount
        }
    }

    /// Terminal, unlike `failed`: the round type is transcript-only, so there is nothing
    /// to retry. Both coaching sweeps below exclude it for that reason.
    public func markCoachingSkipped(sessionId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE session SET coachingStatus = 'skipped' WHERE id = ?", arguments: [sessionId])
        }
    }

    /// Excludes `running` as well as the two terminal states: a debrief already in flight
    /// (from a finalize job) would otherwise be started a second time by a Retry sweep.
    public func sessionsNeedingCoaching() throws -> [InterviewSession] {
        try dbWriter.read { db in
            try InterviewSession
                .filter(Column("coachingStatus") != "complete")
                .filter(Column("coachingStatus") != "skipped")
                .filter(Column("coachingStatus") != "running")
                .filter(sql: "id IN (SELECT DISTINCT sessionId FROM transcriptSegment)")
                .order(Column("date"))
                .fetchAll(db)
        }
    }

    /// How many stored sessions use a round type. Deleting a type whose prompt file is
    /// gone would leave those sessions pointing at a round type that can no longer be
    /// assembled, so the Settings UI blocks the delete instead.
    public func sessionCount(forRoundType type: RoundType) throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session WHERE roundType = ?",
                             arguments: [type.rawValue]) ?? 0
        }
    }

    /// Every session with a transcript, including ones already coached — the re-coach path.
    /// A rubric change only reaches existing debriefs by re-running them, since feedback is
    /// written once at finalize.
    ///
    /// Deliberately includes `skipped` (transcript-only) sessions. This query means exactly
    /// "has a transcript", and `exportAll` uses it as well as the re-coach sweep — a mock
    /// interview's transcript is the entire artifact it produces, so excluding it here to
    /// stop re-coaching would silently drop practice sessions from Cowork export too.
    /// `recoachAll` filters `skipped` itself instead.
    public func sessionsWithTranscript() throws -> [InterviewSession] {
        try dbWriter.read { db in
            try InterviewSession
                .filter(sql: "id IN (SELECT DISTINCT sessionId FROM transcriptSegment)")
                .order(Column("date"))
                .fetchAll(db)
        }
    }

    // MARK: - Planned calls
    //
    // A closed little table with no joins to anything: planned calls are deliberately
    // invisible to `allSessionSummaries`, `pipeline`, `scoresByDate` and the coaching
    // sweeps, because they are not sessions and must never be counted as one.

    /// Soonest first — the order every surface offers them in — and bounded, because a plan
    /// is consumed only by a *successful* finalize: one you never recorded stays forever, and
    /// ascending order puts the oldest of them at the TOP of both the sidebar list and the
    /// pre-fill menu.
    ///
    /// A **filter, not a purge**: the row stays in the table. The 24h grace is what keeps an
    /// interview that ran late — or one whose finalize failed overnight — on the recovery
    /// prompt the next morning, which is the case the plan matters most for.
    public func plannedCalls(now: Date = Date()) throws -> [PlannedCall] {
        try dbWriter.read { db in
            try PlannedCall
                .filter(Column("scheduledDate") > now.addingTimeInterval(-24 * 3600))
                .order(Column("scheduledDate"))
                .limit(20)
                .fetchAll(db)
        }
    }

    /// Deletes plans scheduled more than `days` days ago. Called once per launch.
    ///
    /// The counterpart to `plannedCalls` being a *filter*: a plan is consumed only by a
    /// finalize that produced a session, so a call you planned and never recorded stays in the
    /// table forever — and 24h later it has dropped out of every list, which means the delete
    /// button that would have removed it is gone too. Invisible and undeletable is the worst
    /// of both, so the row eventually goes on its own.
    ///
    /// 30 days rather than something tighter because the row costs nothing and the only harm a
    /// stale plan does is invisible; an interview that slips a fortnight, or a laptop closed
    /// for a week, must still find its plan on the recovery prompt when it comes back.
    @discardableResult
    public func purgeStalePlannedCalls(olderThan days: Int = 30, now: Date = Date()) throws -> Int {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM plannedCall WHERE scheduledDate < ?",
                           arguments: [now.addingTimeInterval(-Double(days) * 24 * 3600)])
            return db.changesCount
        }
    }

    @discardableResult
    public func insertPlannedCall(_ plan: PlannedCall) throws -> PlannedCall {
        try dbWriter.write { db in var p = plan; try p.insert(db); return p }
    }

    /// Raw UPDATE rather than `record.update(db)`, which throws `recordNotFound`: editing a
    /// plan the user recorded (and finalize therefore consumed) from a still-open sheet is a
    /// no-op, not an error to surface.
    ///
    /// Returns whether a row was actually updated — **false is not nothing happened, it is
    /// the row is gone**. The caller owns what to do about the typing that would otherwise be
    /// silently dropped (`AppEnvironment.savePlannedCall` re-inserts it as a new plan).
    @discardableResult
    public func updatePlannedCall(_ plan: PlannedCall) throws -> Bool {
        guard let id = plan.id else { return false }
        return try dbWriter.write { db in
            try db.execute(sql: """
                UPDATE plannedCall SET companyName = ?, role = ?, roundType = ?,
                                       scheduledDate = ?, notes = ?, customInstructions = ?
                WHERE id = ?
                """,
                arguments: [plan.companyName, plan.role, plan.roundType.rawValue,
                            plan.scheduledDate, plan.notes, plan.customInstructions, id])
            return db.changesCount > 0
        }
    }

    public func deletePlannedCall(id: Int64) throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM plannedCall WHERE id = ?", arguments: [id])
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

    /// One company's rounds joined to their feedback, oldest first. Shared by `pipeline` and
    /// `companyOverview` so the two can't disagree about what a round is.
    private static func companySessionRows(_ db: Database, companyId: Int64?) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            SELECT s.id AS id, s.roundType AS roundType, s.date AS date,
                   s.durationSeconds AS durationSeconds, s.coachingStatus AS coachingStatus,
                   f.overallScore AS overallScore, f.advancement AS advancement,
                   f.processNotesJSON AS processNotesJSON, f.actionItemsJSON AS actionItemsJSON
            FROM session s LEFT JOIN feedback f ON f.sessionId = s.id
            WHERE s.companyId = ? ORDER BY s.date
            """, arguments: [companyId])
    }

    private static func summary(_ row: Row) -> SessionSummary {
        SessionSummary(id: row["id"], roundType: RoundType(rawValue: row["roundType"]),
                       date: row["date"], overallScore: row["overallScore"],
                       advancement: (row["advancement"] as String?).flatMap(Advancement.init),
                       durationSeconds: row["durationSeconds"],
                       coachingStatus: CoachingStatus(rawValue: row["coachingStatus"]) ?? .pending)
    }

    /// Newest round first: the latest thing said is the one that still applies. "[]" and NULL
    /// (uncoached session) both mean nothing to show.
    private static func jsonListsNewestFirst(_ rows: [Row], column: String)
        -> [(roundType: RoundType, date: Date, json: String)] {
        rows.reversed().compactMap { row in
            guard let json: String = row[column], json != "[]", !json.isEmpty else { return nil }
            return (RoundType(rawValue: row["roundType"]), row["date"], json)
        }
    }

    /// SQL twin of `Company.isPlaceholder`, for queries that filter in the database.
    private static let isRealCompanySQL = "trim(name) != '' AND lower(trim(name)) != lower('\(Company.placeholderName)')"

    /// Companies you are interviewing with. **Excludes the "Unknown" placeholder** that
    /// finalize files a blank-company session under: it is a real row, but a bucket of
    /// unrelated interviews is not a pipeline. Those sessions are counted by
    /// `unassignedSessionCount` instead and stay visible in Sessions.
    ///
    /// Callers: PipelineView only (plus tests). Trends and the Sessions list do not group by
    /// company, so the exclusion reaches nothing else.
    public func pipeline() throws -> [CompanyPipeline] {
        try dbWriter.read { db in
            let companies = try Company.filter(sql: Self.isRealCompanySQL).order(Column("name")).fetchAll(db)
            return try companies.map { co in
                let rows = try Self.companySessionRows(db, companyId: co.id)
                return CompanyPipeline(company: co, sessions: rows.map(Self.summary),
                                       processNotesJSON: Self.jsonListsNewestFirst(rows, column: "processNotesJSON"))
            }
            // Live pipelines lead, dead ones sink; within a status the most recently
            // interviewed company comes first. Stable over the name order above for ties.
            .sorted { a, b in
                let ra = Self.pipelineRank(a.company.status), rb = Self.pipelineRank(b.company.status)
                if ra != rb { return ra < rb }
                return (a.sessions.last?.date ?? .distantPast) > (b.sessions.last?.date ?? .distantPast)
            }
        }
    }

    /// Sessions filed under the no-company placeholder — the ones Pipeline leaves out.
    public func unassignedSessionCount() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM session
                WHERE companyId NOT IN (SELECT id FROM company WHERE \(Self.isRealCompanySQL))
                """) ?? 0
        }
    }

    /// Company names to offer while typing one: every real company with at least one
    /// session, live pipelines first (then offers, then dead), most recently interviewed
    /// first within a status. Never the placeholder — suggesting "Unknown" would file a
    /// session under the no-company bucket on purpose.
    public func companySuggestions() throws -> [String] {
        try dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.name FROM company c JOIN session s ON s.companyId = c.id
                WHERE trim(c.name) != '' AND lower(trim(c.name)) != lower(?)
                GROUP BY c.id
                ORDER BY CASE c.status WHEN 'active' THEN 0 WHEN 'offer' THEN 1 ELSE 2 END,
                         MAX(s.date) DESC, c.name
                """, arguments: [Company.placeholderName])
        }
    }

    /// The Pipeline drill-in: one company's rounds, notes, action items and weakness tags.
    /// nil if the company is gone.
    public func companyOverview(id: Int64) throws -> CompanyOverview? {
        try dbWriter.read { db in
            guard let company = try Company.fetchOne(db, key: id) else { return nil }
            let rows = try Self.companySessionRows(db, companyId: id)
            let tags = try Row.fetchAll(db, sql: """
                SELECT w.tag AS tag, COUNT(*) AS n FROM weaknessTag w
                JOIN session s ON s.id = w.sessionId
                WHERE s.companyId = ?
                GROUP BY w.tag ORDER BY n DESC, w.tag
                """, arguments: [id]).map { (tag: $0["tag"] as String, count: $0["n"] as Int) }
            return CompanyOverview(company: company, sessions: rows.map(Self.summary),
                                   processNotesJSON: Self.jsonListsNewestFirst(rows, column: "processNotesJSON"),
                                   actionItemsJSON: Self.jsonListsNewestFirst(rows, column: "actionItemsJSON"),
                                   weaknessTags: tags)
        }
    }

    private static func pipelineRank(_ s: CompanyStatus) -> Int {
        switch s {
        case .active: return 0
        case .offer: return 1
        case .dead: return 2
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
