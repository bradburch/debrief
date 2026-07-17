import SwiftUI
import Store

extension Color {
    /// Debrief's score-quality scale, shared by the Sessions list and Pipeline cells.
    static func forScore(_ score: Double) -> Color {
        score >= 3.5 ? .green : score >= 2.5 ? .orange : .red
    }

    /// The verdict's scale. Distinct from forScore because this is an ordinal call, not a
    /// threshold on a number — the two leans are deliberately different shades so a
    /// borderline result never reads as a clean pass or a clean reject.
    static func forAdvancement(_ a: Advancement) -> Color {
        switch a {
        case .strongYes: return .green
        case .leanYes: return .mint
        case .leanNo: return .orange
        case .strongNo: return .red
        }
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
    // Tab selection lives on AppEnvironment so other views can navigate here (Pipeline →
    // a session). Was @State; nothing else could reach it.
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, id: \.self, selection: $env.selectedTab) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(spacing: 0) {
                RecordingBar()
                RecoachBar()
                Divider()
                switch env.selectedTab ?? .sessions {
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

/// A re-run takes ~30s per session and outlives the Settings tab, so its progress is shown
/// app-wide rather than only where it was started. Absent unless a run is in flight.
struct RecoachBar: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        if let progress = env.recoachProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.total == 0
                     ? "Re-coaching debriefs…"
                     : "Re-coaching debrief \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                    .font(.caption)
                if progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .progressViewStyle(.linear).frame(maxWidth: 160)
                }
                Spacer()
                Button("Stop") { env.cancelRecoach() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
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
