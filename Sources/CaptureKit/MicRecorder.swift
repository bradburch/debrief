import Foundation
import AVFoundation
import os

/// Captures the default input device via AVAudioEngine and streams buffers
/// into a WavChunkWriter (which converts to 16k mono Int16).
///
/// Hardware capture is not exercised by the unit test suite — permissions and
/// a real input device aren't available in CI/sandbox environments. Manual
/// verification is covered by the Task 16 checklist.
public final class MicRecorder: StreamRecorder, @unchecked Sendable {
    public var onLevel: (@Sendable (Float) -> Void)?

    private let writer: WavChunkWriter
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "debrief.mic-writer")
    private static let logger = Logger(subsystem: "com.debrief.app", category: "capture")

    public init(writer: WavChunkWriter) { self.writer = writer }

    public func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw NSError(domain: "MicRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(LevelMeter.rms(buffer))
            self.queue.async {
                do {
                    try self.writer.append(buffer)
                } catch {
                    Self.logger.error("MicRecorder: writer.append failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        try engine.start()
    }

    public func stop() async throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Best-effort drain: block until every append already enqueued before
        // this point has run, so finish() (enqueued below) doesn't race ahead
        // of in-flight appends. The tap callback fires on an audio-render
        // thread and dispatches its append async onto `queue`; a tap
        // invocation that was mid-flight at the exact instant removeTap/
        // engine.stop() ran could still enqueue its append concurrently with
        // this sync — at most one tap buffer (~0.1s at the 4096-frame/typical
        // sample-rate tap size) racing the exact stop instant can be lost.
        // End-to-end verification of stop() behavior against real hardware is
        // covered by Task 16's manual checklist.
        queue.sync {}
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.writer.finish(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }
}
