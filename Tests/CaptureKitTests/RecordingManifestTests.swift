import XCTest
@testable import CaptureKit

final class RecordingManifestTests: XCTestCase {
    /// Manifests written before `sessionId` existed must still decode. A decode failure here
    /// is not a visible error: `readManifest` returns nil, `unfinalizedSessions` skips the
    /// directory, and every recording a previous version left behind silently stops being
    /// offered for recovery.
    func testDecodesLegacyManifestWithoutSessionId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"{"startedAt":770000000,"finalized":false}"#
        try legacy.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let m = try XCTUnwrap(RecordingStore.readManifest(in: dir))
        XCTAssertFalse(m.finalized)
        XCTAssertNil(m.sessionId)
        XCTAssertEqual(RecordingStore.unfinalizedSessions(root: dir.deletingLastPathComponent())
                        .filter { $0.lastPathComponent == dir.lastPathComponent }.count, 1)
    }

    func testSessionIdRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecordingStore.writeManifest(.init(startedAt: Date(), finalized: false, sessionId: 42), in: dir)
        XCTAssertEqual(RecordingStore.readManifest(in: dir)?.sessionId, 42)
    }
}
