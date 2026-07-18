import Foundation
import SwiftUI
import Combine
import Store
import Transcriber
import CoachingEngine
import CaptureKit

private let anthropicKeyName = "anthropic-api-key"

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

    // Which tab MainWindow shows. Lives here so a view can navigate to another tab —
    // PipelineView jumping to a session — without plumbing a Binding through the hierarchy.
    @Published var selectedTab: MainTab? = .sessions
    /// A session to select once SessionsView appears. Set by `revealSession`; SessionsView
    /// consumes and clears it. Needed because the tab switch rebuilds SessionsView from
    /// scratch, so the selection can't simply be handed to a live instance.
    @Published var sessionToReveal: Int64?

    /// Jump to a session from anywhere (currently the Pipeline's round cells).
    func revealSession(_ id: Int64) {
        sessionToReveal = id
        selectedTab = .sessions
    }

    // Re-coach state lives here, not in SettingsView, because MainWindow switches tabs with a
    // `switch` that DESTROYS the settings view. As view @State this progress vanished on any
    // tab switch while the run kept going — and coming back re-enabled the button, letting a
    // second concurrent run start over the same sessions. Here it survives navigation and
    // `recoachTask != nil` is a global "already running" interlock.
    @Published private(set) var recoachProgress: (done: Int, total: Int)?
    @Published private(set) var recoachOutcome: RecoachOutcome?
    private var recoachTask: Task<Void, Never>?

    var isRecoaching: Bool { recoachTask != nil }

    /// Terminal state of a re-run, so "finished clean", "finished with failures", and "you
    /// stopped it" don't collapse into one line of grey text.
    struct RecoachOutcome: Equatable {
        let text: String
        let symbol: String
        let isProblem: Bool
    }

    /// Re-coaches every past session on the current rubric, publishing progress as it goes.
    /// No-op if a run is already in flight.
    func startRecoach() {
        guard recoachTask == nil else { return }
        recoachOutcome = nil
        recoachProgress = (0, 0)
        recoachTask = Task { [weak self] in
            guard let self else { return }
            let errors = await self.coaching.recoachAll { done, total in
                self.recoachProgress = (done, total)
            }
            let total = self.recoachProgress?.total ?? 0
            let done = self.recoachProgress?.done ?? 0
            // Progress is the authority, not Task.isCancelled: cancelling after the last
            // session already finished still sets isCancelled, which reported a nonsense
            // "Stopped after 11 of 11" and swallowed the failure count.
            self.recoachOutcome = Self.outcome(total: total, failed: errors.count,
                                               cancelled: done < total, completed: done)
            self.recoachProgress = nil
            self.recoachTask = nil
        }
    }

    func cancelRecoach() { recoachTask?.cancel() }

    /// Result of the last "Export all now" / folder-picked backfill run, surfaced in Settings.
    /// nil until a batch export has completed at least once.
    @Published var exportResult: String?

    /// Exports every session with a transcript to `dir`, off the main thread (many small
    /// file writes). Publishes the outcome to `exportResult` rather than discarding it, so a
    /// failed batch (e.g. an unwritable folder) doesn't silently look like success.
    func exportAllSessions(to dir: URL) {
        let coaching = self.coaching
        Task.detached { [self] in
            let errors = coaching.exportAll(to: dir)
            await MainActor.run {
                self.exportResult = errors.isEmpty
                    ? "Export complete."
                    : "Export finished with \(errors.count) error(s) — check the folder is writable."
            }
        }
    }

    static func outcome(total: Int, failed: Int, cancelled: Bool, completed: Int) -> RecoachOutcome {
        if total == 0 {
            return .init(text: "No sessions with transcripts to re-coach.", symbol: "info.circle", isProblem: false)
        }
        if cancelled {
            // Report failures too — the cancelled branch used to return first and hide them.
            let failures = failed > 0 ? " \(failed) of those failed." : ""
            return .init(text: "Stopped after \(completed) of \(total).\(failures) The rest keep their old debriefs.",
                         symbol: "stop.circle", isProblem: true)
        }
        if failed > 0 {
            return .init(text: "\(total - failed) re-coached, \(failed) failed — see the sessions list.",
                         symbol: "exclamationmark.triangle.fill", isProblem: true)
        }
        return .init(text: "Done — \(total) session\(total == 1 ? "" : "s") re-coached on the current rubric.",
                     symbol: "checkmark.circle.fill", isProblem: false)
    }

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
    private let recordingsRoot: URL
    // 5s start confirmation (was 10) so a browser-tab Meet — which has no meeting-app signal
    // to skip the window — alerts in ~6-8s instead of ~20s. End confirmation stays at 10s:
    // it's the tolerance for a transient mic-free blip mid-call, and firing early would
    // truncate the recording. Zoom/Teams still start instantly (meeting app skips the window).
    private var detector = CallDetector(confirmation: 5, endConfirmation: 10)
    private var detectTimer: Timer?
    private var healthTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(db: AppDatabase, prompts: PromptStore, coaching: CoachingService, coordinator: RecordingCoordinator, alerts: CallAlerting? = nil,
         recordingsRoot: URL = RecordingStore.recordingsRoot()) {
        self.db = db
        self.prompts = prompts
        self.coaching = coaching
        self.coordinator = coordinator
        self.alerts = alerts
        self.recordingsRoot = recordingsRoot
        // coordinator is a nested ObservableObject (a plain `let`, not @Published),
        // so its own @Published changes (phase, micLevel, systemLevel, streamWarning)
        // don't propagate to views observing AppEnvironment unless forwarded here.
        coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        recoverableSessions = RecordingStore.unfinalizedSessions(root: recordingsRoot)
        startTimers()
    }

    /// Re-transcribes and persists an orphaned session directory (left behind by a
    /// crash) via the coordinator's finalizeFromDisk, then re-scans for leftovers.
    func recover(_ dir: URL, metadata: SessionMetadata) async {
        let started = RecordingStore.readManifest(in: dir)?.startedAt ?? Date()
        _ = await coordinator.finalizeFromDisk(dir: dir, startedAt: started, metadata: metadata)
        recoverableSessions = RecordingStore.unfinalizedSessions(root: recordingsRoot)
    }

    func discard(_ dir: URL) {
        try? RecordingStore.deleteSession(at: dir)
        recoverableSessions = RecordingStore.unfinalizedSessions(root: recordingsRoot)
    }

    // nonisolated so key resolution can run off the main thread; retained defensively —
    // the key is now a cheap SecretStore file read, no longer a Keychain call that
    // could block launch on an auth dialog (see SecretStore for why we left the Keychain).
    nonisolated static func resolveAPIKey() -> String {
        SecretStore.read(key: anthropicKeyName)
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
                                      apiKey: SecretStore.read(key: "openai-compat-api-key") ?? "")
    }

    /// Resolve off the main thread. Retained defensively — the key is now a cheap SecretStore
    /// file read, no longer a Keychain call that could block the Settings UI on an auth dialog.
    func rebuildCoaching() {
        Task.detached { [self] in
            let llm = Self.resolveLLM()
            await MainActor.run { self.applyLLM(llm) }
        }
    }

    /// Swaps in a resolved coaching LLM. Kept separate from resolution so the initial
    /// (key-reading) resolution can happen off the main thread — see live().
    func applyLLM(_ llm: CoachingLLM) {
        coaching = CoachingService(db: db, prompts: prompts, llm: llm)
        coordinator.coaching = coaching
    }

    static func live() -> AppEnvironment {
        do {
            // MUST run before any store opens — it may move the DB directory.
            let loc = DataLocations.resolveAndReconcile()
            let db = try AppDatabase.onDisk(at: loc.db.appendingPathComponent("debrief.sqlite"))
            let prompts = PromptStore(directory: loc.prompts)
            try prompts.ensureDefaults()
            // Start with an empty-key client; the real LLM is resolved off-main below.
            // Coaching only runs long after launch (post-finalize), by which point the
            // real client has been swapped in.
            let coaching = CoachingService(db: db, prompts: prompts,
                                           llm: AnthropicClient(apiKey: "", model: resolveModel()))
            let keepAudio = UserDefaults.standard.bool(forKey: "keepAudioAfterTranscription")
            let coordinator = RecordingCoordinator(
                db: db, coaching: coaching,
                transcriber: WhisperTranscriber(model: .accurate),
                makeMicRecorder: { MicRecorder(writer: $0) },
                makeSystemRecorder: { SystemAudioRecorder(writer: $0) },
                recordingsRoot: loc.audio,
                deleteAudioOnSuccess: !keepAudio)
            // Constructing CallAlerts touches UNUserNotificationCenter, which traps when
            // run as an unbundled binary (`swift run`) — launch via the bundled
            // Debrief.app (scripts/make-app.sh) instead.
            let alerts = CallAlerts()
            let env = AppEnvironment(db: db, prompts: prompts, coaching: coaching,
                                     coordinator: coordinator, alerts: alerts,
                                     recordingsRoot: loc.audio)
            alerts.onRecord = { [weak env] in
                guard let env else { return }
                Task { await env.startRecording() }
            }
            // Resolve the real coaching LLM (reads the API key) off the main thread, then
            // swap it in.
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
