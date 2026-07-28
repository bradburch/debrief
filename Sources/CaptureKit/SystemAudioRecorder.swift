import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import os

/// Captures system audio output (the other call participants) via ScreenCaptureKit,
/// excluding our own process. Requires Screen Recording permission.
///
/// Hardware capture is not exercised by the unit test suite — Screen Recording
/// permission and a real display aren't available in CI/sandbox environments.
/// Manual verification is covered by the Task 16 checklist.
public final class SystemAudioRecorder: NSObject, StreamRecorder, SCStreamOutput, @unchecked Sendable {
    public var onLevel: (@Sendable (Float) -> Void)?

    private let writer: WavChunkWriter
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "debrief.sys-writer")
    private static let logger = Logger(subsystem: "com.debrief.app", category: "capture")
    /// Throttled diagnostic for the Continuity/cellular-call audio gap (see manual-test-
    /// checklist #16): logs whether SCK is delivering audio buffers at all, and at what
    /// level, roughly every 3s. Only touched from `queue`, so no lock needed. Distinguishes
    /// "SCK never calls back during the call" (platform excludes it from the capture mix —
    /// nothing app-side can fix) from "buffers arrive but are silent" (a different, possibly
    /// fixable bug). ponytail: fixed 3s cadence, not configurable — this is a one-off
    /// diagnostic to delete once the root cause is confirmed, not a permanent feature.
    private var lastDiagnosticLogTime: CFAbsoluteTime = 0

    public init(writer: WavChunkWriter) { self.writer = writer }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Keep video capture at minimal cost — SCK requires a video stream but we ignore its frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async throws {
        if let stream {
            try await stream.stopCapture()
        }
        stream = nil
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.writer.finish(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = sampleBuffer.toPCMBuffer() else { return }
        let rms = LevelMeter.rms(pcm)
        onLevel?(rms)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastDiagnosticLogTime > 3 {
            lastDiagnosticLogTime = now
            Self.logger.debug("SystemAudioRecorder: buffer delivered, rms=\(rms, privacy: .public)")
        }
        do {
            try writer.append(pcm)
        } catch {
            Self.logger.error("SystemAudioRecorder: writer.append failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension CMSampleBuffer {
    /// Convert an SCK audio CMSampleBuffer into an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(self),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
