import XCTest
import AVFoundation
@testable import CaptureKit

/// `makeBuffer` is the only non-trivial logic in the tap path that can run without a
/// real audio device: it copies CoreAudio's transient IOProc buffers into owned
/// AVAudioPCMBuffers. Everything else in SystemAudioRecorder is device setup, covered
/// by manual checklist #16.
final class SystemAudioTapBufferTests: XCTestCase {
    /// The tap's real format, as observed on macOS 26: 48 kHz stereo float32, interleaved.
    private let tapFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

    /// Builds an AudioBufferList over `samples` and hands it to makeBuffer the way an
    /// IOProc would, so the copy is exercised against memory we control.
    private func copyThroughMakeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        var storage = samples
        return storage.withUnsafeMutableBufferPointer { raw -> AVAudioPCMBuffer? in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: format.channelCount,
                    mDataByteSize: UInt32(raw.count * MemoryLayout<Float>.size),
                    mData: raw.baseAddress))
            return withUnsafePointer(to: &list) {
                SystemAudioRecorder.makeBuffer(from: $0, format: format)
            }
        }
    }

    func testCopiesInterleavedStereoFramesAndValues() {
        // 4 stereo frames: left ramps up, right ramps down.
        let samples: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        let buffer = copyThroughMakeBuffer(samples, format: tapFormat)
        let copied = try! XCTUnwrap(buffer)

        // 8 floats / 2 channels = 4 frames. A stride bug here would report 8.
        XCTAssertEqual(copied.frameLength, 4)
        let data = try! XCTUnwrap(copied.floatChannelData)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: data[0], count: samples.count)), samples)
    }

    /// The copy must not alias CoreAudio's memory — the IOProc's buffers are only valid
    /// for the duration of the callback, so an aliasing bug would read freed audio.
    func testCopyIsIndependentOfSourceMemory() {
        var storage: [Float] = [0.5, 0.5, 0.5, 0.5]
        let copied: AVAudioPCMBuffer? = storage.withUnsafeMutableBufferPointer { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(raw.count * MemoryLayout<Float>.size),
                    mData: raw.baseAddress))
            let out = withUnsafePointer(to: &list) {
                SystemAudioRecorder.makeBuffer(from: $0, format: tapFormat)
            }
            // Scribble over the source after the copy; the copy must not change.
            for i in 0..<raw.count { raw[i] = -99 }
            return out
        }
        let result = try! XCTUnwrap(copied)
        XCTAssertEqual(result.floatChannelData![0][0], 0.5)
    }

    func testEmptyBufferIsRejectedRatherThanWrittenAsZeroFrames() {
        XCTAssertNil(copyThroughMakeBuffer([], format: tapFormat))
    }

    /// Guards the RMS path the "Them" level bar reads: a silent tap buffer must meter 0,
    /// and a loud one must not. This is exactly the signal that was bit-exact zero for
    /// the whole Continuity call under ScreenCaptureKit.
    func testMeteringDistinguishesSilenceFromSignal() {
        let silent = try! XCTUnwrap(copyThroughMakeBuffer([Float](repeating: 0, count: 8), format: tapFormat))
        XCTAssertEqual(LevelMeter.rms(silent), 0, accuracy: 0.0001)

        let loud = try! XCTUnwrap(copyThroughMakeBuffer([Float](repeating: 0.5, count: 8), format: tapFormat))
        XCTAssertGreaterThan(LevelMeter.rms(loud), 0.4)
    }

    // MARK: - Silence padding
    //
    // The tap delivers nothing while the output device is idle, so the recorder
    // reconstructs the missing wall-clock time as silence. If this regresses, the
    // system track compresses against the continuously-streaming mic track and
    // two-party attribution drifts — which no other test would catch.

    private func makeRecorder() throws -> (SystemAudioRecorder, WavChunkWriter, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One long chunk so duration is read from a single file.
        let writer = try WavChunkWriter(directory: dir, prefix: "sys", chunkDuration: 600)
        return (SystemAudioRecorder(writer: writer), writer, dir)
    }

    /// Total seconds of 16 kHz mono audio the writer produced.
    private func writtenSeconds(_ writer: WavChunkWriter, _ dir: URL) throws -> Double {
        try writer.finish()
        var frames: AVAudioFramePosition = 0
        for url in writer.completedChunks {
            frames += try AVAudioFile(forReading: url).length
        }
        return Double(frames) / 16_000
    }

    func testPaddingFillsAnIdleGapWithSilence() throws {
        let (recorder, writer, dir) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two seconds of wall clock elapsed with the tap delivering nothing.
        recorder.captureStart = CFAbsoluteTimeGetCurrent() - 2.0
        recorder.padSilenceToNow(format: tapFormat)

        XCTAssertEqual(try writtenSeconds(writer, dir), 2.0, accuracy: 0.1)
    }

    /// Recomputing from the wall clock (rather than accumulating) must make a second
    /// call a no-op once the track has caught up — otherwise every callback would
    /// re-pad and the system track would run *long* instead of short.
    func testPaddingIsIdempotentOnceCaughtUp() throws {
        let (recorder, writer, dir) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: dir) }

        recorder.captureStart = CFAbsoluteTimeGetCurrent() - 1.0
        recorder.padSilenceToNow(format: tapFormat)
        recorder.padSilenceToNow(format: tapFormat)
        recorder.padSilenceToNow(format: tapFormat)

        XCTAssertEqual(try writtenSeconds(writer, dir), 1.0, accuracy: 0.15)
    }

    /// Sub-threshold gaps are IOProc jitter, not real silence; padding them would
    /// insert a sliver of audio on essentially every callback.
    func testJitterSizedGapIsNotPadded() throws {
        let (recorder, writer, dir) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: dir) }

        recorder.captureStart = CFAbsoluteTimeGetCurrent() - 0.005  // 5ms, under the ~20ms slack
        recorder.padSilenceToNow(format: tapFormat)

        XCTAssertEqual(try writtenSeconds(writer, dir), 0, accuracy: 0.0001)
    }

    /// An unanchored clock must pad nothing. `captureStart` is 0 until `start()` runs, and
    /// CFAbsoluteTime's epoch is 2001 — so treating 0 as a real anchor would ask for
    /// ~10^13 frames and write silence until the disk filled.
    func testUnanchoredClockPadsNothing() throws {
        let (recorder, writer, dir) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(recorder.captureStart, 0, "captureStart should start unanchored")
        recorder.padSilenceToNow(format: tapFormat)

        XCTAssertEqual(try writtenSeconds(writer, dir), 0, accuracy: 0.0001)
    }

    /// Frames already delivered by the tap must count against the gap, so padding only
    /// covers what's actually missing.
    func testDeliveredFramesReduceThePad() throws {
        let (recorder, writer, dir) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: dir) }

        recorder.captureStart = CFAbsoluteTimeGetCurrent() - 2.0
        // Pretend the tap already delivered 1s of 48 kHz audio.
        recorder.framesWritten = 48_000
        recorder.padSilenceToNow(format: tapFormat)

        // ~1s still missing, so ~1s of silence — not 2s.
        XCTAssertEqual(try writtenSeconds(writer, dir), 1.0, accuracy: 0.1)
    }
}
