import Foundation
import AVFoundation

/// A single audio source (microphone or system audio) that can be started
/// and stopped, and that reports a running RMS level via `onLevel`.
public protocol StreamRecorder: AnyObject, Sendable {
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    func start() async throws
    func stop() async throws
}

/// Pure RMS level metering — no I/O, fully unit-testable.
public enum LevelMeter {
    /// 0.0–1.0-ish RMS of the first channel of `buffer`. Supports Float32
    /// (values already in -1...1) and Int16 (normalized by Int16.max)
    /// sample formats. Returns 0 for an empty buffer or an unsupported format.
    public static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        // For an interleaved buffer, channelData[0] holds all channels'
        // samples interleaved (L,R,L,R,...) — frameLength * channelCount
        // samples in total, not just frameLength. For a non-interleaved
        // buffer, channelData[0] holds only that one channel's frameLength
        // samples. Computing RMS over the interleaved mix is correct for a
        // level meter (it reflects overall loudness across channels).
        let n = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        guard n > 0 else { return 0 }
        if let floats = buffer.floatChannelData {
            var sum: Float = 0
            for i in 0..<n {
                let v = floats[0][i]
                sum += v * v
            }
            return (sum / Float(n)).squareRoot()
        }
        if let ints = buffer.int16ChannelData {
            var sum: Float = 0
            for i in 0..<n {
                let v = Float(ints[0][i]) / Float(Int16.max)
                sum += v * v
            }
            return (sum / Float(n)).squareRoot()
        }
        return 0
    }
}
