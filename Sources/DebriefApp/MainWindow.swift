import SwiftUI
import Store

extension Color {
    /// Debrief's score-quality scale, shared by the Sessions list and Pipeline cells.
    static func forScore(_ score: Double) -> Color {
        score >= 3.5 ? .green : score >= 2.5 ? .orange : .red
    }
}

enum MainTab: String, CaseIterable {
    case sessions = "Sessions", pipeline = "Pipeline", trends = "Trends", settings = "Settings"
    var symbol: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .pipeline: return "building.2"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    @State private var tab: MainTab? = .sessions

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, id: \.self, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(spacing: 0) {
                RecordingBar()
                Divider()
                switch tab ?? .sessions {
                case .sessions: SessionsView()
                case .pipeline: PipelineView()
                case .trends: TrendsView()
                case .settings: SettingsView()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct RecordingBar: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch env.coordinator.phase {
            case .idle:
                HStack {
                    if env.callDetected {
                        Label("Call detected", systemImage: "phone.fill").foregroundStyle(.orange)
                    } else {
                        Text("No recording in progress").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await env.startRecording() }
                    } label: {
                        Label(env.callDetected ? "Record this call" : "Start recording", systemImage: "record.circle")
                    }
                }
            case .recording(let started):
                HStack {
                    Label("Recording \(started, style: .timer)", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                    Spacer()
                }
                LevelRow(label: "You", level: env.coordinator.micLevel)
                LevelRow(label: "Them", level: env.coordinator.systemLevel)
                if let warning = env.coordinator.streamWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow).font(.caption)
                }
                // ponytail: the Company/Round/Notes stop-form layout is reproduced from
                // MenuBarView — ~12 lines read clearer than a shared @Binding-plumbed
                // subview. The field *values* live on AppEnvironment (recordCompany/…), so
                // the two surfaces share state and neither loses metadata the other typed.
                // Upgrade path: extract a RecordingControls view if a third caller appears.
                HStack {
                    TextField("Company", text: $env.recordCompany).frame(maxWidth: 200)
                    Picker("Round", selection: $env.recordRoundType) {
                        ForEach(env.prompts.availableRoundTypes(), id: \.self) { Text($0.displayName).tag($0) }
                    }.frame(maxWidth: 220)
                    TextField("Notes (optional)", text: $env.recordNotes)
                    Button("Stop & Debrief") {
                        Task { await env.stopAndDebrief() }
                    }
                }
            case .finalizing(let status):
                HStack { ProgressView().controlSize(.small); Text(status) }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption).lineLimit(3)
            }
        }
        .padding(10)
        .background(.bar)
    }
}
