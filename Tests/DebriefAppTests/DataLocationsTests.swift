import XCTest
@testable import DebriefApp

final class DataLocationsTests: XCTestCase {
    private let fm = FileManager.default
    private func tmp() -> URL { fm.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // A scratch UserDefaults suite so reconcile tests never read or mutate the real app
    // defaults. Torn down in `tearDown` (removePersistentDomain) so nothing leaks between runs.
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DataLocationsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func kind(defaultDir: URL) -> DataLocations.Kind {
        DataLocations.Kind(desiredKey: "audioDirDesired", actualKey: "audioDirActual",
                           errorKey: "audioDirError", defaultDir: defaultDir)
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
        XCTAssertThrowsError(try DataLocations.migrateDirectory(from: from, to: to, fm: fm)) { error in
            guard case DataLocations.MigrationError.targetNotEmpty(let url) = error else {
                return XCTFail("expected .targetNotEmpty, got \(error)")
            }
            XCTAssertEqual(url, to)
        }
        // Source untouched...
        XCTAssertEqual(try String(contentsOf: from.appendingPathComponent("file.txt"), encoding: .utf8), "src")
        // ...and the target's original contents are preserved, not overwritten.
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("other.txt"), encoding: .utf8), "existing")
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

    // MARK: - reconcile state machine

    func testReconcileSuccessAdoptsDesiredAndClearsError() throws {
        let defaultDir = tmp()      // == actual (no actualKey stored)
        let desired = tmp()
        let k = kind(defaultDir: defaultDir)
        try write("payload", to: defaultDir.appendingPathComponent("data.txt")) // data lives at actual
        defaults.set(desired.path, forKey: k.desiredKey)
        defaults.set("stale error", forKey: k.errorKey) // should be cleared on success

        let used = DataLocations.reconcile(k, defaults: defaults, fm: fm)

        XCTAssertEqual(used, desired)
        XCTAssertFalse(fm.fileExists(atPath: defaultDir.path)) // data moved off the source
        XCTAssertEqual(try String(contentsOf: desired.appendingPathComponent("data.txt"), encoding: .utf8), "payload")
        XCTAssertEqual(defaults.string(forKey: k.actualKey), desired.path) // actual adopted desired
        XCTAssertNil(defaults.string(forKey: k.errorKey)) // error cleared
    }

    func testReconcileFailureKeepsActualPreservesDesiredAndRecordsError() throws {
        let defaultDir = tmp()      // == actual
        let desired = tmp()
        let k = kind(defaultDir: defaultDir)
        try write("payload", to: defaultDir.appendingPathComponent("data.txt")) // data at actual
        try write("occupied", to: desired.appendingPathComponent("existing.txt")) // desired NON-EMPTY → refuse
        defaults.set(desired.path, forKey: k.desiredKey)

        let used = DataLocations.reconcile(k, defaults: defaults, fm: fm)

        XCTAssertEqual(used, defaultDir) // fell back to actual
        // Source data untouched.
        XCTAssertEqual(try String(contentsOf: defaultDir.appendingPathComponent("data.txt"), encoding: .utf8), "payload")
        XCTAssertNil(defaults.string(forKey: k.actualKey)) // actual NOT advanced (still default/absent)
        XCTAssertEqual(defaults.string(forKey: k.desiredKey), desired.path) // desired preserved → retried next launch
        XCTAssertNotNil(defaults.string(forKey: k.errorKey)) // error recorded for Settings to show
    }
}
