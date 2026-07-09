import XCTest
import AVFoundation
@testable import Transcriber

/// Slow: downloads a Whisper model on first run and synthesizes a fixture with `say`.
/// Run explicitly: swift test --filter WhisperIntegrationTests
/// Skipped unless DEBRIEF_RUN_INTEGRATION=1.
final class WhisperIntegrationTests: XCTestCase {
    func testTranscribesSynthesizedSpeech() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEBRIEF_RUN_INTEGRATION"] == "1")

        // Synthesize "hello world this is a test" to a 16k wav via say + afconvert.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appendingPathComponent("fixture.aiff")
        let wav = dir.appendingPathComponent("fixture.wav")
        try run("/usr/bin/say", ["-o", aiff.path, "hello world this is a test"])
        try run("/usr/bin/afconvert", [aiff.path, wav.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"])

        let transcriber = WhisperTranscriber(model: .accurate)
        let segments = try await transcriber.transcribe(wavURL: wav)
        let joined = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("hello"), "got: \(joined)")
        XCTAssertTrue(joined.contains("test"), "got: \(joined)")
    }

    private func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(path) failed")
    }
}
