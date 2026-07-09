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
        return m
    }
}
