import Foundation

public protocol Transcribing: Sendable {
    /// Transcribe one WAV file. Returned starts are relative to the file's own t=0.
    func transcribe(wavURL: URL) async throws -> [TimedText]
}
