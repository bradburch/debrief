import XCTest
import AVFoundation
@testable import CaptureKit

final class WavChunkWriterTests: XCTestCase {
    func makeBuffer(seconds: Double, value: Float = 0.25) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = value }
        return buf
    }

    func testChunksRollAtDuration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = try WavChunkWriter(directory: dir, prefix: "mic", chunkDuration: 1.0)
        try writer.append(makeBuffer(seconds: 0.6))
        XCTAssertEqual(writer.completedChunks.count, 0)
        try writer.append(makeBuffer(seconds: 0.6)) // crosses 1.0s -> rolls chunk 0
        XCTAssertEqual(writer.completedChunks.count, 1)
        try writer.append(makeBuffer(seconds: 0.3)) // opens chunk 1
        try writer.finish()                          // closes partial chunk 1
        XCTAssertEqual(writer.completedChunks.count, 2)
        XCTAssertEqual(writer.completedChunks[0].lastPathComponent, "mic-0000.wav")
        XCTAssertEqual(writer.completedChunks[1].lastPathComponent, "mic-0001.wav")
    }

    func testWrittenChunkIsReadable16kMono() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = try WavChunkWriter(directory: dir, prefix: "sys", chunkDuration: 10)
        try writer.append(makeBuffer(seconds: 0.5))
        try writer.finish()
        let file = try AVAudioFile(forReading: writer.completedChunks[0])
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length), 0.5 * 16_000, accuracy: 16) // within 1ms
    }

    /// Production case: 48 kHz mic input resampled down to 16 kHz through a real
    /// AVAudioConverter (not the passthrough path). The output buffer in
    /// `convertTo16kMono` is sized `frameLength * ratio + 64`; a real resampler's
    /// filter latency/tail can exceed that margin, and `appendSamples` silently
    /// drops overflowing frames. This test pins that no audio is lost and that
    /// the signal (not just silence) survives the round trip.
    func testRealResample48kTo16kDropsNoAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = try WavChunkWriter(directory: dir, prefix: "mic48", chunkDuration: 60)

        let sourceRate = 48_000.0
        let seconds = 2.0
        let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sourceRate)
        let buf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frames)!
        buf.frameLength = frames
        // Constant non-zero value so any surviving sample proves non-silence.
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.25 }

        try writer.append(buf)
        try writer.finish()

        XCTAssertEqual(writer.completedChunks.count, 1)
        let file = try AVAudioFile(forReading: writer.completedChunks[0])
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)

        let expectedFrames = seconds * 16_000
        XCTAssertEqual(Double(file.length), expectedFrames, accuracy: 64,
                        "resampled chunk lost audio frames: got \(file.length), expected ~\(expectedFrames)")

        let intFile = try AVAudioFile(forReading: writer.completedChunks[0],
                                       commonFormat: .pcmFormatInt16, interleaved: true)
        let readBuf = AVAudioPCMBuffer(pcmFormat: intFile.processingFormat, frameCapacity: AVAudioFrameCount(intFile.length))!
        try intFile.read(into: readBuf)
        XCTAssertGreaterThan(readBuf.frameLength, 0)
        var sawNonZero = false
        if let data = readBuf.int16ChannelData?[0] {
            for i in 0..<Int(readBuf.frameLength) where data[i] != 0 {
                sawNonZero = true
                break
            }
        }
        XCTAssertTrue(sawNonZero, "resampled chunk is entirely silent — signal was lost")
    }
}
