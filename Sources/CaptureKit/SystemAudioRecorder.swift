import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// Captures system audio output (the other call participants) via a CoreAudio
/// process tap, excluding our own process.
///
/// **Why a tap and not ScreenCaptureKit** (this used to be SCK — see checklist #16):
/// `SCContentFilter(display:excludingWindows:)` scopes capture to audio produced by
/// *windows on that display*. A Continuity/cellular call (an iPhone call answered on
/// the Mac) is voiced by a windowless system daemon, so it contributes nothing to the
/// display-scoped mix: SCK delivered buffers at full rate containing bit-exact silence
/// for the entire call, while every Zoom/Meet/browser call captured fine. A tap scopes
/// by *what reaches the output device* instead, so it hears the call. Verified against
/// a live Continuity call: tap RMS tracked speech (-15 dB) and gaps (-80 dB) at the
/// same moment SCK wrote zeros.
///
/// The aggregate device deliberately has **no output sub-device** — only the tap. That
/// keeps capture independent of the current output device, so switching AirPods →
/// speakers mid-call can't leave us bound to a stale device UID. Verified: a tap-only
/// aggregate delivers audio with `kAudioAggregateDeviceSubDeviceListKey: []`.
///
/// Hardware capture is not exercised by the unit test suite — a real audio device isn't
/// available in CI/sandbox environments. Manual verification is covered by checklist #16.
public final class SystemAudioRecorder: NSObject, StreamRecorder, @unchecked Sendable {
    public var onLevel: (@Sendable (Float) -> Void)?

    private let writer: WavChunkWriter
    private let queue = DispatchQueue(label: "debrief.sys-writer")
    private static let logger = Logger(subsystem: "com.debrief.app", category: "capture")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    /// Logged once so a support report can distinguish "tap never delivered" from
    /// "tap delivered silence" without a rebuild — the exact ambiguity that made the
    /// Continuity bug take two sessions to pin down. Only touched from `queue`.
    private var loggedFirstBuffer = false
    /// Wall-clock anchor and the count of tap-format frames handed to the writer, for
    /// the silence padding in `padSilenceToNow`. Set before the IOProc can fire, then
    /// only touched from `queue`. Internal rather than private so the padding can be
    /// unit-tested without an audio device.
    var captureStart: CFAbsoluteTime = 0
    var framesWritten: Int64 = 0

    public init(writer: WavChunkWriter) { self.writer = writer }

    public func start() async throws {
        framesWritten = 0
        do {
            try startCapture()
        } catch {
            // Otherwise a failed start (denied permission, no device) leaks the tap and
            // aggregate until the process exits, and they accumulate if the user retries.
            releaseDevices()
            throw error
        }
    }

    private func startCapture() throws {
        // A global tap: everything any process plays, minus our own output. Debrief
        // plays nothing today, but excluding ourselves keeps a future notification
        // sound out of the interview audio.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted  // never silence the user's call
        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try Self.check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd),
                       "read tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw Self.error("Unsupported tap format")
        }
        tapFormat = format

        // Private so the aggregate never appears in Sound settings or other apps'
        // device lists.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Debrief System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice),
                       "create aggregate device")
        aggregateID = aggregateDevice

        // Callbacks land on `queue`, the same queue `stop()` finishes the writer on,
        // so writer access stays serialized without a lock.
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }, "create IOProc")
        captureStart = CFAbsoluteTimeGetCurrent()
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
        Self.logger.info("SystemAudioRecorder: tap started, format \(format, privacy: .public)")
    }

    public func stop() async throws {
        releaseDevices()
        // Runs after the teardown above, so no IOProc callback can still be writing.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                // Trailing pad so the system track spans the whole recording, matching
                // the continuously-streaming mic track.
                if let tapFormat = self.tapFormat { self.padSilenceToNow(format: tapFormat) }
                do { try self.writer.finish(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Stops and destroys the aggregate device and tap. Idempotent, so it is safe from
    /// both `stop()` and a failed `start()`.
    private func releaseDevices() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              let pcm = SystemAudioRecorder.makeBuffer(from: input, format: tapFormat) else { return }
        padSilenceToNow(format: tapFormat)
        onLevel?(LevelMeter.rms(pcm))
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            Self.logger.info("SystemAudioRecorder: first tap buffer delivered")
        }
        do {
            try writer.append(pcm)
            framesWritten += Int64(pcm.frameLength)
        } catch {
            Self.logger.error("SystemAudioRecorder: writer.append failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Fills the gap between what the wall clock says we should have captured and what
    /// the tap actually delivered.
    ///
    /// A process tap delivers **nothing at all** while the output device is idle —
    /// verified on macOS 26: zero IOProc callbacks until audio plays, then full-rate
    /// 48 kHz. (Including an output sub-device in the aggregate does not change this.)
    /// The ScreenCaptureKit path this replaced delivered full-rate zeros instead, so a
    /// wall-clock-accurate timeline came free; the tap needs it reconstructed.
    ///
    /// Without this, `MicRecorder` — an AVAudioEngine tap, which always streams — would
    /// keep real time while the system track compressed, so every "them" segment after
    /// an idle stretch would land early in `TranscriptMerger.merge(you:them:)` and the
    /// two-party attribution would drift. The common case is real: recording starts,
    /// then the user joins the call seconds later.
    ///
    /// Recomputed from the wall clock rather than accumulated, so a long idle stretch or
    /// a dropped buffer self-corrects on the next callback instead of drifting.
    func padSilenceToNow(format: AVAudioFormat) {
        let expected = Int64((CFAbsoluteTimeGetCurrent() - captureStart) * format.sampleRate)
        var missing = expected - framesWritten
        // Below ~20ms it's IOProc jitter, not a gap worth representing.
        guard missing > Int64(format.sampleRate / 50) else { return }
        onLevel?(0)  // the level bar should read silent, not freeze at its last value
        while missing > 0 {
            let frames = AVAudioFrameCount(min(missing, Int64(format.sampleRate)))  // ≤1s per piece
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            silence.frameLength = frames
            // AVAudioPCMBuffer does not promise zeroed memory.
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            do {
                try writer.append(silence)
            } catch {
                Self.logger.error("SystemAudioRecorder: silence pad failed: \(String(describing: error), privacy: .public)")
                return
            }
            framesWritten += Int64(frames)
            missing -= Int64(frames)
        }
    }

    /// Copies an `AudioBufferList` handed to us by CoreAudio into an owned
    /// `AVAudioPCMBuffer` of the same format. The IOProc's buffers are only valid for
    /// the duration of the callback, so this copy is required, not defensive.
    ///
    /// `mBytesPerFrame` already reflects the per-`AudioBuffer` stride for interleaved
    /// and non-interleaved layouts alike, so one path handles both.
    static func makeBuffer(from input: UnsafePointer<AudioBufferList>,
                           format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let first = source.first else { return nil }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destination.count == source.count else { return nil }
        for i in 0..<source.count {
            guard let src = source[i].mData, let dst = destination[i].mData else { return nil }
            memcpy(dst, src, min(Int(source[i].mDataByteSize), Int(destination[i].mDataByteSize)))
        }
        return buffer
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw error("\(what) failed: OSStatus \(status) (\(fourCC(status)))")
    }

    /// OSStatus values from CoreAudio are usually packed four-character codes
    /// ('!obj', 'nope'), which are far easier to search for than the signed decimal.
    private static func fourCC(_ status: OSStatus) -> String {
        let chars = withUnsafeBytes(of: status.bigEndian) {
            $0.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "?" }
        }
        return String(chars)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SystemAudioRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
