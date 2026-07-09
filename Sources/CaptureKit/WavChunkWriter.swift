import Foundation
import AVFoundation

public enum WavChunkWriterError: Error {
    /// Defensive backstop: the resampled-sample accumulator could not be
    /// flushed into an output buffer. Should be unreachable in practice since
    /// the accumulator grows to fit whatever the converter produces, but a
    /// thrown error here is strictly preferable to ever silently dropping
    /// audio.
    case converterOverflow
}

public enum CaptureAudio {
    /// Canonical on-disk format: 16 kHz mono Int16 — Whisper's native input rate.
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    public static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
}

/// Writes incoming PCM buffers (any format) to sequential 16k mono WAV chunk files.
/// Not thread-safe; call from one queue/actor.
public final class WavChunkWriter {
    public private(set) var completedChunks: [URL] = []

    private let directory: URL
    private let prefix: String
    private let chunkFrames: AVAudioFramePosition
    private var currentFile: AVAudioFile?
    private var currentIndex = 0
    private var framesInCurrentChunk: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    public init(directory: URL, prefix: String, chunkDuration: TimeInterval = 30) throws {
        self.directory = directory
        self.prefix = prefix
        self.chunkFrames = AVAudioFramePosition(chunkDuration * 16_000)
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        let converted = try convertTo16kMono(buffer)
        if currentFile == nil { try openNextChunk() }
        try currentFile!.write(from: converted)
        framesInCurrentChunk += AVAudioFramePosition(converted.frameLength)
        if framesInCurrentChunk >= chunkFrames { try rollChunk() }
    }

    public func finish() throws {
        if currentFile != nil { try rollChunk() }
    }

    private func openNextChunk() throws {
        let url = directory.appendingPathComponent(String(format: "%@-%04d.wav", prefix, currentIndex))
        currentFile = try AVAudioFile(forWriting: url, settings: CaptureAudio.wavSettings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)
        framesInCurrentChunk = 0
    }

    private func rollChunk() throws {
        guard let file = currentFile else { return }
        let url = file.url
        currentFile = nil  // AVAudioFile flushes/closes on dealloc
        completedChunks.append(url)
        currentIndex += 1
    }

    private func convertTo16kMono(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == CaptureAudio.format { return buffer }
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: CaptureAudio.format)
            converterInputFormat = buffer.format
        }
        guard let converter else {
            throw NSError(domain: "WavChunkWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No converter for \(buffer.format)"])
        }
        // Signaling .endOfStream below tells the converter this call's source is
        // done so it fully flushes any internally buffered/latent samples (filter
        // tail) rather than holding them back — without this, real resamplers
        // silently drop their tail on every call. But .endOfStream also marks
        // the AVAudioConverter instance itself as permanently finished; since
        // `converter` is deliberately reused across append() calls (to keep
        // resampler state/continuity where possible), it must be reset before
        // returning — on every exit path, including thrown errors — so the next
        // append() call can feed it fresh data instead of hitting the
        // converter's terminal state.
        defer { converter.reset() }
        let ratio = 16_000 / buffer.format.sampleRate
        // Sized as a hint only — `samples` grows to fit whatever the
        // converter actually produces, so an undersized estimate here can
        // never cause audio loss (unlike a fixed-capacity output buffer
        // would).
        var samples: [Int16] = []
        samples.reserveCapacity(Int(Double(buffer.frameLength) * ratio) + 64)
        // AVAudioConverter's block-based convert(to:error:withInputFrom:) does not
        // drain arbitrarily large input/output in a single call — in practice it
        // only pulls/produces an internal chunk's worth (observed: 4096 frames)
        // per invocation. Handing the converter the *entire* source buffer once
        // (fed=true) silently drops whatever it didn't consume on that first
        // pull, since the input block contract requires fresh data each call —
        // it won't re-offer a partially-consumed buffer. So we hand-roll our own
        // frame offset into `buffer` and slice off a fresh piece each time the
        // input block is invoked, and loop the outer convert() call until both
        // the input is exhausted and a call yields zero output frames.
        var offset: AVAudioFrameCount = 0
        while true {
            let chunk = AVAudioPCMBuffer(pcmFormat: CaptureAudio.format, frameCapacity: 4096)!
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                guard let piece = self.makeChunk(from: buffer, offset: offset, maxFrames: 4096) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                offset += piece.frameLength
                inputStatus.pointee = .haveData
                return piece
            }
            if let error { throw error }
            if chunk.frameLength > 0, let src = chunk.int16ChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: src, count: Int(chunk.frameLength)))
            }
            if status == .endOfStream { break }
            if chunk.frameLength == 0 && offset >= buffer.frameLength { break }
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: CaptureAudio.format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw WavChunkWriterError.converterOverflow
        }
        out.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty {
            guard let dst = out.int16ChannelData?[0] else { throw WavChunkWriterError.converterOverflow }
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return out
    }

    /// Copies up to `maxFrames` frames starting at `offset` out of `buffer` into a
    /// freshly allocated buffer of the same format. Works for interleaved and
    /// non-interleaved layouts alike since `mBytesPerFrame` already reflects the
    /// per-AudioBuffer stride for either layout.
    private func makeChunk(from buffer: AVAudioPCMBuffer, offset: AVAudioFrameCount, maxFrames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard offset < buffer.frameLength else { return nil }
        let n = min(buffer.frameLength - offset, maxFrames)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: n) else { return nil }
        chunk.frameLength = n
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let srcBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dstBuffers = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
        for i in 0..<srcBuffers.count {
            guard let srcData = srcBuffers[i].mData, let dstData = dstBuffers[i].mData else { continue }
            memcpy(dstData, srcData.advanced(by: Int(offset) * bytesPerFrame), Int(n) * bytesPerFrame)
        }
        return chunk
    }
}
