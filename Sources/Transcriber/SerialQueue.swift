import Foundation

/// Runs async bodies one at a time.
///
/// Exists because actor isolation is *not* a mutual-exclusion lock across suspension
/// points: Swift actors are reentrant, so an actor method that awaits lets the next caller
/// in at exactly that await. For a wrapper around a stateful non-reentrant resource — a
/// loaded WhisperKit pipeline — that is not a data race the compiler can see and not a
/// crash; it is two transcriptions sharing one pipeline and returning each other's audio.
///
/// Each submission chains onto the tail of the previous one, so `body` never starts until
/// the body before it has returned. Bodies run in whatever order callers reach this actor,
/// which is not necessarily the order they were written — mutual exclusion is the contract
/// here, not ordering. The chain holds only its tail, so completed work is released.
actor SerialQueue {
    private var tail: Task<Void, Never>?

    /// Bodies submitted so far. Exists for `SerialQueueTests`, which has to know a second
    /// submission has actually chained onto a *running* predecessor — otherwise the test
    /// quietly degrades into the empty-queue case it was written to be different from.
    private(set) var submissionCount = 0

    /// Bodies are deliberately **not** cancelled with the caller: `body` runs in its own
    /// task, so a cancelled caller still leaves the chain intact and the work running.
    /// Cancelling would buy nothing anyway — a WhisperKit decode is not
    /// cancellation-responsive — and abandoning a body mid-chain is how the queue would
    /// wedge. `SerialQueueTests` pins this behaviour.
    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        submissionCount += 1
        let previous = tail
        let work = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        // The chain node must complete when `work` does, whether it threw or not — a failed
        // transcription must not wedge every later one behind it.
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}
