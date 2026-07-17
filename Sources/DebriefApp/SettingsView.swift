import SwiftUI
import CoachingEngine
import CaptureKit

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var apiKey = KeychainStore.read(key: "anthropic-api-key") ?? ""
    @State private var saved = false
    @State private var saveError: String?
    @AppStorage("keepAudioAfterTranscription") private var keepAudio = false
    @State private var retryResult: String?
    @State private var confirmingRecoach = false
    @AppStorage("coachingModel") private var model = AnthropicClient.defaultModel
    @AppStorage("coachingProvider") private var provider = "anthropic"
    @AppStorage("openAICompatBaseURL") private var compatBaseURL = "http://localhost:11434/v1"
    @AppStorage("openAICompatModel") private var compatModel = ""
    @State private var compatKey = KeychainStore.read(key: "openai-compat-api-key") ?? ""
    @AppStorage("exportDirectory") private var exportDir = ""
    @State private var relaunchPrompt: RelaunchPrompt?
    @State private var relaunchError: String?
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
    private var canRelocate: Bool {
        if case .idle = env.coordinator.phase, !env.isRecoaching { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Coaching model") {
                Picker("Provider", selection: $provider) {
                    Text("Claude API (recommended)").tag("anthropic")
                    Text("Local / OpenAI-compatible").tag("openai_compat")
                }
                .onChange(of: provider) { env.rebuildCoaching() }

                if provider == "anthropic" {
                    if apiKey.isEmpty && !envAPIKeyPresent {
                        Label("No API key configured — debriefs will not run.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if apiKey.isEmpty && envAPIKeyPresent {
                        Text("Using ANTHROPIC_API_KEY from environment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SecureField("API key (sk-ant-…)", text: $apiKey)
                    HStack {
                        Button("Save") {
                            do {
                                if apiKey.isEmpty {
                                    try KeychainStore.delete(key: "anthropic-api-key")
                                } else {
                                    try KeychainStore.save(key: "anthropic-api-key", value: apiKey)
                                }
                                env.rebuildCoaching()
                                saved = true
                                saveError = nil
                            } catch {
                                saveError = "Could not save key: \(error.localizedDescription)"
                                saved = false
                            }
                        }.disabled(!apiKey.isEmpty && !apiKey.hasPrefix("sk-ant-"))
                        if saved { Text("Saved ✓").foregroundStyle(.green) }
                        if let saveError { Text(saveError).foregroundStyle(.red) }
                    }
                    Picker("Model", selection: $model) {
                        ForEach(modelOptions, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .onChange(of: model) { env.rebuildCoaching() }
                    Text("Which Claude model generates debriefs. Applies to the next (re)generate.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Base URL", text: $compatBaseURL, prompt: Text("http://localhost:11434/v1"))
                        .onChange(of: compatBaseURL) { env.rebuildCoaching() }
                    TextField("Model", text: $compatModel, prompt: Text("e.g. deepseek-r1:14b"))
                        .onChange(of: compatModel) { env.rebuildCoaching() }
                    SecureField("API key (optional, for remote providers)", text: $compatKey)
                    Button("Save key") {
                        do {
                            if compatKey.isEmpty {
                                try KeychainStore.delete(key: "openai-compat-api-key")
                            } else {
                                try KeychainStore.save(key: "openai-compat-api-key", value: compatKey)
                            }
                            env.rebuildCoaching()
                            saved = true; saveError = nil
                        } catch {
                            saveError = "Could not save key: \(error.localizedDescription)"; saved = false
                        }
                    }
                    if saved { Text("Saved ✓").foregroundStyle(.green) }
                    if let saveError { Text(saveError).foregroundStyle(.red) }
                    Text("Works with Ollama, LM Studio, or any /v1/chat/completions server. See docs/local-llm.md for setup. Local models give weaker coaching than Claude.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Audio") {
                Toggle("Keep raw audio after transcription", isOn: $keepAudio)
                Text("Takes effect after relaunching Debrief.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Coaching") {
                Button("Retry pending debriefs") {
                    Task {
                        let errors = await env.coaching.retryAllPending()
                        retryResult = errors.isEmpty ? "All caught up." : "\(errors.count) failed — see sessions list."
                    }
                }
                if let retryResult { Text(retryResult).font(.caption) }
                HStack {
                    Button("Re-run debriefs on current rubric") { confirmingRecoach = true }
                        .disabled(env.isRecoaching)
                    if env.isRecoaching { Button("Stop") { env.cancelRecoach() } }
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
                Text("Re-coaches every past session so old debriefs use the current prompts and get an advancement verdict. Costs one API call per session (~30s each) and replaces existing debrief text.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open prompts folder") {
                    NSWorkspace.shared.open(PromptStore.defaultDirectory())
                }
            }
            Section("Cowork export") {
                Text(exportDir.isEmpty
                     ? "Off — choose a folder to write each debrief as a markdown file Claude Cowork can read."
                     : "Exporting to: \(exportDir)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
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
                    if !exportDir.isEmpty {
                        Button("Turn off") { exportDir = "" }
                        Button("Export all now") {
                            env.exportAllSessions(to: URL(fileURLWithPath: exportDir))
                        }
                    }
                }
                if let exportResult = env.exportResult {
                    Text(exportResult).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Data locations") {
                Text("Where Debrief stores its files. Changing a location moves the existing data and relaunches Debrief.")
                    .font(.caption).foregroundStyle(.secondary)
                if !canRelocate {
                    Text("Finish or stop any recording and re-coaching before changing these — the move happens on relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Label(relaunchError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Permissions") {
                Text("Debrief needs Microphone (your voice) and Screen Recording (the other side's audio). Grant them to the terminal/app you launch Debrief from.")
                    .font(.caption)
                Button("Open Microphone settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                Button("Open Screen Recording settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).bold()
                Spacer()
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
            }
            Text(current).font(.caption).foregroundStyle(.secondary)
            if let desired, desired != current, err == nil {
                Text("Pending after relaunch: \(desired)").font(.caption).foregroundStyle(.secondary)
            }
            if let err {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
