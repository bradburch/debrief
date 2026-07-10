import XCTest
import Combine
@testable import DebriefApp
import Store
import CoachingEngine

// Regression test for the nested-ObservableObject gap: AppEnvironment wraps a
// `coordinator: RecordingCoordinator` (a plain `let`, not @Published), so
// SwiftUI views observing AppEnvironment never see coordinator's own
// @Published changes (phase, micLevel, systemLevel, streamWarning) unless
// AppEnvironment forwards coordinator.objectWillChange into its own.
@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testCoordinatorPhaseChangeForwardsToEnvironmentObjectWillChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.inMemory()

        // Built exactly the way RecordingCoordinatorTests.makeCoordinator does.
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let coaching = CoachingService(db: db, prompts: prompts, llm: OKStubLLM())
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: coaching,
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root,
            chunkDuration: 1.0)

        let env = AppEnvironment(db: db, prompts: prompts, coaching: coaching, coordinator: coordinator)

        var fired = false
        let cancellable = env.objectWillChange.sink { _ in fired = true }
        defer { cancellable.cancel() }

        await coordinator.startRecording()

        XCTAssertTrue(
            fired,
            "AppEnvironment.objectWillChange should fire when the nested coordinator's @Published phase changes")
    }

    func testResolveLLMDispatchesOnProvider() {
        let d = UserDefaults.standard
        defer {
            d.removeObject(forKey: "coachingProvider")
            d.removeObject(forKey: "openAICompatBaseURL")
            d.removeObject(forKey: "openAICompatModel")
        }
        d.set("openai_compat", forKey: "coachingProvider")
        d.set("http://localhost:1234/v1", forKey: "openAICompatBaseURL")
        d.set("qwen2.5:14b", forKey: "openAICompatModel")
        XCTAssertTrue(AppEnvironment.resolveLLM() is OpenAICompatibleClient)

        d.set("anthropic", forKey: "coachingProvider")
        XCTAssertTrue(AppEnvironment.resolveLLM() is AnthropicClient)

        d.removeObject(forKey: "coachingProvider")  // default: anthropic
        XCTAssertTrue(AppEnvironment.resolveLLM() is AnthropicClient)
    }
}
