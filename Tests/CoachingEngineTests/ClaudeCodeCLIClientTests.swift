import XCTest
@testable import CoachingEngine
import Store

/// Unit coverage for the parts of the subscription path that don't need the CLI installed.
/// The real end-to-end contract check lives in `ClaudeCodeCLIIntegrationTests`.
final class ClaudeCodeCLIClientTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeExecutable(named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho hi\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A configured path must win over the built-in search list, so a non-standard install
    /// can be pointed at from Settings.
    func testExplicitPathTakesPrecedence() throws {
        let custom = try makeExecutable(named: "claude")
        XCTAssertEqual(ClaudeCodeCLIClient.locate(extraPath: custom.path), custom)
    }

    /// An empty or whitespace-only Settings field must fall through to the search list
    /// rather than being treated as a path (which would resolve to nothing).
    func testBlankExplicitPathFallsThroughToSearch() {
        let blank = ClaudeCodeCLIClient.locate(extraPath: "   ")
        XCTAssertEqual(blank, ClaudeCodeCLIClient.locate(extraPath: nil))
    }

    func testNonExecutablePathIsNotAccepted() throws {
        let plain = dir.appendingPathComponent("claude")
        try "not executable".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(ClaudeCodeCLIClient.locate(extraPath: plain.path), plain)
    }

    /// The search list must be absolute paths. `/usr/bin/env claude` would resolve in a
    /// shell but not in an app launched from Finder, which inherits a minimal PATH — the
    /// exact "works in tests, fails in the built app" trap this list exists to avoid.
    func testSearchPathsAreAbsolute() {
        let paths = ClaudeCodeCLIClient.defaultSearchPaths()
        XCTAssertFalse(paths.isEmpty)
        for url in paths {
            XCTAssertTrue(url.path.hasPrefix("/"), "\(url.path) is not absolute")
            XCTAssertEqual(url.lastPathComponent, "claude")
        }
    }

    // MARK: - Process plumbing
    //
    // Driven with /bin/cat rather than the real CLI: it echoes stdin to stdout, so one
    // payload exercises both directions of the pipe with no subscription quota spent.

    /// A pipe holds ~64KB. An interview transcript routinely exceeds that, so both the write
    /// and the read must be able to outrun the buffer:
    ///  - writing inline on the caller's thread blocks once the buffer fills, and would hang
    ///    before the timeout is armed;
    ///  - reading only after exit deadlocks the child, which blocks writing output nobody is
    ///    draining.
    /// A regression in either shows up here as a hang or a short read, not a wrong value.
    func testPayloadLargerThanThePipeBufferSurvivesBothDirections() async throws {
        let big = String(repeating: "abcdefghij", count: 40_000)  // ~400KB, ~6x the buffer
        let client = ClaudeCodeCLIClient(executable: URL(fileURLWithPath: "/bin/cat"), timeout: 60)

        let out = try await client.run(arguments: [], stdin: big)

        XCTAssertEqual(out.count, big.utf8.count, "output truncated — a pipe read was lost")
        XCTAssertEqual(String(data: out, encoding: .utf8), big)
    }

    /// A non-zero exit must surface as an error rather than being reported as an empty
    /// success, which would decode to "no debrief" instead of a retryable failure.
    func testNonZeroExitIsAnError() async throws {
        let client = ClaudeCodeCLIClient(executable: URL(fileURLWithPath: "/bin/sh"), timeout: 60)
        do {
            _ = try await client.run(arguments: ["-c", "exit 3"], stdin: "")
            XCTFail("expected a non-zero exit to throw")
        } catch {
            // Expected — the specific error type isn't the contract, failing is.
        }
    }

    /// A wedged CLI must not hang finalize forever.
    func testTimeoutTerminatesAHungProcess() async throws {
        let client = ClaudeCodeCLIClient(executable: URL(fileURLWithPath: "/bin/sh"), timeout: 1)
        let started = Date()
        do {
            _ = try await client.run(arguments: ["-c", "sleep 30"], stdin: "")
            XCTFail("expected the timeout to terminate the process")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 20, "timeout did not fire")
        }
    }

    /// The CLI path reuses the same prose contract as the local-model path. If the model
    /// returns the wrong dimension keys there is no schema to catch it, so this check is
    /// the only thing standing between a bad response and a debrief scored on the wrong
    /// dimensions.
    func testDecodeRejectsWrongDimensionKeys() throws {
        let payload = """
            {"prose_debrief": "A real debrief.", "scores": {"not_a_real_dimension": 3},
             "advancement": "lean_yes", "advancement_rationale": "ok",
             "weakness_tags": [], "highlights": [], "action_items": [], "process_notes": []}
            """
        XCTAssertThrowsError(
            try OpenAICompatibleClient.decodeCoaching(from: payload,
                                                      dimensions: ["structure", "conciseness"]))
    }

    func testDecodeAcceptsExactDimensionKeys() throws {
        let payload = """
            Sure, here's the debrief:
            {"prose_debrief": "A real debrief.", "scores": {"structure": 2, "conciseness": 4},
             "advancement": "lean_yes", "advancement_rationale": "ok",
             "weakness_tags": [], "highlights": [], "action_items": [], "process_notes": []}
            """
        let result = try OpenAICompatibleClient.decodeCoaching(
            from: payload, dimensions: ["structure", "conciseness"])
        XCTAssertEqual(result.scores["structure"], 2)
        XCTAssertEqual(result.scores["conciseness"], 4)
    }
}
