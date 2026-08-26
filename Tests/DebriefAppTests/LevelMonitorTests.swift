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

/// Parks inside `start()`, so a test can hold `startRecording` in the window where it has
/// already claimed `recordingPhase` but has not yet assigned `live`.
final class GatedStartRecorder: StreamRecorder, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func start() async throws { await gate.wait("start") }
    func stop() async throws {}
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

    /// Builds a coordinator whose two streams start (or refuse) independently.
    private func makeCoordinator(root: URL,
                                 mic: @escaping (WavChunkWriter?) -> StreamRecorder,
                                 sys: @escaping (WavChunkWriter?) -> StreamRecorder)
        throws -> RecordingCoordinator {
        let db = try AppDatabase.inMemory()
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        return RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: mic,
            makeSystemRecorder: sys,
            recordingsRoot: root,
            chunkDuration: 1.0)
    }

    /// Monitoring is a diagnostic. A refused mic must leave the meters dark, never produce
    /// the `.failed` state a real start does — opening the popover would otherwise report a
    /// recording failure for a recording nobody asked for.
    ///
    /// It must also **drop the claim**: `isMonitoring` is what the popover asks in order to
    /// explain itself, so a monitor left holding two dead streams reports a working meter
    /// and suppresses the message that says otherwise.
    func testMonitorStartFailureDropsTheClaimAndExplainsItself() async throws {
        let coordinator = try makeCoordinator(root: try makeRoot(),
                                              mic: { _ in FailingStartRecorder() },
                                              sys: { _ in FailingStartRecorder() })

        await coordinator.startMonitoring()

        XCTAssertEqual(coordinator.recordingPhase, .idle)
        XCTAssertEqual(coordinator.micLevel, 0)
        XCTAssertFalse(coordinator.isMonitoring,
                       "a monitor of two dead streams still reports as monitoring")
        XCTAssertEqual(coordinator.monitorFailure,
                       "Levels unavailable — check Microphone and system-audio permissions.")
    }

    /// A refused microphone must not blind the system-audio meter as well. They are separate
    /// permissions, and "Them" is the half worth protecting: a tap that runs and delivers
    /// digital silence is the capture failure this surface exists to make visible.
    func testRefusedMicStillOpensTheSystemMeter() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(),
                                              mic: { _ in FailingStartRecorder() },
                                              sys: { registry.make(writer: $0) })

        await coordinator.startMonitoring()

        XCTAssertTrue(coordinator.isMonitoring, "the system meter still opened")
        XCTAssertEqual(registry.all.count, 1)
        XCTAssertEqual(registry.all[0].starts, 1, "the system stream was never started")
        XCTAssertEqual(coordinator.monitorFailure, "Mic level unavailable — check Microphone permission.")

        registry.all[0].onLevel?(0.6)
        try await waitUntil("the system meter is live despite the refused mic") {
            coordinator.systemLevel == 0.6
        }
    }

    /// The converse, and the one that matters most: a working mic beside a refused tap must
    /// say so, rather than leaving a flat "Them" that reads exactly like a silent call.
    func testRefusedSystemTapIsNamedSeparately() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(),
                                              mic: { registry.make(writer: $0) },
                                              sys: { _ in FailingStartRecorder() })

        await coordinator.startMonitoring()

        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertEqual(coordinator.monitorFailure,
                       "System-audio level unavailable — check audio-capture permission.")
    }

    /// The window the `.recording` guard actually exists for, and the one the popover's new
    /// 1s tick made reachable: between `startRecording` claiming the phase and assigning
    /// `live`, it awaits the monitor's release and then the recorders' starts (the mic's
    /// awaits a TCC prompt). Throughout that stretch `recordingPhase` is `.recording` while
    /// `live` is still nil, so the `live == nil` guard alone lets a tick straight through to
    /// open a monitor pair on the devices the real recorders are opening right now.
    ///
    /// Deleting the `.recording` check must fail this test; the `live`-based test below
    /// passes without it, which is what made the guard look redundant.
    func testMonitoringStaysOffWhileARecordingIsStillStarting() async throws {
        let gate = Gate()
        await gate.hold("start")
        let registry = RecorderRegistry()
        // Only the *recording* mic is gated (it gets a real writer); the monitor's streams
        // (nil writer) open instantly. So if the guard is removed the monitor opens cleanly
        // and the assertion below fails on its own terms, rather than the test deadlocking
        // on a gate the monitor was never meant to reach.
        let coordinator = try makeCoordinator(
            root: try makeRoot(),
            mic: { writer in
                writer == nil ? registry.make(writer: writer) : GatedStartRecorder(gate: gate)
            },
            sys: { registry.make(writer: $0) })

        let recording = Task { await coordinator.startRecording() }
        try await waitUntil("startRecording claimed the phase") {
            if case .recording = coordinator.recordingPhase { return true }
            return false
        }
        XCTAssertFalse(coordinator.isMonitoring)

        // The popover's tick, landing mid-start.
        await coordinator.startMonitoring()

        XCTAssertFalse(coordinator.isMonitoring,
                       "a tick opened a monitor while the recording was still starting")
        await gate.open()
        await recording.value
    }

    /// The popover keeps calling `startMonitoring` while it is open, which is what re-arms
    /// the meters after a recording started from inside it. While the recording still owns
    /// the devices that call must stay a no-op.
    func testMonitoringStaysOffWhileARecordingOwnsTheDevices() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)

        await coordinator.startRecording()
        let duringRecording = registry.all.count

        await coordinator.startMonitoring()
        await coordinator.startMonitoring()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertEqual(registry.all.count, duringRecording,
                       "the popover's poll opened streams alongside a live recording")
    }

    /// A failed attempt must not leave its message stranded on screen. `startRecording`
    /// calls `stopMonitoring`, and the "nothing opened" path has already dropped the claim —
    /// so an early return there leaves the popover showing "Levels unavailable" underneath a
    /// live recording timer and two working meters, for the whole interview.
    func testFailedMonitorMessageIsClearedWhenARecordingTakesOver() async throws {
        let registry = RecorderRegistry()
        var monitorAttempted = false
        let coordinator = try makeCoordinator(
            root: try makeRoot(),
            // Refuses for the monitor (nil writer), succeeds for the real recording.
            mic: { writer in
                if writer == nil { monitorAttempted = true; return FailingStartRecorder() }
                return registry.make(writer: writer)
            },
            sys: { writer in writer == nil ? FailingStartRecorder() : registry.make(writer: writer) })

        await coordinator.startMonitoring()
        XCTAssertTrue(monitorAttempted)
        XCTAssertNotNil(coordinator.monitorFailure)

        await coordinator.startRecording()

        XCTAssertNil(coordinator.monitorFailure,
                     "the popover would show a permissions warning during a working recording")
    }

    /// One attempt per popover open. The tick that re-arms the meters must not turn into an
    /// unbounded retry, constructing recorders and attempting a real device open every
    /// second on the machine that is already misconfigured.
    func testAFailedAttemptIsNotRetriedOnEveryTick() async throws {
        let attempts = StopSpy()
        let coordinator = try makeCoordinator(
            root: try makeRoot(),
            mic: { _ in attempts.record(); return FailingStartRecorder() },
            sys: { _ in FailingStartRecorder() })

        for _ in 0..<5 { await coordinator.startMonitoring() }

        XCTAssertEqual(attempts.stops, 1, "the popover's tick retried the device open every second")
        XCTAssertNotNil(coordinator.monitorFailure, "the message must survive the ticks that follow")

        // Closing the popover retires the attempt, so reopening re-checks — which is how a
        // permission granted in System Settings takes effect.
        await coordinator.stopMonitoring()
        XCTAssertNil(coordinator.monitorFailure)
        await coordinator.startMonitoring()
        XCTAssertEqual(attempts.stops, 2, "reopening the popover must try again")
    }

    /// A process tap delivers nothing while the output is idle, so without expiry the "Them"
    /// bar latches at its last reading and reports audio that stopped playing.
    func testStaleMeterExpiresInsteadOfLatching() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)
        await coordinator.startMonitoring()

        registry.all[1].onLevel?(0.8)
        try await waitUntil("the system meter picked up the level") { coordinator.systemLevel == 0.8 }

        coordinator.expireStaleLevels(now: Date().addingTimeInterval(0.1))
        XCTAssertEqual(coordinator.systemLevel, 0.8, "a fresh reading must not be expired")

        coordinator.expireStaleLevels(now: Date().addingTimeInterval(5))
        XCTAssertEqual(coordinator.systemLevel, 0, "the meter latched after the tap went quiet")
    }

    /// The same latch, on the recording path — where it matters most. Mid-interview is
    /// exactly when someone glances at "Them" to check the other side is still being
    /// captured, and a bar frozen at its last reading answers yes when nothing has arrived
    /// for a while. `checkStreamHealth` only speaks up after 60s, a much later question.
    func testRecordingMeterExpiresWhenTheTapGoesQuiet() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)
        await coordinator.startRecording()

        // registry.all is [mic, sys] for the recording's own pair.
        registry.all[1].onLevel?(0.7)
        try await waitUntil("the recording's system meter picked up the level") {
            coordinator.systemLevel == 0.7
        }

        coordinator.expireStaleLevels(now: Date().addingTimeInterval(0.1))
        XCTAssertEqual(coordinator.systemLevel, 0.7, "a fresh reading must not be expired")

        coordinator.expireStaleLevels(now: Date().addingTimeInterval(5))
        XCTAssertEqual(coordinator.systemLevel, 0,
                       "the recording meter latched after the tap went quiet")
    }

    /// Expiring a displayed level must not disturb `checkStreamHealth`, which answers a
    /// different question from a different field — a silent bar is not a 60s outage.
    func testExpiringAMeterDoesNotRaiseAStreamWarning() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)
        await coordinator.startRecording()

        registry.all[1].onLevel?(0.7)
        try await waitUntil("level landed") { coordinator.systemLevel == 0.7 }
        coordinator.expireStaleLevels(now: Date().addingTimeInterval(5))

        coordinator.checkStreamHealth(now: Date())
        XCTAssertNil(coordinator.streamWarning,
                     "expiring the bar was mistaken for an audio outage")
    }

    /// The mic is deliberately left alone in both phases: an AVAudioEngine tap streams
    /// continuously, so a mic reading is never stale for want of callbacks, and expiring it
    /// would only be a chance to flicker "You" to zero on a slow input device.
    func testMicMeterIsNeverExpired() async throws {
        let registry = RecorderRegistry()
        let coordinator = try makeCoordinator(root: try makeRoot(), registry: registry)
        await coordinator.startMonitoring()

        registry.all[0].onLevel?(0.5)
        try await waitUntil("mic level landed") { coordinator.micLevel == 0.5 }

        coordinator.expireStaleLevels(now: Date().addingTimeInterval(30))
        XCTAssertEqual(coordinator.micLevel, 0.5)
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
