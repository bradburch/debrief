import XCTest
@testable import CaptureKit

final class RecordingStoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func testManifestRoundTripAndRecoveryScan() throws {
        let dir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.writeManifest(.init(startedAt: Date(), finalized: false), in: dir)
        XCTAssertEqual(RecordingStore.unfinalizedSessions(root: root), [dir])
        try RecordingStore.writeManifest(.init(startedAt: Date(), finalized: true), in: dir)
        XCTAssertTrue(RecordingStore.unfinalizedSessions(root: root).isEmpty)
    }

    func testChunkURLsAreSortedByIndex() throws {
        let dir = try RecordingStore.createSessionDirectory(root: root)
        for name in ["mic-0002.wav", "mic-0000.wav", "mic-0001.wav", "sys-0000.wav"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        let mics = RecordingStore.chunkURLs(in: dir, prefix: "mic")
        XCTAssertEqual(mics.map(\.lastPathComponent), ["mic-0000.wav", "mic-0001.wav", "mic-0002.wav"])
    }

    func testDeleteSessionRemovesDirectory() throws {
        let dir = try RecordingStore.createSessionDirectory(root: root)
        try RecordingStore.deleteSession(at: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
