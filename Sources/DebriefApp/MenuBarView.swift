import SwiftUI
import Store

struct MenuBarView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @State private var company = ""
    @State private var roundType: RoundType = .behavioral
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch env.coordinator.phase {
            case .idle:
                if !env.recoverableSessions.isEmpty {
                    ForEach(env.recoverableSessions, id: \.self) { dir in
                        RecoveryPrompt(dir: dir)
                    }
                    Divider()
                }
                if env.callDetected {
                    Label("Call detected", systemImage: "phone.fill").foregroundStyle(.orange)
                }
                Button {
                    Task { await env.coordinator.startRecording() }
                } label: {
                    Label(env.callDetected ? "Record this call" : "Start recording",
                          systemImage: "record.circle")
                }
            case .recording(let started):
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
                TextField("Company", text: $company)
                Picker("Round", selection: $roundType) {
                    ForEach(RoundType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Notes (optional)", text: $notes)
                Button("Stop & Debrief") {
                    Task {
                        let name = company.isEmpty ? "Unknown" : company
                        _ = await env.coordinator.stopAndFinalize(
                            metadata: .init(company: name, roundType: roundType, notes: notes))
                        company = ""; notes = ""
                    }
                }
            case .finalizing(let status):
                HStack { ProgressView().controlSize(.small); Text(status) }
                if let p = env.coordinator.transcribeProgress, p.done < p.total {
                    Text("\(p.done)/\(p.total) chunks")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
                    .lineLimit(4)
            }
            Divider()
            Button("Open Debrief") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
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
