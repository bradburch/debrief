import XCTest
@testable import DebriefApp

final class DataLocationsTests: XCTestCase {
    private let fm = FileManager.default
    private func tmp() -> URL { fm.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testMovesPopulatedDirectory() throws {
        let from = tmp(), to = tmp()
        try write("data", to: from.appendingPathComponent("file.txt"))
        try DataLocations.migrateDirectory(from: from, to: to, fm: fm)
        XCTAssertFalse(fm.fileExists(atPath: from.path))
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("file.txt"), encoding: .utf8), "data")
    }

    func testRefusesNonEmptyTargetAndLeavesSourceIntact() throws {
        let from = tmp(), to = tmp()
        try write("src", to: from.appendingPathComponent("file.txt"))
        try write("existing", to: to.appendingPathComponent("other.txt"))
        XCTAssertThrowsError(try DataLocations.migrateDirectory(from: from, to: to, fm: fm))
        XCTAssertEqual(try String(contentsOf: from.appendingPathComponent("file.txt"), encoding: .utf8), "src")
    }

    func testNoopWhenSourceMissing() throws {
        let from = tmp(), to = tmp()
        try DataLocations.migrateDirectory(from: from, to: to, fm: fm) // must not throw
        XCTAssertFalse(fm.fileExists(atPath: to.path))
    }

    func testNoopWhenEqual() throws {
        let dir = tmp()
        try write("x", to: dir.appendingPathComponent("file.txt"))
        try DataLocations.migrateDirectory(from: dir, to: dir, fm: fm)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("file.txt"), encoding: .utf8), "x")
    }

    func testMovesIntoEmptyExistingTarget() throws {
        let from = tmp(), to = tmp()
        try write("src", to: from.appendingPathComponent("file.txt"))
        try fm.createDirectory(at: to, withIntermediateDirectories: true) // empty dir the user pre-made
        try DataLocations.migrateDirectory(from: from, to: to, fm: fm)
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("file.txt"), encoding: .utf8), "src")
    }
}
