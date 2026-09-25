import SwiftUI
import CoachingEngine
import CaptureKit
import EventKit

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var apiKey = SecretStore.read(key: "anthropic-api-key") ?? ""
    @State private var saved = false
    @State private var saveError: String?
    @AppStorage("keepAudioAfterTranscription") private var keepAudio = false
    @State private var retryResult: String?
    @State private var confirmingRecoach = false
    @AppStorage("coachingModel") private var model = AnthropicClient.defaultModel
    @AppStorage("coachingProvider") private var provider = "anthropic"
    @AppStorage("openAICompatBaseURL") private var compatBaseURL = "http://localhost:11434/v1"
    @AppStorage("openAICompatModel") private var compatModel = ""
    @AppStorage("claudeCLIPath") private var claudeCLIPath = ""
    @AppStorage("claudeCLIModel") private var claudeCLIModel = "claude-opus-5"
    @State private var compatKey = SecretStore.read(key: "openai-compat-api-key") ?? ""
    @AppStorage("exportDirectory") private var exportDir = ""
    @State private var relaunchPrompt: RelaunchPrompt?
    @State private var relaunchError: String?
    @State private var calendarStatusText = ""
    @State private var calendarFileExists = false
    @AppStorage("interviewCalendarID") private var interviewCalendarID = ""
    @State private var calendarAuthStatus: EKAuthorizationStatus = CalendarEvents.authorizationStatus
    @State private var calendars: [(id: String, title: String)] = []
    @State private var calendarUpcomingText = ""
    private struct RelaunchPrompt: Identifiable { let id = UUID(); let dir: String }

    private let modelOptions: [(label: String, id: String)] = [
        ("Opus 4.8 — best quality (default)", "claude-opus-4-8"),
        ("Sonnet 5 — balanced", "claude-sonnet-5"),
        ("Haiku 4.5 — fastest, cheapest", "claude-haiku-4-5-20251001"),
    ]

    private var envAPIKeyPresent: Bool {
        !(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
    }

    // Gates data-location relocation: a relaunch runs DataLocations.resolveAndReconcile(),
    // which MOVES the db directory before any store reopens. A same-volume move is a safe
    // rename, but a cross-volume move is copy-then-unlink — if the OLD instance is still
    // writing (mid-recording finalize, or a background coach/recoachAll call) during that
    // window, the tail of the write can be lost or corrupted. Only allow starting a
    // relocation when nothing can be writing to the DB.
    /// A *finished* job writes nothing, so this gates on jobs still in flight rather than on
    /// the list being empty — otherwise an undismissed success would block relocation.
    private var canRelocate: Bool {
        if case .idle = env.coordinator.recordingPhase,
           !env.coordinator.hasActiveJobs, !env.isRecoaching { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    Text("Claude API (recommended)").tag("anthropic")
                    Text("Claude subscription (Claude Code CLI)").tag("claude_cli")
                    Text("Local / OpenAI-compatible").tag("openai_compat")
                }
                .onChange(of: provider) { env.rebuildCoaching() }

                if provider == "claude_cli" {
                    claudeCLISettings
                } else if provider == "anthropic" {
                    LabeledContent("API key") {
                        HStack(spacing: Spacing.s) {
                            SecureField("API key", text: $apiKey, prompt: Text("sk-ant-…"))
                                .labelsHidden()
                            Button("Save") {
                                do {
                                    if apiKey.isEmpty {
                                        try SecretStore.delete(key: "anthropic-api-key")
                                    } else {
                                        try SecretStore.save(key: "anthropic-api-key", value: apiKey)
                                    }
                                    env.rebuildCoaching()
                                    saved = true
                                    saveError = nil
                                } catch {
                                    saveError = "Could not save key: \(error.localizedDescription)"
                                    saved = false
                                }
                            }.disabled(!apiKey.isEmpty && !apiKey.hasPrefix("sk-ant-"))
                        }
                    }
                    if apiKey.isEmpty && !envAPIKeyPresent {
                        InlineMessage(text: "No API key configured — debriefs will not run.", kind: .warning)
                    } else if apiKey.isEmpty && envAPIKeyPresent {
                        InlineMessage(text: "Using ANTHROPIC_API_KEY from the environment.")
                    }
                    saveStatus
                    Picker("Model", selection: $model) {
                        ForEach(modelOptions, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .onChange(of: model) { env.rebuildCoaching() }
                } else {
                    TextField("Base URL", text: $compatBaseURL, prompt: Text("http://localhost:11434/v1"))
                        .onChange(of: compatBaseURL) { env.rebuildCoaching() }
                    TextField("Model", text: $compatModel, prompt: Text("e.g. deepseek-r1:14b"))
                        .onChange(of: compatModel) { env.rebuildCoaching() }
                    LabeledContent("API key") {
                        HStack(spacing: Spacing.s) {
                            SecureField("API key", text: $compatKey, prompt: Text("Optional, for remote providers"))
                                .labelsHidden()
                            Button("Save key") {
                                do {
                                    if compatKey.isEmpty {
                                        try SecretStore.delete(key: "openai-compat-api-key")
                                    } else {
                                        try SecretStore.save(key: "openai-compat-api-key", value: compatKey)
                                    }
                                    env.rebuildCoaching()
                                    saved = true; saveError = nil
                                } catch {
                                    saveError = "Could not save key: \(error.localizedDescription)"; saved = false
                                }
                            }
                        }
                    }
                    saveStatus
                }
            } header: {
                Text("Coaching model")
            } footer: {
                footer(providerFooter)
            }

            Section {
                Toggle("Keep raw audio after transcription", isOn: $keepAudio)
            } header: {
                Text("Audio")
            } footer: {
                footer("Takes effect after relaunching Debrief.")
            }

            Section {
                // Disabled while a finalize job is running: that job's own debrief is part of
                // what "pending" means until it lands, and a sweep started now would report a
                // confusing count for work already in flight. Gated on a re-run too, and for
                // the same reason the re-run is gated on this one: whichever sweep gets there
                // second hits `coach()`'s claim and bails, then reports the session as handled
                // when nothing of its own ran.
                LabeledContent {
                    Button("Retry pending debriefs") {
                        Task {
                            let errors = await env.coaching.retryAllPending()
                            retryResult = errors.isEmpty ? "All caught up." : "\(errors.count) failed — see sessions list."
                        }
                    }
                    .disabled(env.coordinator.hasActiveJobs || env.isRecoaching)
                } label: {
                    Text("Pending debriefs")
                    if env.coordinator.hasActiveJobs || env.isRecoaching {
                        Text(env.isRecoaching
                             ? "Re-running debriefs — try again when that finishes."
                             : "Finishing a debrief — try again in a moment.")
                    } else if let retryResult {
                        Text(retryResult)
                    }
                }
                LabeledContent {
                    HStack(spacing: Spacing.s) {
                        if env.isRecoaching { Button("Stop") { env.cancelRecoach() } }
                        // Also gated on live jobs: a sweep started now would reach a session whose
                        // finalize is coaching it, and `coach()` would (correctly) bail on it —
                        // reporting it as done on the current rubric when it hasn't been re-run.
                        Button("Re-run debriefs on current rubric") { confirmingRecoach = true }
                            .disabled(env.isRecoaching || env.coordinator.hasActiveJobs)
                    }
                } label: {
                    Text("Re-run all debriefs")
                    Text("One API call per session (~30s each). Replaces existing debrief text.")
                }
                if let progress = env.recoachProgress {
                    // Determinate: the total is known before the first call, and each session
                    // takes ~30s — an indeterminate spinner would read as a hang for minutes.
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text(progress.total == 0
                             ? "Starting…"
                             : progress.done == 0
                               ? "Starting \(progress.total) debrief\(progress.total == 1 ? "" : "s")…"
                               : "Re-coaching \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                            .font(.caption)
                    }
                    .progressViewStyle(.linear)
                }
                if let outcome = env.recoachOutcome {
                    Label(outcome.text, systemImage: outcome.symbol)
                        .font(.caption)
                        .foregroundStyle(outcome.isProblem ? Color.orange : Color.green)
                }
                LabeledContent("Prompts") {
                    Button("Open prompts folder") {
                        NSWorkspace.shared.open(PromptStore.defaultDirectory())
                    }
                }
            } header: {
                Text("Coaching")
            } footer: {
                footer("Re-running brings old debriefs onto the current prompts, so they gain an advancement verdict and compare fairly with new ones.")
            }

            InterviewTypesSection()

            Section {
                LabeledContent {
                    HStack(spacing: Spacing.s) {
                        if !exportDir.isEmpty {
                            Button("Turn off") { exportDir = "" }
                            Button("Export all now") {
                                env.exportAllSessions(to: URL(fileURLWithPath: exportDir))
                            }
                        }
                        Button("Choose export folder…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                exportDir = url.path
                                env.exportAllSessions(to: url)  // backfill existing sessions immediately
                            }
                        }
                    }
                } label: {
                    Text("Export folder")
                    Text(exportDir.isEmpty ? "Off" : exportDir)
                        .truncationMode(.middle)
                }
                if let exportResult = env.exportResult {
                    Text(exportResult).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Cowork export")
            } footer: {
                footer("Writes each debrief as a markdown file Claude Cowork can read.")
            }

            Section {
                LabeledContent("Calendar access", value: authorizationStatusText(calendarAuthStatus))
                if calendarAuthStatus == .fullAccess {
                    if calendars.isEmpty {
                        Text("No calendars found on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Interview calendar", selection: $interviewCalendarID) {
                            Text("None selected").tag("")
                            ForEach(calendars, id: \.id) { cal in
                                Text(cal.title).tag(cal.id)
                            }
                        }
                        .onChange(of: interviewCalendarID) { refreshCalendarSection() }
                        if !interviewCalendarID.isEmpty {
                            Text(calendarUpcomingText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if calendarAuthStatus == .notDetermined || calendarAuthStatus == .writeOnly {
                    LabeledContent {
                        Button("Grant calendar access") {
                            Task {
                                _ = await CalendarEvents.shared.requestAccess()
                                refreshCalendarSection()
                            }
                        }
                    } label: {
                        Text("Access")
                        Text("macOS lists every calendar on this Mac, including Google accounts added in System Settings.")
                    }
                } else {
                    // .denied or .restricted: requestFullAccessToEvents() returns false
                    // without prompting once the user has already said no, so "Grant
                    // calendar access" would be a silent no-op here. Send them to System
                    // Settings instead, same idiom as Microphone/Screen Recording below.
                    LabeledContent {
                        Button("Open Calendar settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    } label: {
                        Text("Access denied")
                        Text("Enable it in System Settings, then click Refresh.")
                    }
                }
                LabeledContent {
                    HStack(spacing: Spacing.s) {
                        Button("Reveal in Finder") { revealCalendarFile() }
                        Button("Refresh") { refreshCalendarSection() }
                    }
                } label: {
                    Text("upcoming.json fallback")
                    Text(calendarStatusText)
                }
                .help(UpcomingInterviews.fileURL().path)
            } header: {
                Text("Calendar pre-fill")
            } footer: {
                // The privacy claim stays visible: it is the reason this section is safe to use.
                footer("Read locally through macOS Calendar — no network call, no OAuth, no tokens. "
                       + "upcoming.json is used when no calendar is selected or it has nothing upcoming.")
            }

            Section {
                if !canRelocate {
                    InlineMessage(text: "Finish or stop any recording and re-coaching before changing these — the move happens on relaunch.")
                }
                locationRow("Recordings", desiredKey: "audioDirDesired", actualKey: "audioDirActual",
                            errorKey: "audioDirError", subdir: "recordings",
                            defaultPath: RecordingStore.recordingsRoot().path)
                locationRow("Database", desiredKey: "dbDirDesired", actualKey: "dbDirActual",
                            errorKey: "dbDirError", subdir: "db",
                            defaultPath: RecordingStore.appSupportRoot().appendingPathComponent("db").path)
                locationRow("Prompts", desiredKey: "promptsDirDesired", actualKey: "promptsDirActual",
                            errorKey: "promptsDirError", subdir: "prompts",
                            defaultPath: PromptStore.defaultDirectory().path)
                if let relaunchError {
                    InlineMessage(text: relaunchError, kind: .warning)
                }
            } header: {
                Text("Data locations")
            } footer: {
                footer("Changing a location moves the existing data and relaunches Debrief.")
            }

            Section {
                LabeledContent {
                    Button("Open Microphone settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                } label: {
                    Text("Microphone")
                    Text("Your side of the call")
                }
                LabeledContent {
                    Button("Open Screen Recording settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                } label: {
                    Text("System audio")
                    Text("The other side of the call")
                }
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshCalendarSection)
        .confirmationDialog("Re-run every past debrief?", isPresented: $confirmingRecoach) {
            Button("Re-run all", role: .destructive) { env.startRecoach() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing debrief text, scores, and tags are replaced with fresh ones from the current prompts. Transcripts are untouched. This makes old sessions comparable to new ones, and costs one API call per session (~30s each).")
        }
        .alert("Relaunch to move your data?", isPresented: Binding(
            get: { relaunchPrompt != nil }, set: { if !$0 { relaunchPrompt = nil } })) {
            Button("Relaunch now") { relaunch() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Debrief will move your \(relaunchPrompt?.dir.lowercased() ?? "data") to the new folder on the next launch.")
        }
    }

    /// Recomputes from disk on demand — never cached across the app's lifetime, since
    /// the file is written by an external process (Claude, via MCP) at any time.
    private func refreshCalendarStatus() {
        let url = UpcomingInterviews.fileURL()
        calendarFileExists = FileManager.default.fileExists(atPath: url.path)
        let entryCount = UpcomingInterviews.load().count
        calendarStatusText = UpcomingInterviews.statusText(fileExists: calendarFileExists, entryCount: entryCount)
    }

    private func authorizationStatusText(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "Granted"
        case .denied: return "Denied — enable in System Settings > Privacy & Security > Calendars"
        case .restricted: return "Restricted by device management"
        case .writeOnly: return "Write-only access — not enough to read events, request access again"
        case .notDetermined: return "Not yet requested"
        @unknown default: return "Unknown"
        }
    }

    /// Recomputes the calendar list and the selected calendar's upcoming count. Cheap
    /// enough to call on appear, on every refresh, and after a grant/selection change —
    /// EventKit's own store is already long-lived (`CalendarEvents.shared`).
    /// Settings for the subscription-backed path. The honest tradeoffs are stated inline
    /// rather than buried in docs: this route is measurably more expensive per debrief in
    /// tokens and is not a supported integration, so the person choosing it should see that
    /// at the moment they choose it.
    @ViewBuilder
    private var claudeCLISettings: some View {
        let located = ClaudeCodeCLIClient.locate(extraPath: claudeCLIPath)
        if let located {
            InlineMessage(text: "Using \(located.path)")
        } else {
            InlineMessage(text: "Claude Code CLI not found — debriefs fall back to the Claude API (needs a key).",
                          kind: .warning)
        }
        TextField("CLI path", text: $claudeCLIPath,
                  prompt: Text("~/.local/bin/claude"))
            .onChange(of: claudeCLIPath) { env.rebuildCoaching() }
        TextField("Model", text: $claudeCLIModel, prompt: Text("claude-opus-5"))
            .onChange(of: claudeCLIModel) { env.rebuildCoaching() }
    }

    /// Per-provider footer copy. The honest tradeoffs of the CLI path are stated where it's
    /// chosen rather than buried in docs: it is measurably more expensive per debrief in
    /// tokens and is not a supported integration.
    private var providerFooter: String {
        switch provider {
        case "claude_cli":
            return "Bills your Claude subscription instead of an API key; needs the CLI installed and signed in. "
                + "Each debrief carries ~15–20k extra tokens, rate limits can throttle re-runs, there's no JSON "
                + "schema, and a CLI update could break it — this isn't a supported integration."
        case "anthropic":
            return "The model applies to the next debrief you generate."
        default:
            return "Works with Ollama, LM Studio, or any /v1/chat/completions server (see docs/local-llm.md). "
                + "Local models give weaker coaching than Claude."
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var saveStatus: some View {
        if saved {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        }
        if let saveError { InlineMessage(text: saveError, kind: .error) }
    }

    private func refreshCalendarSection() {
        refreshCalendarStatus()
        calendarAuthStatus = CalendarEvents.authorizationStatus
        guard calendarAuthStatus == .fullAccess else {
            calendars = []
            return
        }
        calendars = CalendarEvents.shared.calendars()
        guard !interviewCalendarID.isEmpty else {
            calendarUpcomingText = ""
            return
        }
        let knownRoundTypes = env.prompts.availableRoundTypes().map(\.rawValue)
        let count = CalendarEvents.shared.upcoming(calendarID: interviewCalendarID,
                                                    knownRoundTypes: knownRoundTypes).count
        calendarUpcomingText = "\(count) upcoming interview\(count == 1 ? "" : "s") visible in this calendar."
    }

    private func revealCalendarFile() {
        let url = UpcomingInterviews.fileURL()
        if calendarFileExists {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Never select a nonexistent file — reveal the containing directory instead.
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            // Terminate only once a new instance is confirmed launched. Quitting on failure
            // would kill the only instance with nothing relaunched and the move never applied
            // (the move happens at the next launch's reconcile).
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
                else { relaunchError = "Couldn’t relaunch automatically — quit and reopen Debrief to apply the move." }
            }
        }
    }

    /// One relocatable directory. `subdir` is the canonical name appended to the picked parent.
    private func locationRow(_ title: String, desiredKey: String, actualKey: String,
                             errorKey: String, subdir: String, defaultPath: String) -> some View {
        let d = UserDefaults.standard
        // Mirror DataLocations.reconcile: the path in use is actualKey (promoted only on a
        // successful move) or the default. desiredKey is NOT a fallback — a set-but-unpromoted
        // desired means a move is still pending or was refused, not that data has moved.
        let current = d.string(forKey: actualKey) ?? defaultPath
        let err = d.string(forKey: errorKey)
        let desired = d.string(forKey: desiredKey)
        return LabeledContent {
            Button("Change…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.message = "Choose a parent folder — Debrief will keep a “\(subdir)” folder inside it."
                guard panel.runModal() == .OK, let parent = panel.url else { return }
                let picked = parent.appendingPathComponent(subdir).path
                guard picked != current else { return }
                d.set(picked, forKey: desiredKey)
                relaunchPrompt = RelaunchPrompt(dir: title)
            }
            .disabled(!canRelocate)
        } label: {
            Text(title)
            Text(current).truncationMode(.middle).textSelection(.enabled)
            if let desired, desired != current, err == nil {
                Text("Pending after relaunch: \(desired)")
            }
            if let err {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}
