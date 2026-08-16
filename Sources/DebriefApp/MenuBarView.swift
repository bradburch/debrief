import SwiftUI
import Store

struct MenuBarView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Recording state and finalize jobs are stacked, not switched between: starting the
        // next interview while the last one is still being debriefed is the whole point.
        VStack(alignment: .leading, spacing: 10) {
            if case .recording(let started) = env.coordinator.recordingPhase {
                recordingSection(started: started)
            } else {
                idleSection
            }
            if !env.coordinator.finalizeJobs.isEmpty {
                Divider()
                FinalizeJobsSection()
            }
            Divider()
            Button("Open Debrief") {
                openWindow(id: "main")
                // ponytail: openWindow() creates the NSWindow asynchronously; activating
                // immediately races it and leaves the window unfocused (LSUIElement apps
                // don't get key status for free). Defer a tick so the window exists first.
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
                }
            }
            // Routed through applicationShouldTerminate (see AppDelegate), which is what
            // asks before abandoning an unfinished debrief.
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    @ViewBuilder
    private var idleSection: some View {
        if !env.recoverableSessions.isEmpty {
            ForEach(env.recoverableSessions, id: \.self) { dir in
                RecoveryPrompt(dir: dir)
            }
            Divider()
        }
        if case .failed(let message) = env.coordinator.recordingPhase {
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(4)
        }
        if env.callDetected {
            Label("Call detected", systemImage: "phone.fill").foregroundStyle(.orange)
        }
        Button {
            Task { await env.startRecording() }
        } label: {
            Label(env.callDetected ? "Record this call" : "Start recording",
                  systemImage: "record.circle")
        }
    }

    @ViewBuilder
    private func recordingSection(started: Date) -> some View {
        Label("Recording \(started, style: .timer)", systemImage: "record.circle.fill")
            .foregroundStyle(.red)
        LevelRow(label: "You", level: env.coordinator.micLevel)
        LevelRow(label: "Them", level: env.coordinator.systemLevel)
        if let warning = env.coordinator.streamWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow).font(.caption)
        }
        if let p = env.coordinator.transcribeProgress, p.total > 0 {
            Text("Transcribed \(p.done)/\(p.total) chunks")
                .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        RecordingControls(axis: .vertical)
    }
}

struct LevelRow: View {
    let label: String
    let level: Float
    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            ProgressView(value: min(Double(level) * 4, 1.0))  // RMS is small; scale for visibility
        }
    }
}
