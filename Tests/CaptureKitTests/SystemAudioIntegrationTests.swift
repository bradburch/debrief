import XCTest
import AVFoundation
@testable import CaptureKit

/// Real system-audio capture through the CoreAudio tap: plays audio with `say` and
/// checks it lands on disk. This is the only check that the tap, the writer, and the
/// silence padding work together against a real audio device — the unit tests all
/// operate on synthetic buffers, and the bug this replaced (ScreenCaptureKit writing
/// full-rate digital silence for Continuity calls) passed every mocked test.
///
/// Run explicitly: DEBRIEF_RUN_INTEGRATION=1 swift test --filter SystemAudioIntegrationTests
/// Skipped unless DEBRIEF_RUN_INTEGRATION=1. Needs a working output device and audible
/// volume — muted output legitimately captures silence and fails this test.
///
/// Continuity/cellular calls specifically cannot be automated (they need a real inbound
/// phone call); that stays manual checklist #16.
final class SystemAudioIntegrationTests: XCTestCase {
    /// Thread-safe max of the levels handed to the UI's "Them" bar. `onLevel` fires on
    /// the recorder's private queue, so this can't be a plain captured var.
    private final class LevelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Float = 0
        func record(_ level: Float) {
            lock.lock(); defer { lock.unlock() }
            value = Swift.max(value, level)
        }
        var highest: Float { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testCapturesRealOutputAudioAndKeepsWallClockDuration() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEBRIEF_RUN_INTEGRATION"] == "1")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = try WavChunkWriter(directory: dir, prefix: "sys", chunkDuration: 600)
        let recorder = SystemAudioRecorder(writer: writer)
        let levels = LevelBox()
        recorder.onLevel = { levels.record($0) }

        let started = Date()
        try await recorder.start()
        // Deliberate leading silence: the tap delivers nothing at all while output is
        // idle, so this is exactly the gap `padSilenceToNow` has to reconstruct. Without
        // it the system track would be shorter than the mic track and every "them"
        // segment would land early.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try Self.run("/usr/bin/say",
                     ["-v", "Samantha", "one two three four five six seven eight nine ten"])
        let elapsed = Date().timeIntervalSince(started)
        try await recorder.stop()

        // 1. Audio actually reached disk — the property that was false under SCK.
        let (seconds, rms) = try Self.measure(writer.completedChunks)
        XCTAssertGreaterThan(rms, 0.0001, "system audio captured as silence — the tap heard nothing")

        // 2. The track spans the whole recording, leading silence included.
        XCTAssertEqual(seconds, elapsed, accuracy: 1.0,
                       "system track (\(seconds)s) drifted from wall clock (\(elapsed)s)")

        // 3. The level the "Them" bar reads is nonzero, so capture working can't present
        //    as a dead UI (one of the three outcomes checklist #16 had to distinguish).
        XCTAssertGreaterThan(levels.highest, 0.0001, "onLevel never reported signal")
    }

    /// Total duration and overall RMS of 16 kHz mono Int16 chunks.
    private static func measure(_ urls: [URL]) throws -> (seconds: Double, rms: Double) {
        var frames: AVAudioFramePosition = 0
        var sumSquares = 0.0
        var samples = 0
        for url in urls {
            let file = try AVAudioFile(forReading: url)
            frames += file.length
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length))
            else { continue }
            try file.read(into: buffer)
            // `processingFormat` for a 16-bit WAV is float32, not Int16 — reading
            // int16ChannelData alone silently measures nothing and reports RMS 0.
            if let data = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) {
                    let v = Double(data[i])
                    sumSquares += v * v
                }
                samples += Int(buffer.frameLength)
            } else if let data = buffer.int16ChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) {
                    let v = Double(data[i]) / 32768.0
                    sumSquares += v * v
                }
                samples += Int(buffer.frameLength)
            } else {
                XCTFail("could not read samples from \(url.lastPathComponent)")
            }
        }
        return (Double(frames) / 16_000, samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0)
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
    }
}
