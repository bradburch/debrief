import XCTest
@testable import DebriefApp
import CaptureKit
import Transcriber
import Store
import CoachingEngine

/// Hands every recorder it builds back to the test, so a monitor's streams can be driven
/// and counted. The registry — not the coordinator — is what proves a monitor released its
/// devices: `isMonitoring` going false only says the coordinator forgot about them.
final class RecorderRegistry: @unchecked Sendable {
    final class Spy: StreamRecorder, @unchecked Sendable {
        var onLevel: (@Sendable (Float) -> Void)?
        let writer: WavChunkWriter?
        private let lock = NSLock()
        private var startCount = 0
        private var stopCount = 0
        var starts: Int { lock.lock(); defer { lock.unlock() }; return startCount }
        var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
        init(writer: WavChunkWriter?) { self.writer = writer }
        func start() async throws { lock.lock(); startCount += 1; lock.unlock() }
        func stop() async throws {
            lock.lock(); stopCount += 1; lock.unlock()
            try writer?.finish()
        }
    }

    private let lock = NSLock()
    private var built: [Spy] = []
    var all: [Spy] { lock.lock(); defer { lock.unlock() }; return built }

    func make(writer: WavChunkWriter?) -> StreamRecorder {
        let spy = Spy(writer: writer)
        lock.lock(); built.append(spy); lock.unlock()
        return spy
    }
}

@MainActor
final class LevelMonitorTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCoordinator(root: URL, registry: RecorderRegistry) throws -> RecordingCoordinator {
        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        return RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { registry.make(writer: $0) },
            makeSystemRecorder: { registry.make(writer: $0) },
            recordingsRoot: root,
            chunkDuration: 1.0)
    }

    /// Polls a main-actor condition: monitor levels arrive through a `Task { @MainActor }`
    /// hop off the recorder's callback, so they are not visible on the next line.
    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), description)
    }

    /// The feature: meters read live while idle, so a broken capture path is visible
    /// *before* an interview rather than after it.
    func testMonitorDrivesLevelsWhileIdle() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)

        XCTAssertFalse(coordinator.isMonitoring)
        await coordinator.startMonitoring()

        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertEqual(registry.all.count, 2, "monitoring opens exactly one mic and one system stream")
        XCTAssertEqual(registry.all.map(\.starts), [1, 1])

        registry.all[0].onLevel?(0.4)
        registry.all[1].onLevel?(0.2)
        try await waitUntil("mic level reaches the meter while idle") { coordinator.micLevel == 0.4 }
        try await waitUntil("system level reaches the meter while idle") { coordinator.systemLevel == 0.2 }
    }

    /// A monitor writes nothing, so it must never leave a session directory behind. One
    /// under the recordings root would be read back by `unfinalizedSessions()` as a crashed
    /// interview and offered for recovery — a phantom prompt for a call that never happened.
    func testMonitoringCreatesNoSessionDirectory() async throws {
        let root = try makeRoot()
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: root, registry: registry)

        await coordinator.startMonitoring()
        XCTAssertTrue(registry.all.allSatisfy { $0.writer == nil }, "a monitor is built with no writer")
        await coordinator.stopMonitoring()

        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(entries, [], "monitoring left something on disk: \(entries)")
    }

    /// The privacy contract behind the "only while the popover is open" choice: stopping
    /// releases the devices for real, and a callback already in flight cannot leave a stale
    /// reading frozen on a meter nothing is feeding.
    func testStopMonitoringReleasesDevicesAndClearsStaleLevels() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)

        await coordinator.startMonitoring()
        let opened = registry.all
        registry.all[0].onLevel?(0.9)
        try await waitUntil("level lands before the stop") { coordinator.micLevel == 0.9 }

        await coordinator.stopMonitoring()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertEqual(opened.map(\.stops), [1, 1], "both streams released")
        XCTAssertEqual(coordinator.micLevel, 0)
        XCTAssertEqual(coordinator.systemLevel, 0)

        // A buffer that was already in flight when the popover closed.
        opened[0].onLevel?(0.7)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.micLevel, 0, "a stale monitor callback moved a meter nothing is feeding")
    }

    /// The race the popover cannot win on its own: pressing Record dismisses the popover, so
    /// `onDisappear` and `startRecording` run concurrently. The monitor holds the same input
    /// device and process tap the real recorders are about to open, so the release has to
    /// happen inside `startRecording` rather than being left to the view.
    func testStartRecordingReleasesTheMonitorFirst() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)

        await coordinator.startMonitoring()
        let monitorStreams = registry.all
        XCTAssertEqual(monitorStreams.count, 2)

        await coordinator.startRecording()

        XCTAssertFalse(coordinator.isMonitoring, "a recording must not run alongside the monitor")
        XCTAssertEqual(monitorStreams.map(\.stops), [1, 1],
                       "the monitor still held the mic and the tap when the recorders opened")
        XCTAssertEqual(registry.all.count, 4, "the recording opens its own pair")
        if case .recording = coordinator.recordingPhase {} else {
            XCTFail("expected .recording, got \(coordinator.recordingPhase)")
        }
    }

    /// Monitoring is a diagnostic. A refused mic must leave the meters dark, never produce
    /// the `.failed` state a real start does — opening the popover would otherwise report a
    /// recording failure for a recording nobody asked for.
    func testMonitorStartFailureDoesNotFailTheRecordingPhase() async throws {
        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { _ in FailingStartRecorder() },
            makeSystemRecorder: { _ in FailingStartRecorder() },
            recordingsRoot: try makeRoot(),
            chunkDuration: 1.0)

        await coordinator.startMonitoring()

        XCTAssertEqual(coordinator.recordingPhase, .idle)
        XCTAssertEqual(coordinator.micLevel, 0)
    }

    /// Reopening the popover repeatedly must not stack streams: each open would otherwise
    /// leave the previous pair capturing with nothing holding a reference to it.
    func testStartMonitoringIsIdempotent() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)

        await coordinator.startMonitoring()
        await coordinator.startMonitoring()
        await coordinator.startMonitoring()

        XCTAssertEqual(registry.all.count, 2, "a second open built another pair of recorders")
    }
}
