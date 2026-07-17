import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return try AppDatabase(DatabaseQueue(path: url.path))
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "company") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("status", .text).notNull().defaults(to: "active")
            }
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("company", onDelete: .cascade).notNull()
                t.column("roundType", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("durationSeconds", .integer).notNull()
                t.column("contextNotes", .text).notNull().defaults(to: "")
                t.column("coachingStatus", .text).notNull().defaults(to: "pending")
            }
            try db.create(table: "transcriptSegment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade).notNull()
                t.column("speaker", .text).notNull()
                t.column("tStart", .double).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(table: "feedback") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade).notNull().unique()
                t.column("proseDebrief", .text).notNull()
                t.column("scoresJSON", .text).notNull()
                t.column("highlightsJSON", .text).notNull()
                t.column("actionItemsJSON", .text).notNull()
                t.column("overallScore", .double).notNull()
            }
            try db.create(table: "weaknessTag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade).notNull()
                t.column("tag", .text).notNull()
            }
            try db.create(indexOn: "weaknessTag", columns: ["tag"])
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "session") { t in
                t.add(column: "customInstructions", .text).notNull().defaults(to: "")
            }
        }
        // The advance/no-advance verdict, elicited from the LLM rather than derived from
        // overallScore. Empty string = feedback written before v3; the UI reads that as
        // "no verdict" and Settings → "Re-run debriefs on current rubric" backfills it.
        m.registerMigration("v3") { db in
            try db.alter(table: "feedback") { t in
                t.add(column: "advancement", .text).notNull().defaults(to: "")
                t.add(column: "advancementRationale", .text).notNull().defaults(to: "")
            }
        }
        // What the interviewer said about process/next steps/timeline, as [{t,note}] JSON.
        // Defaults to "[]" (not "") so every row decodes as a valid empty list — pre-v4 rows
        // are then indistinguishable in shape from "the topic never came up", which is what
        // they are until re-coached.
        m.registerMigration("v4") { db in
            try db.alter(table: "feedback") { t in
                t.add(column: "processNotesJSON", .text).notNull().defaults(to: "[]")
            }
        }
        // Retroactively apply the insertSegments cleaning to rows written before it existed.
        // Runs the same TranscriptArtifacts rules rather than SQL LIKEs, so the stored
        // transcript and future writes can't drift apart. Safe to lose a segment here: the
        // WAV chunks remain the source of truth, and these carry no speech by definition.
        m.registerMigration("v5") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM transcriptSegment")
            for row in rows {
                let id: Int64 = row["id"]
                let original: String = row["text"]
                let cleaned = TranscriptArtifacts.clean(original)
                if cleaned.isEmpty {
                    try db.execute(sql: "DELETE FROM transcriptSegment WHERE id = ?", arguments: [id])
                } else if cleaned != original {
                    try db.execute(sql: "UPDATE transcriptSegment SET text = ? WHERE id = ?",
                                   arguments: [cleaned, id])
                }
            }
        }
        return m
    }
}
