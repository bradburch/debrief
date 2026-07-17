import XCTest
import Store
@testable import CoachingEngine

final class CoachingExportTests: XCTestCase {
    private func makeService(_ db: AppDatabase) -> CoachingService {
        // llm is unused by export; any client is fine.
        CoachingService(db: db, prompts: PromptStore(directory: URL(fileURLWithPath: "/tmp/none")),
                        llm: AnthropicClient(apiKey: "", model: "x"))
    }

    private func seedSession(_ db: AppDatabase, company: String) throws -> Int64 {
        let c = try db.fetchOrCreateCompany(named: company)
        let s = try db.insertSession(InterviewSession(
            id: nil, companyId: c.id!, roundType: .behavioral, date: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, contextNotes: "", coachingStatus: .complete))
        _ = try db.insertSegments([
            TranscriptSegmentRecord(id: nil, sessionId: s.id!, speaker: .you, tStart: 0, text: "Hello there.")
        ])
        return s.id!
    }

    func testExportSessionWritesFile() throws {
        let db = try AppDatabase.inMemory()
        let id = try seedSession(db, company: "Acme")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeService(db).exportSession(id: id, to: dir)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(contents.contains("# Acme — Behavioral"))
        XCTAssertTrue(contents.contains("Hello there."))
    }

    func testExportAllWritesOnePerSession() throws {
        let db = try AppDatabase.inMemory()
        _ = try seedSession(db, company: "Acme")
        _ = try seedSession(db, company: "Globex")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let errors = makeService(db).exportAll(to: dir)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }
}
