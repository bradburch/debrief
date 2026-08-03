import Foundation
import Store
import os

/// Coaching through the locally installed Claude Code CLI (`claude -p`), which authenticates
/// with the user's Claude subscription instead of a pay-per-token API key.
///
/// **Know what this trades away before choosing it.** Measured on macOS with CLI 2.1.220:
///
/// - **~15–20k tokens of overhead per debrief.** Every `claude -p` call carries Claude Code's
///   own system prompt and tool definitions. It is not removable: disabling all tools and
///   passing a minimal system prompt measured *worse* (20,662 tokens vs 15,589), because
///   changing the prefix breaks Claude Code's prompt cache and forces a full re-create.
/// - **No JSON schema.** The CLI has no equivalent of `AnthropicClient.outputSchema`, so the
///   response contract is enforced as prose plus an explicit key-set check — the same
///   mechanism `OpenAICompatibleClient` uses, shared via `decodeCoaching(from:dimensions:)`.
/// - **Subscription rate limits are session-windowed**, so a bulk `recoachAll()` across many
///   stored sessions can throttle where the metered API would not.
/// - **Claude Code is a coding tool.** Using it as a general LLM backend is outside its
///   intended use and the CLI's flags and output shape are not a stable contract — a CLI
///   update can break this path with no warning. `AnthropicClient` remains the supported one.
public struct ClaudeCodeCLIClient: CoachingLLM {
    let executable: URL
    let model: String
    let timeout: TimeInterval
    private static let logger = Logger(subsystem: "com.debrief.app", category: "coaching")

    public init(executable: URL, model: String = "claude-opus-5", timeout: TimeInterval = 600) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
    }

    /// Locations to search for the `claude` binary, in order.
    ///
    /// A path search is required rather than `/usr/bin/env claude`: an app launched from
    /// Finder inherits a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so the usual install
    /// location under `~/.local/bin` is invisible to it even though it resolves fine in a
    /// shell. Getting this wrong presents as "works in tests, fails in the built app".
    public static func defaultSearchPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
        ]
    }

    /// First existing, executable `claude` binary, or nil when none is installed.
    public static func locate(extraPath: String? = nil) -> URL? {
        var candidates: [URL] = []
        if let extraPath, !extraPath.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates.append(URL(fileURLWithPath: extraPath))
        }
        candidates.append(contentsOf: defaultSearchPaths())
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func generateCoaching(systemPrompt: String, userMessage: String,
                                 dimensions: [String]) async throws -> CoachingResult {
        // The rubric goes in --system-prompt (a few KB, comfortably under ARG_MAX) and the
        // transcript goes on stdin, because a long interview can approach the 1MB argv limit.
        let system = systemPrompt + "\n\n" + OpenAICompatibleClient.formatAppendix(dimensions: dimensions)
        let output = try await run(arguments: [
            "-p",
            "--output-format", "json",
            "--model", model,
            "--system-prompt", system,
        ], stdin: userMessage)

        struct Envelope: Decodable {
            let result: String?
            let is_error: Bool?
            let subtype: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: output) else {
            throw ClaudeError.httpStatus(0, body: String(data: output, encoding: .utf8) ?? "")
        }
        guard envelope.is_error != true, let result = envelope.result else {
            throw ClaudeError.httpStatus(0, body: envelope.subtype ?? "claude CLI reported an error")
        }
        return try OpenAICompatibleClient.decodeCoaching(from: result, dimensions: dimensions)
    }

    /// Runs the CLI and returns its stdout.
    ///
    /// stdout is drained continuously rather than read after exit: a debrief response can
    /// exceed the 64KB pipe buffer, and a full buffer with no reader deadlocks — the child
    /// blocks writing, the parent blocks waiting for a child that will never exit.
    /// Internal rather than private so tests can drive it with a stand-in binary (`/bin/cat`)
    /// and push more than a pipe's worth of data through it without needing the CLI.
    func run(arguments: [String], stdin: String) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()  // discard; the JSON envelope carries the error
        process.standardInput = inPipe

        let collector = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collector.append(chunk) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            // Guards against double-resume: the timeout and the exit handler race, and
            // resuming a continuation twice is a crash, not an error.
            @Sendable func finish(_ outcome: Result<Data, Error>) {
                let alreadyResumed = resumed.withLock { was -> Bool in
                    defer { was = true }
                    return was
                }
                guard !alreadyResumed else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(with: outcome)
            }

            process.terminationHandler = { proc in
                // Stop the streaming reader BEFORE draining. Leaving it installed means two
                // readers on the same descriptor at once — readToEnd and the handler
                // interleave, and chunks are lost or double-counted.
                outPipe.fileHandleForReading.readabilityHandler = nil
                let rest = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
                if let rest, !rest.isEmpty { collector.append(rest) }
                guard proc.terminationStatus == 0 else {
                    finish(.failure(ClaudeError.httpStatus(Int(proc.terminationStatus),
                                                           body: collector.string)))
                    return
                }
                finish(.success(collector.data))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(error))
                return
            }

            // Armed BEFORE the stdin write, not after: the write below can block, and a
            // timeout scheduled afterwards would never be armed to rescue it.
            //
            // Without this a wedged CLI would hang finalize indefinitely. Coaching is
            // already best-effort inside runFinalize, so a timeout leaves the session
            // retryable rather than blocking the recording from finishing.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                Self.logger.error("ClaudeCodeCLIClient: timed out after \(timeout, privacy: .public)s; terminating")
                process.terminate()
            }

            // Off the caller's thread: a pipe holds ~64KB, and an interview transcript
            // routinely exceeds that, so writing it blocks until the CLI drains stdin. Doing
            // that inline would block a Swift concurrency cooperative thread — and if the CLI
            // never drains, it would hang before the timeout above could fire.
            DispatchQueue.global().async {
                let handle = inPipe.fileHandleForWriting
                do {
                    try handle.write(contentsOf: Data(stdin.utf8))
                } catch {
                    // Broken pipe means the CLI already exited; terminationHandler reports why.
                    Self.logger.error("ClaudeCodeCLIClient: stdin write failed: \(String(describing: error), privacy: .public)")
                }
                try? handle.close()
            }
        }
    }
}

/// Thread-safe stdout accumulator. `readabilityHandler` fires on an arbitrary queue, so the
/// buffer it appends to cannot be plain mutable state.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    var string: String { String(data: data, encoding: .utf8) ?? "" }
}
