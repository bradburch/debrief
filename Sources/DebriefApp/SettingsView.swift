import SwiftUI
import CoachingEngine

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var apiKey = KeychainStore.read(key: "anthropic-api-key") ?? ""
    @State private var saved = false
    @State private var saveError: String?
    @AppStorage("keepAudioAfterTranscription") private var keepAudio = false
    @State private var retryResult: String?
    @AppStorage("coachingModel") private var model = AnthropicClient.defaultModel
    @AppStorage("coachingProvider") private var provider = "anthropic"
    @AppStorage("openAICompatBaseURL") private var compatBaseURL = "http://localhost:11434/v1"
    @AppStorage("openAICompatModel") private var compatModel = ""
    @State private var compatKey = KeychainStore.read(key: "openai-compat-api-key") ?? ""

    private let modelOptions: [(label: String, id: String)] = [
        ("Opus 4.8 — best quality (default)", "claude-opus-4-8"),
        ("Sonnet 5 — balanced", "claude-sonnet-5"),
        ("Haiku 4.5 — fastest, cheapest", "claude-haiku-4-5-20251001"),
    ]

    private var envAPIKeyPresent: Bool {
        !(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
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
                Button("Open prompts folder") {
                    NSWorkspace.shared.open(PromptStore.defaultDirectory())
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
    }
}
