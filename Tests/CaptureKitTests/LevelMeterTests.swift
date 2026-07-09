import XCTest
import AVFoundation
@testable import CaptureKit

final class LevelMeterTests: XCTestCase {
    func testSilenceIsZeroAndToneIsPositive() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let silent = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600)!
        silent.frameLength = 1600
        XCTAssertEqual(LevelMeter.rms(silent), 0, accuracy: 0.0001)

        let loud = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600)!
        loud.frameLength = 1600
        for i in 0..<1600 { loud.floatChannelData![0][i] = 0.5 }
        XCTAssertEqual(LevelMeter.rms(loud), 0.5, accuracy: 0.01)
    }

    func testInt16BuffersSupported() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 100)!
        buf.frameLength = 100
        for i in 0..<100 { buf.int16ChannelData![0][i] = Int16.max / 2 }
        XCTAssertEqual(LevelMeter.rms(buf), 0.5, accuracy: 0.01)
    }

    /// Interleaved stereo buffer: channel 0's underlying storage actually holds
    /// frameLength * channelCount interleaved samples (L,R,L,R,...), not just
    /// frameLength samples. A buggy implementation that only reads the first
    /// `frameLength` samples of channelData[0] would read only the first half
    /// of this data (all zeros here) and report 0.0. The fix must read all
    /// frameLength * channelCount samples, yielding an RMS of the half-0.6
    /// data: sqrt((frames * 0.6^2) / (2 * frames)) = 0.6 / sqrt(2) ≈ 0.424.
    func testInterleavedStereoBufferReadsAllChannelSamples() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: true)!
        let frames = 800
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<(frames * 2) {
            buf.floatChannelData![0][i] = i >= frames ? 0.6 : 0.0
        }
        XCTAssertEqual(LevelMeter.rms(buf), 0.424, accuracy: 0.01)
    }
}
