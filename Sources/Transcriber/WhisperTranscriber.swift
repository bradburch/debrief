import Foundation
import WhisperKit

public enum WhisperModel: String, Sendable {
    case accurate = "small.en" // per-chunk transcription, live during the call and at finalize
}

public actor WhisperTranscriber: Transcribing {
    private let model: WhisperModel
    private var pipeTask: Task<WhisperKit, Error>?

    /// Matches Whisper special tokens like <|startoftranscript|>, <|en|>, <|0.00|>.
    private static let specialTokenRegex = try! NSRegularExpression(pattern: "<\\|[^|]*\\|>")

    public init(model: WhisperModel) { self.model = model }

    public func transcribe(wavURL: URL) async throws -> [TimedText] {
        let pipe = try await loadedPipe()
        // WhisperKit 0.18.0 resolves `transcribe(audioPath:)` to an ambiguous overload
        // (`TranscriptionResult?` vs `[TranscriptionResult]`) without an explicit type
        // annotation, so pin the array-returning form here.
        let results: [TranscriptionResult] = try await pipe.transcribe(audioPath: wavURL.path)
        return results.flatMap { result in
            result.segments.map { seg in
                TimedText(start: TimeInterval(seg.start), text: Self.stripSpecialTokens(seg.text))
            }
        }
    }

    private static func stripSpecialTokens(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = specialTokenRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let pipeTask {
            return try await pipeTask.value
        }
        let model = self.model
        let task = Task {
            try await WhisperKit(WhisperKitConfig(model: model.rawValue))
        }
        pipeTask = task
        do {
            return try await task.value
        } catch {
            pipeTask = nil  // allow retry after a failed load (e.g. network error)
            throw error
        }
    }
}
