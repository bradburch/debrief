import Foundation
import SwiftUI
import Combine
import Store
import Transcriber
import CoachingEngine
import CaptureKit

private let anthropicKeychainKey = "anthropic-api-key"

@MainActor
final class AppEnvironment: ObservableObject {
    let db: AppDatabase
    let prompts: PromptStore
    @Published private(set) var coaching: CoachingService
    let coordinator: RecordingCoordinator
    @Published var callDetected = false
    @Published var recoverableSessions: [URL] = []

    private var detector = CallDetector()
    private var detectTimer: Timer?
    private var healthTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(db: AppDatabase, prompts: PromptStore, coaching: CoachingService, coordinator: RecordingCoordinator) {
        self.db = db
        self.prompts = prompts
        self.coaching = coaching
        self.coordinator = coordinator
        // coordinator is a nested ObservableObject (a plain `let`, not @Published),
        // so its own @Published changes (phase, micLevel, systemLevel, streamWarning)
        // don't propagate to views observing AppEnvironment unless forwarded here.
        coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        recoverableSessions = RecordingStore.unfinalizedSessions()
        startTimers()
    }

    /// Re-transcribes and persists an orphaned session directory (left behind by a
    /// crash) via the coordinator's finalizeFromDisk, then re-scans for leftovers.
    func recover(_ dir: URL, metadata: SessionMetadata) async {
        let started = RecordingStore.readManifest(in: dir)?.startedAt ?? Date()
        _ = await coordinator.finalizeFromDisk(dir: dir, startedAt: started, metadata: metadata)
        recoverableSessions = RecordingStore.unfinalizedSessions()
    }

    func discard(_ dir: URL) {
        try? RecordingStore.deleteSession(at: dir)
        recoverableSessions = RecordingStore.unfinalizedSessions()
    }

    static func resolveAPIKey() -> String {
        KeychainStore.read(key: anthropicKeychainKey)
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    static func resolveModel() -> String {
        UserDefaults.standard.string(forKey: "coachingModel") ?? "claude-opus-4-8"
    }

    func rebuildCoaching() {
        coaching = CoachingService(db: db, prompts: prompts,
                                   llm: AnthropicClient(apiKey: Self.resolveAPIKey(), model: Self.resolveModel()))
        coordinator.coaching = coaching
    }

    static func live() -> AppEnvironment {
        do {
            let root = RecordingStore.appSupportRoot()
            let db = try AppDatabase.onDisk(at: root.appendingPathComponent("db/debrief.sqlite"))
            let prompts = PromptStore(directory: PromptStore.defaultDirectory())
            try prompts.ensureDefaults()
            let apiKey = resolveAPIKey()
            let coaching = CoachingService(db: db, prompts: prompts,
                                           llm: AnthropicClient(apiKey: apiKey, model: resolveModel()))
            let keepAudio = UserDefaults.standard.bool(forKey: "keepAudioAfterTranscription")
            let coordinator = RecordingCoordinator(
                db: db, coaching: coaching,
                transcriber: WhisperTranscriber(model: .accurate),
                makeMicRecorder: { MicRecorder(writer: $0) },
                makeSystemRecorder: { SystemAudioRecorder(writer: $0) },
                deleteAudioOnSuccess: !keepAudio)
            return AppEnvironment(db: db, prompts: prompts, coaching: coaching, coordinator: coordinator)
        } catch {
            fatalError("Debrief could not start: \(error)")
        }
    }

    private func startTimers() {
        detectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDetection() }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.coordinator.checkStreamHealth(now: Date()) }
        }
    }

    private func pollDetection() {
        guard case .idle = coordinator.phase else { return }
        // While recording we hold the mic ourselves, so only poll when idle.
        if let event = detector.ingest(DetectionProbes.snapshot(), at: Date()) {
            switch event {
            case .callLikelyStarted: callDetected = true
            case .callLikelyEnded: callDetected = false
            }
        }
    }
}
