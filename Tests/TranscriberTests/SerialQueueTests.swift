import XCTest
@testable import Transcriber

/// Counts overlapping bodies. `@unchecked Sendable` + a lock rather than an actor: an actor
/// would serialize the observations and hide exactly what this is looking for.
private final class OverlapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    func enter() {
        lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
    }
    func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
}

final class SerialQueueTests: XCTestCase {
    /// The reason `WhisperTranscriber` has a gate at all: without one, concurrent callers
    /// run inside a single WhisperKit pipeline. Actor isolation does not provide this —
    /// actors are reentrant, so the awaits below would interleave.
    func testBodiesNeverOverlap() async throws {
        let queue = SerialQueue()
        let counter = OverlapCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await queue.run {
                        counter.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        counter.leave()
                        return 0
                    }
                }
            }
        }
        XCTAssertEqual(counter.maxInFlight, 1, "two bodies ran at once")
    }

    /// A thrown body must not wedge the queue behind it.
    func testFailureDoesNotBlockLaterWork() async throws {
        struct Boom: Error {}
        let queue = SerialQueue()
        do {
            _ = try await queue.run { throw Boom() }
            XCTFail("expected the body's error to propagate")
        } catch is Boom {}
        let value = try await queue.run { 42 }
        XCTAssertEqual(value, 42)
    }

    /// Pins the deliberate choice that a body outlives its caller's cancellation. `run` hands
    /// the body to its own task, which does not inherit cancellation — cancelling would buy
    /// nothing (a WhisperKit decode ignores it) and abandoning a body mid-chain is how the
    /// queue would wedge every submission behind it.
    ///
    /// There is deliberately no test that submission order is preserved: the hop onto this
    /// actor is not ordered, so the contract is mutual exclusion, not ordering.
    func testCancelledCallerLeavesTheChainIntact() async throws {
        let queue = SerialQueue()
        let latch = Latch()

        let caller = Task {
            _ = try? await queue.run {
                await latch.wait()
                // Read inside the body: an unstructured task does not inherit its creator's
                // cancellation, which is exactly the property being pinned.
                await latch.markFinished(cancelled: Task.isCancelled)
                return 0
            }
        }
        for _ in 0..<1000 where await latch.waitingCount == 0 { await Task.yield() }
        let parked = await latch.waitingCount
        XCTAssertEqual(parked, 1, "the body never reached the latch")

        caller.cancel()
        await latch.open()
        await caller.value

        let finished = await latch.finished
        XCTAssertTrue(finished, "the body was abandoned when its caller was cancelled")
        let bodyWasCancelled = await latch.bodyWasCancelled
        XCTAssertFalse(bodyWasCancelled, "the body inherited its caller's cancellation")
        let later = try await queue.run { 7 }
        XCTAssertEqual(later, 7, "the queue was wedged by a cancelled caller")
    }
}

private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var finished = false
    private(set) var bodyWasCancelled = false

    var waitingCount: Int { waiters.count }
    func markFinished(cancelled: Bool) { finished = true; bodyWasCancelled = cancelled }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
