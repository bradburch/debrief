import SwiftUI
import CoachingEngine

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var apiKey = KeychainStore.read(key: "anthropic-api-key") ?? ""
    @State private var saved = false
    @State private var saveError: String?
    @AppStorage("keepAudioAfterTranscription") private var keepAudio = false
    @State private var retryResult: String?

    private var envAPIKeyPresent: Bool {
        !(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
    }

    var body: some View {
        Form {
            Section("Claude API") {
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
