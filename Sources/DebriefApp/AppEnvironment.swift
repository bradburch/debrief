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
    // Stop-form fields shared by the menu-bar popover and the in-window recording bar,
    // so metadata typed in one surface isn't lost when the recording is stopped from the
    // other (both bind to these instead of keeping private @State). roundType stays sticky
    // across recordings; company/notes are cleared on stop.
    @Published var recordCompany = ""
    @Published var recordRoundType: RoundType = .behavioral
    @Published var recordNotes = ""

    func clearRecordMetadata() { recordCompany = ""; recordNotes = "" }

    /// Single stop path shared by the two Stop buttons and call-end auto-stop.
    func stopAndDebrief() async {
        let name = recordCompany.isEmpty ? "Unknown" : recordCompany
        _ = await coordinator.stopAndFinalize(
            metadata: .init(company: name, roundType: recordRoundType, notes: recordNotes))
        clearRecordMetadata()
    }

    /// Single start path shared by the two Record buttons and the notification's
    /// Record action; clears the call-detected notification so it can't be
    /// clicked again mid-recording.
    func startRecording() async {
        alerts?.clear()
        await coordinator.startRecording()
    }

    private let alerts: CallAlerting?
    private var detector = CallDetector()
    private var detectTimer: Timer?
    private var healthTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(db: AppDatabase, prompts: PromptStore, coaching: CoachingService, coordinator: RecordingCoordinator, alerts: CallAlerting? = nil) {
        self.db = db
        self.prompts = prompts
        self.coaching = coaching
        self.coordinator = coordinator
        self.alerts = alerts
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
        UserDefaults.standard.string(forKey: "coachingModel") ?? AnthropicClient.defaultModel
    }

    static func resolveLLM() -> CoachingLLM {
        let d = UserDefaults.standard
        guard d.string(forKey: "coachingProvider") == "openai_compat" else {
            return AnthropicClient(apiKey: resolveAPIKey(), model: resolveModel())
        }
        let url = URL(string: d.string(forKey: "openAICompatBaseURL") ?? "") ?? URL(string: "http://localhost:11434/v1")!
        return OpenAICompatibleClient(baseURL: url,
                                      model: d.string(forKey: "openAICompatModel") ?? "",
                                      apiKey: KeychainStore.read(key: "openai-compat-api-key") ?? "")
    }

    func rebuildCoaching() {
        coaching = CoachingService(db: db, prompts: prompts, llm: Self.resolveLLM())
        coordinator.coaching = coaching
    }

    static func live() -> AppEnvironment {
        do {
            let root = RecordingStore.appSupportRoot()
            let db = try AppDatabase.onDisk(at: root.appendingPathComponent("db/debrief.sqlite"))
            let prompts = PromptStore(directory: PromptStore.defaultDirectory())
            try prompts.ensureDefaults()
            let coaching = CoachingService(db: db, prompts: prompts, llm: resolveLLM())
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
            Task { @MainActor in await self?.pollDetection(DetectionProbes.snapshot(), at: Date()) }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.coordinator.checkStreamHealth(now: Date()) }
        }
    }

    /// Polls in every phase: the mic probe excludes our own capture, so detection
    /// stays meaningful while recording — that's what lets a call ending end the
    /// recording. Internal + parameterized so tests can inject snapshots/clock.
    func pollDetection(_ snapshot: DetectionSnapshot, at now: Date) async {
        guard let event = detector.ingest(snapshot, at: now) else { return }
        switch event {
        case .callLikelyStarted:
            callDetected = true
            if case .idle = coordinator.phase { alerts?.callDetected() }
        case .callLikelyEnded:
            callDetected = false
            alerts?.clear()
            if case .recording = coordinator.phase { await stopAndDebrief() }
        }
    }
}
