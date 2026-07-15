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
    // 5s start confirmation (was 10) so a browser-tab Meet — which has no meeting-app signal
    // to skip the window — alerts in ~6-8s instead of ~20s. End confirmation stays at 10s:
    // it's the tolerance for a transient mic-free blip mid-call, and firing early would
    // truncate the recording. Zoom/Teams still start instantly (meeting app skips the window).
    private var detector = CallDetector(confirmation: 5, endConfirmation: 10)
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

    // nonisolated so the Keychain read can run off the main thread — a synchronous
    // SecItemCopyMatching can block on the keychain-auth dialog and must never do so
    // on the launch main thread (it would hang the whole app before detection starts).
    nonisolated static func resolveAPIKey() -> String {
        KeychainStore.read(key: anthropicKeychainKey)
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    nonisolated static func resolveModel() -> String {
        UserDefaults.standard.string(forKey: "coachingModel") ?? AnthropicClient.defaultModel
    }

    nonisolated static func resolveLLM() -> CoachingLLM {
        let d = UserDefaults.standard
        guard d.string(forKey: "coachingProvider") == "openai_compat" else {
            return AnthropicClient(apiKey: resolveAPIKey(), model: resolveModel())
        }
        let url = URL(string: d.string(forKey: "openAICompatBaseURL") ?? "") ?? URL(string: "http://localhost:11434/v1")!
        return OpenAICompatibleClient(baseURL: url,
                                      model: d.string(forKey: "openAICompatModel") ?? "",
                                      apiKey: KeychainStore.read(key: "openai-compat-api-key") ?? "")
    }

    /// Resolve off the main thread — resolveLLM() reads the API key from the Keychain, which
    /// can block on the auth dialog; doing it on the main actor would hang the Settings UI.
    func rebuildCoaching() {
        Task.detached { [self] in
            let llm = Self.resolveLLM()
            await MainActor.run { self.applyLLM(llm) }
        }
    }

    /// Swaps in a resolved coaching LLM. Kept separate from resolution so the initial
    /// (Keychain-reading) resolution can happen off the main thread — see live().
    func applyLLM(_ llm: CoachingLLM) {
        coaching = CoachingService(db: db, prompts: prompts, llm: llm)
        coordinator.coaching = coaching
    }

    static func live() -> AppEnvironment {
        do {
            let root = RecordingStore.appSupportRoot()
            let db = try AppDatabase.onDisk(at: root.appendingPathComponent("db/debrief.sqlite"))
            let prompts = PromptStore(directory: PromptStore.defaultDirectory())
            try prompts.ensureDefaults()
            // Start with a no-Keychain client; the real LLM is resolved off-main below so a
            // keychain-auth prompt can't hang launch. Coaching only runs long after launch
            // (post-finalize), by which point the real client has been swapped in.
            let coaching = CoachingService(db: db, prompts: prompts,
                                           llm: AnthropicClient(apiKey: "", model: resolveModel()))
            let keepAudio = UserDefaults.standard.bool(forKey: "keepAudioAfterTranscription")
            let coordinator = RecordingCoordinator(
                db: db, coaching: coaching,
                transcriber: WhisperTranscriber(model: .accurate),
                makeMicRecorder: { MicRecorder(writer: $0) },
                makeSystemRecorder: { SystemAudioRecorder(writer: $0) },
                deleteAudioOnSuccess: !keepAudio)
            // Constructing CallAlerts touches UNUserNotificationCenter, which traps when
            // run as an unbundled binary (`swift run`) — launch via the bundled
            // Debrief.app (scripts/make-app.sh) instead.
            let alerts = CallAlerts()
            let env = AppEnvironment(db: db, prompts: prompts, coaching: coaching,
                                     coordinator: coordinator, alerts: alerts)
            alerts.onRecord = { [weak env] in
                guard let env else { return }
                Task { await env.startRecording() }
            }
            // Resolve the real coaching LLM (reads the API key from the Keychain) off the
            // main thread, then swap it in. Keeps a keychain-auth dialog from freezing launch.
            Task.detached {
                let llm = resolveLLM()
                await MainActor.run { env.applyLLM(llm) }
            }
            return env
        } catch {
            fatalError("Debrief could not start: \(error)")
        }
    }

    private func startTimers() {
        detectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            // Compute the snapshot off the main actor — micInUseByOtherProcess enumerates
            // every CoreAudio process object, too heavy to run on the UI thread every 3s.
            // Only pollDetection (which touches the coordinator) needs the main actor.
            Task { let snapshot = DetectionProbes.snapshot(); await self?.pollDetection(snapshot, at: Date()) }
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
            // Known gap: a call that starts during .finalizing never re-fires the alert
            // once idle (the detector is already inCall); the menu-bar icon still shows it.
            if case .idle = coordinator.phase { alerts?.callDetected() }
        case .callLikelyEnded:
            callDetected = false
            alerts?.clear()
            if case .recording = coordinator.phase { await stopAndDebrief() }
        }
    }
}
