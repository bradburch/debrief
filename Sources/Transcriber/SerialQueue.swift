import Foundation

/// Runs async bodies one at a time, in submission order.
///
/// Exists because actor isolation is *not* a mutual-exclusion lock across suspension
/// points: Swift actors are reentrant, so an actor method that awaits lets the next caller
/// in at exactly that await. For a wrapper around a stateful non-reentrant resource — a
/// loaded WhisperKit pipeline — that is not a data race the compiler can see and not a
/// crash; it is two transcriptions sharing one pipeline and returning each other's audio.
///
/// Each submission chains onto the tail of the previous one, so `body` never starts until
/// the body before it has returned. The chain holds only its tail, so completed work is
/// released.
actor SerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
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
