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

    func testPreservesSubmissionOrder() async throws {
        let queue = SerialQueue()
        let order = OrderLog()
        await withTaskGroup(of: Void.self) { group in
            // Submitted one at a time (awaiting the enqueue, not the result) so submission
            // order is defined; the queue must then run them in that order.
            for i in 0..<5 {
                group.addTask { _ = try? await queue.run { await order.append(i) } }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let values = await order.values
        XCTAssertEqual(values, [0, 1, 2, 3, 4])
    }
}

private actor OrderLog {
    var values: [Int] = []
    func append(_ i: Int) { values.append(i) }
}
