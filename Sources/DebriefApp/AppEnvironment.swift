import Foundation
import SwiftUI
import Combine
import Store
import Transcriber
import CoachingEngine
import CaptureKit
import os

private let anthropicKeyName = "anthropic-api-key"
private let logger = Logger(subsystem: "com.debrief.app", category: "environment")

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
    /// Grading criteria for the interview being recorded, pre-filled from a planned call.
    /// Cleared with company/notes on stop. It reaches `SessionMetadata`, and through it the
    /// session row at insert time — which is what puts it in front of the FIRST debrief.
    @Published var recordCriteria = ""

    /// Interviews read from the calendar hand-off file, offered as pre-fills when
    /// starting a recording. Empty is the normal case, not an error.
    @Published var upcoming: [UpcomingInterview] = []

    /// Calls the user planned ahead of time (Store's `plannedCall` table), offered in the
    /// same pre-fill menu as the calendar entries and shown as a small upcoming list.
    @Published private(set) var plannedCalls: [PlannedCall] = []

    /// The planned call whose metadata is currently in the stop-form, if any. Consumed at
    /// stop: the row is deleted only once its finalize has actually produced a session id.
    /// Not published — nothing renders it, and it must not survive a stop. Readable (not
    /// writable) inside the module so tests can assert on the claim itself: every way of
    /// releasing it is invisible from the outside until a stop happens.
    private(set) var appliedPlannedCallId: Int64?

    /// The "Plan a call" sheet's draft, presented by MainWindow. Lives here rather than as
    /// view @State because the menu-bar popover opens it too, and a `MenuBarExtra` window
    /// cannot reliably present a sheet of its own — it opens the main window instead.
    @Published var planningCall: PlannedCallDraft?

    func refreshPlannedCalls() { plannedCalls = (try? db.plannedCalls()) ?? [] }

    /// Creates or updates a planned call from the sheet's draft, then refreshes the list.
    ///
    /// An update that matches no row means the plan was consumed by a finalize while its
    /// editor was open — which is not rare, since the sheet is modal to the window and a call
    /// can end at any time. Dropping the edit there would silently discard whatever was just
    /// typed, so the draft is re-inserted as a new plan instead: a duplicate row is trivially
    /// deletable, lost typing is not recoverable.
    func savePlannedCall(_ draft: PlannedCallDraft) {
        let plan = draft.plannedCall
        do {
            if try plan.id == nil || !db.updatePlannedCall(plan) {
                var fresh = plan
                fresh.id = nil
                _ = try db.insertPlannedCall(fresh)
            }
        } catch {
            logger.error("could not save planned call: \(error.localizedDescription, privacy: .public)")
        }
        refreshPlannedCalls()
    }

    func deletePlannedCall(id: Int64) {
        try? db.deletePlannedCall(id: id)
        if appliedPlannedCallId == id { appliedPlannedCallId = nil }
        refreshPlannedCalls()
    }

    /// Undo for a pre-fill. Applying a plan is otherwise a one-way latch: it arms a rubric
    /// this interview will be graded on and marks a row for deletion at stop, and until this
    /// existed the only exit from a mis-click mid-call was to record the wrong plan's
    /// criteria and lose that plan. Leaves company/round/notes alone — those are visibly
    /// editable in the form; the criteria and the claim are the invisible half.
    func clearAppliedPlan() {
        recordCriteria = ""
        appliedPlannedCallId = nil
    }

    /// Prefers EventKit (live macOS Calendar, including a synced Google account) over the
    /// `upcoming.json` hand-off, falling back to the file when the calendar isn't
    /// authorized, isn't configured (no `interviewCalendarID` in Settings), or is simply
    /// empty right now — so an unconfigured install behaves exactly as before.
    ///
    /// Synchronous end to end: `CalendarEvents.upcoming(calendarID:...)` and
    /// `EKEventStore.events(matching:)` never await, which matters because this must run
    /// before `startRecording`'s first `await` so the pre-fill list is ready before the
    /// form renders (see the comment on `startRecording`). Do not add an `await` here.
    func refreshUpcoming() {
        let calendarID = UserDefaults.standard.string(forKey: "interviewCalendarID") ?? ""
        if CalendarEvents.isAuthorized, !calendarID.isEmpty {
            let knownRoundTypes = prompts.availableRoundTypes().map(\.rawValue)
            let fromCalendar = CalendarEvents.shared.upcoming(calendarID: calendarID,
                                                               knownRoundTypes: knownRoundTypes)
            if !fromCalendar.isEmpty {
                upcoming = fromCalendar
                return
            }
        }
        upcoming = UpcomingInterviews.load()
    }

    /// Pre-fills the stop-form fields from a scheduled interview. The round type is
    /// adopted only if the prompt store has an overlay for it — RoundType accepts any
    /// string, but the Picker binds by tag, so an unknown value would blank the control.
    func apply(_ item: UpcomingInterview) {
        recordCompany = item.company
        recordNotes = item.notes ?? ""
        recordCriteria = ""
        appliedPlannedCallId = nil
        if let raw = item.roundType {
            let candidate = RoundType(rawValue: raw)
            if prompts.availableRoundTypes().contains(candidate) {
                recordRoundType = candidate
            }
        }
    }

    /// Pre-fills the stop-form from a planned call, and remembers which plan it came from so
    /// the row can be consumed once the recording has actually become a session.
    ///
    /// Unlike the calendar path this adopts the round type unconditionally: it was picked
    /// from `availableRoundTypes()` in the sheet, so it is known to have an overlay — and
    /// keeping a stale one would silently grade the interview on the wrong rubric.
    func apply(_ plan: PlannedCall) {
        recordCompany = plan.companyName
        recordRoundType = plan.roundType
        recordNotes = Self.contextNotes(role: plan.role, notes: plan.notes)
        recordCriteria = plan.customInstructions
        appliedPlannedCallId = plan.id
    }

    /// Folds the role into the notes the debrief reads, rather than adding a session column
    /// for it: the LLM needs to know what job the interview was for, and nothing queries it.
    /// Kept pure and static so both pre-fill surfaces (stop-form and recovery) fold it the
    /// same way, and so the empty cases are testable without driving SwiftUI.
    static func contextNotes(role: String, notes: String) -> String {
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty else { return notes }
        return notes.isEmpty ? "Role: \(role)" : "Role: \(role) — \(notes)"
    }

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

    func clearRecordMetadata() { recordCompany = ""; recordNotes = ""; recordCriteria = "" }

    /// Single stop path shared by the two Stop buttons and call-end auto-stop.
    ///
    /// The form is read and cleared *before* the await, not after: stopping now takes as long
    /// as the recorders and the last in-flight decode, and the next interview can be started
    /// and typed into during that window. Clearing afterwards wiped the company the user had
    /// just entered for the new recording.
    func stopAndDebrief() async {
        let name = recordCompany.isEmpty ? "Unknown" : recordCompany
        let metadata = SessionMetadata(company: name, roundType: recordRoundType,
                                       notes: recordNotes, customInstructions: recordCriteria)
        // Read with the rest of the form and cleared before the await, for the same reason:
        // the next interview can be started and pre-filled during the stop, and it must not
        // inherit — or lose — this one's plan.
        let plannedCallId = appliedPlannedCallId
        appliedPlannedCallId = nil
        clearRecordMetadata()
        let job = await coordinator.stopAndFinalize(metadata: metadata)
        consumePlan(plannedCallId, after: job)
    }

    /// Deletes a planned call once its recording has actually become a session — never
    /// before. `stopAndFinalize` returning only means the audio is on disk; the finalize
    /// behind it can still fail (no speech transcribed, and `runFinalize` then deletes the
    /// session row it had inserted). Consuming the plan at stop would throw away the
    /// company, round type and grading criteria for a call that still needs recovering.
    ///
    /// Runs as a detached follow-up rather than blocking the caller: stopping is deliberately
    /// non-blocking so the next interview can start while this one is transcribed.
    /// The job lookup inside `awaitFinalize` is why this Task is started at stop time and not
    /// later: a *dismissed* job is unknown to the coordinator and reports nil. Dismissal
    /// requires a finished job and a click, both on the main actor, long after this Task has
    /// been enqueued — and if it ever did lose the race, the plan is kept, not wrongly eaten.
    private func consumePlan(_ id: Int64?, after job: UUID?) {
        guard let id, let job else { return }
        planConsumptions.append(Task { [weak self] in
            guard let self, await self.coordinator.awaitFinalize(job) != nil else { return }
            self.deletePlannedCall(id: id)
        })
    }

    /// Every consume follow-up in flight, not just the newest. Kept at all so tests can await
    /// the *decision*: an assertion that a plan was NOT deleted passes vacuously whenever the
    /// task simply hasn't run yet.
    ///
    /// An array rather than a single `Task?` because finalizes overlap by design — stop
    /// interview A, start B, stop B. Be aware this is **not** pinned by a test, and can't
    /// easily be: jobs drain through one serial chain, so consumes resolve in enqueue order
    /// and awaiting only the newest happens to await the rest as a side effect. That is a
    /// coincidence of the current queue, not a contract — and the cost of relying on it is a
    /// plan that is never deleted.
    private var planConsumptions: [Task<Void, Never>] = []

    /// Drains and awaits them all, re-checking afterwards — a consume that finishes can be
    /// followed by another appended while we were suspended.
    func awaitPlanConsumption() async {
        while !planConsumptions.isEmpty {
            let pending = planConsumptions
            planConsumptions = []
            for task in pending { await task.value }
        }
    }

    /// Single start path shared by the two Record buttons and the notification's
    /// Record action; clears the call-detected notification so it can't be
    /// clicked again mid-recording. Refreshes `upcoming` here — not at each call
    /// site — so all three paths (menu-bar button, in-window button, call-detected
    /// notification) populate the same array, not just whichever caller remembered
    /// to ask. That array feeds the "From calendar" menu rendered by
    /// `RecordingControls`, which both MenuBarView and MainWindow embed, so the
    /// menu itself is shown consistently in whichever surface is visible — this
    /// refresh alone does not make a menu appear anywhere it isn't already wired
    /// up. Must run before any `await` so the list is populated by the time the
    /// UI renders the recording state.
    func startRecording() async {
        refreshUpcoming()
        refreshPlannedCalls()
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
        // A finished job may have consumed a recoverable directory (or failed and kept one),
        // and there is no longer a phase returning to .idle to hang that rescan off.
        //
        // `receive(on:)` is load-bearing, not tidiness: @Published delivers synchronously
        // *inside* the mutation, which happens while runFinalize is still on the stack — its
        // `defer` has not released the directory claim yet, so a rescan there would still see
        // the dir as active and drop it. A failed finalize would then keep telling the user to
        // discard its audio from a recovery prompt that no longer lists it.
        coordinator.$finalizeCompletions.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRecoverables() }.store(in: &cancellables)
        // Launch-time reclaim of debriefs whose process died mid-call. `running` is excluded
        // from every sweep, so without this they would never be retried. Safe here because
        // nothing in this process can be coaching yet.
        _ = try? db.resetRunningCoaching()
        refreshRecoverables()
        refreshPlannedCalls()
        startTimers()
    }

    /// Directories a crashed launch left behind, minus the ones this launch is already using.
    /// Two filters, and they answer different questions: `activeDirs` is the coordinator's
    /// authority on what is claimed *right now*, and the manifest's session id catches a dir
    /// whose transcript already landed in a *previous* launch — recovering that would insert
    /// the same interview twice.
    ///
    /// The second filter asks whether that session has a *transcript*, not whether the row
    /// exists: a crash between the session insert and the segment insert leaves an empty row,
    /// and treating that as "already recovered" would hide the only remaining copy of the
    /// interview — the audio — behind a row the coaching sweeps skip for having no transcript.
    func refreshRecoverables() {
        let active = coordinator.activeDirs
        recoverableSessions = RecordingStore.unfinalizedSessions(root: recordingsRoot).filter { dir in
            guard !active.contains(dir.lastPathComponent) else { return false }
            guard let id = RecordingStore.readManifest(in: dir)?.sessionId else { return true }
            return (try? db.sessionHasTranscript(id: id)) != true
        }
    }

    /// Re-transcribes and persists an orphaned session directory (left behind by a
    /// crash) via the coordinator's finalizeFromDisk. Returns once the job is queued and
    /// the directory claimed — the rescan below drops it from the banner immediately, and
    /// the coordinator's completion signal rescans again when the job settles.
    /// `plannedCallId` is set when the recovery prompt was pre-filled from a planned call —
    /// a crashed session's plan is still in the table, and recovering it consumes the plan on
    /// exactly the same terms as a live stop does (only if a session id comes back).
    func recover(_ dir: URL, metadata: SessionMetadata, plannedCallId: Int64? = nil) async {
        let started = RecordingStore.readManifest(in: dir)?.startedAt ?? Date()
        let job = coordinator.finalizeFromDisk(dir: dir, startedAt: started, metadata: metadata)
        consumePlan(plannedCallId, after: job)
        refreshRecoverables()
    }

    func discard(_ dir: URL) {
        try? RecordingStore.deleteSession(at: dir)
        refreshRecoverables()
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
        // Subscription-backed path: shells out to the Claude Code CLI instead of billing an
        // API key. Falls back to the Anthropic client when the binary isn't found, so a
        // missing or moved CLI degrades to "needs an API key" rather than failing every
        // debrief with a spawn error.
        if d.string(forKey: "coachingProvider") == "claude_cli",
           let cli = ClaudeCodeCLIClient.locate(extraPath: d.string(forKey: "claudeCLIPath")) {
            return ClaudeCodeCLIClient(executable: cli,
                                       model: d.string(forKey: "claudeCLIModel").flatMap {
                                           $0.isEmpty ? nil : $0
                                       } ?? "claude-opus-5")
        }
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
            // Lets applicationShouldTerminate see in-flight finalize jobs; see AppDelegate.
            AppDelegate.environment = env
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
            // Keyed on recording state alone: an earlier session still finalizing no longer
            // suppresses this alert, which closes the documented gap where a call starting
            // during finalize was never offered (the detector is already inCall by the time
            // finalize ends, so it never re-fired).
            if case .idle = coordinator.recordingPhase { alerts?.callDetected() }
        case .callLikelyEnded:
            callDetected = false
            alerts?.clear()
            if case .recording = coordinator.recordingPhase { await stopAndDebrief() }
        }
    }
}
